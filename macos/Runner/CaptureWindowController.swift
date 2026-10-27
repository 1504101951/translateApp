import AppKit
import AVKit
import FlutterMacOS

/// 采集工具协调者；截图层确认选区，采集与暂停时显示实时阴影与四气泡控制条，完成后展示结果。
@MainActor
final class CaptureWindowController: NSObject, NSWindowDelegate {
    let service = MediaCaptureService()
    private let screenshot: ScreenshotWindowController
    private var engine: FlutterEngine?
    private var channel: FlutterMethodChannel?
    /// 启动期间合并预热和展示请求，退出或丢弃时撤销，避免迟到创建旧面板。
    private var pendingStartup: WindowEngine.Startup?
    private var window: NSWindow?
    private var player: AVPlayer?
    private weak var playerView: AVPlayerView?
    private var playerSession: String?
    private var preparingScreenshot = false
    private var shuttingDown = false
    private var discarding = false
    private var compactPresentation: Bool?
    private var lastPhase = CapturePhase.idle
    /// 打开结果前的激活策略；关闭结果后恢复菜单栏形态，避免采集层消失后窗口留在其他应用后面。
    private var activationBeforeResult: NSApplication.ActivationPolicy?
    private var originScreen: NSScreen?
    private var captureShades: [CGDirectDisplayID: NSWindow] = [:]
    var onActiveChanged: ((Bool) -> Void)?
    var onLivePause: ((Bool) -> Void)?
    var onLiveStop: (() -> Void)?
    var onLiveCancel: (() -> Void)?
    private var liveControlID: String?
    private var livePaused = false
    private var liveDetail = ""
    private var liveShadeFrame: NSRect?
    /// 已显示的长截图过程提示（会话身份#序号）；新序号才在选区中央再显示一次。
    private var shownScrollHint: String?
    /// 长截图实时缩略图窗口；只在滚动、暂停中存在，属于本应用而不进入采集像素。
    private var scrollPreviewWindow: NSPanel?

    /// 无参数；返回菜单与悬浮条停止可作用的真实资源阶段。
    var canStop: Bool {
        liveControlID != nil || [.recording, .scrolling, .paused].contains(service.phase)
    }

    /// 无参数；有资源或结果时必须明确处理，不能被另一工具入口覆盖。
    var hasPendingCapture: Bool { discarding || ![.idle, .failed].contains(service.phase) }

    /// screenshot为唯一截图选择/编辑控制器；监听资源状态以切换承载面板。
    init(screenshot: ScreenshotWindowController) {
        self.screenshot = screenshot
        super.init()
        service.onChange = { [weak self] _ in
            guard let self else { return }
            let started = ContinuousClock.now
            let transition = self.service.phase != self.lastPhase
            let phase = self.service.phase
            // 真正进入采集后才释放截图草稿；准备失败或取消恢复同一编辑会话。
            let preparationFinished = [.recording, .scrolling, .failed].contains(self.service.phase)
                || (self.service.phase == .idle && self.lastPhase == .preparing)
            if self.preparingScreenshot && preparationFinished {
                self.preparingScreenshot = false
                if [.recording, .scrolling].contains(self.service.phase) { self.screenshot.closeForCapture() }
                else if !self.shuttingDown { self.screenshot.restoreAfterCapturePreparation() }
            }
            // 准备态由present在缩放前发布，提供可提交的新帧；媒体结果待窗口几何就绪后再布局。
            self.present()
            self.showScrollHintIfNeeded()
            if phase != .preparing {
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            }
            // 只记录启动阶段切换的同步UI工作，录制计时通知不产生逐秒诊断日志。
            if transition && [.preparing, .recording].contains(phase) {
                CaptureStartupLog.record("ui-\(phase.rawValue)-sync", since: started)
            }
        }
        service.onActiveChanged = { [weak self] active in self?.onActiveChanged?(active) }
        service.onScrollPreview = { [weak self] preview, scale in self?.showScrollPreview(preview, scale: scale) }
    }

    /// 无参数；终止任务并释放播放器文件引用，再关闭本工具的面板和引擎。
    func shutdown() async {
        shuttingDown = true
        pendingStartup?.cancel()
        pendingStartup = nil
        // 退出立即撤下可见遮罩，再等待媒体资源清理。
        updateCaptureShades()
        // 在等待媒体资源清理前，先阻止选区冻结任务创建新的窗口。
        screenshot.cancelCapture()
        releasePlayer()
        await service.cancel()
        window?.delegate = nil
        window?.close()
        restoreActivationIfNeeded()
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }

    /// source为截图工具栏确认的来源，scrolling指定长截图，region为已校验的选区；返回后异步启动。
    func prepare(source: [String: Any], scrolling: Bool, region: MediaCaptureService.Region?) throws {
        guard !shuttingDown, !hasPendingCapture else {
            throw GIFExporter.ExportError(message: "请先结束或放弃当前采集。")
        }
        guard source["kind"] as? String != CaptureTarget.region.rawValue || region != nil else {
            throw GIFExporter.ExportError(message: "请先选择有效录制区域。")
        }
        // start负责保持会话身份并在资源层重新验证目标，工具栏不直接持有捕获流。
        start(source, scrolling: scrolling, region: region)
    }

    /// preferredApplicationID为截图前台应用；返回应用图标行所需的去重有序来源。
    func sources(preferredApplicationID: String?) async throws -> [[String: Any]] {
        try await service.sources(preferredApplicationID: preferredApplicationID)
    }

    /// 无参数/返回值；选择录制目标时准备隐藏的采集界面，避免开始采集时同步初始化Flutter引擎。
    func prepareControls() {
        guard !shuttingDown else { return }
        // createPanel只初始化并复用界面，不显示窗口、不申请或启动媒体资源。
        createPanel()
    }

    /// source为明确目标，scrolling决定静帧或视频，region为本次选区；返回后异步启动资源。
    private func start(_ source: [String: Any], scrolling: Bool, region: MediaCaptureService.Region? = nil) {
        let token = service.id
        guard let screenshotID = screenshot.liveCaptureID else { return }
        Task { @MainActor in
            guard !shuttingDown, token == service.id, !hasPendingCapture,
                  screenshotID == screenshot.liveCaptureID else { return }
            do {
                // 先提交选区；其idle通知只是选区更新，不是采集准备被取消。
                if let region { try service.select(region) }
                // 准备期间隐藏冻结层，实际采集就绪后才销毁草稿。
                preparingScreenshot = true
                screenshot.hideForCapture()
                if let id = source["sourceID"] as? NSNumber {
                    originScreen = NSScreen.screens.first { $0.displayID == id.uint32Value }
                }
                if scrolling { try await service.startScrolling() }
                else { try await service.startRecording(source) }
            } catch is CancellationError {
                // 准备期间用户停止已清理会话，不把明确取消显示成采集故障。
            } catch {
                if preparingScreenshot {
                    preparingScreenshot = false
                    screenshot.restoreAfterCapturePreparation()
                }
                if service.phase != .failed { showError(error) }
            }
        }
    }

    /// 无参数；等待 Dart 就绪后懒建透明 Flutter 面板，按当前状态展示，idle 预热保持隐藏，无返回值。
    private func createPanel() {
        guard window == nil, pendingStartup == nil, !shuttingDown, !discarding else { return }
        let started = ContinuousClock.now
        // 记录真实采集引擎初始化，便于区分界面准备与ScreenCaptureKit启动耗时。
        defer { CaptureStartupLog.record("capture-ui-create-sync", since: started) }
        // WindowEngine 等待 Dart 确认；采集窗口就绪后再注册视频预览平台视图。
        pendingStartup = WindowEngine.start(
            name: AppConstants.captureEntrypoint, entrypoint: AppConstants.captureEntrypoint,
            channel: AppConstants.captureChannel,
            handler: { [weak self] call, result in self?.handle(call, result: result) },
            completion: { [weak self] started in
                guard let self else { return }
                self.pendingStartup = nil
                guard let started else {
                    // 清理期间阻止资源通知重新启动面板；真实采集资源必须在失败提示前结束。
                    self.discarding = true
                    if self.liveControlID != nil {
                        self.onLiveCancel?()
                        // hideLiveControls/setLiveShade 立即撤销失去控制条的实时展示状态。
                        self.hideLiveControls()
                        self.setLiveShade(nil)
                    }
                    Task { @MainActor in
                        // releasePlayer 先解除文件引用，再由 cancel 释放流与临时媒体。
                        self.releasePlayer()
                        await self.service.cancel()
                        if self.preparingScreenshot {
                            self.preparingScreenshot = false
                            // restoreAfterCapturePreparation 恢复尚未开始采集的同一截图草稿。
                            if !self.shuttingDown { self.screenshot.restoreAfterCapturePreparation() }
                        }
                        self.discarding = false
                        // present 同步清理后的空闲状态，撤下采集遮罩并恢复激活策略。
                        self.present()
                        guard !self.shuttingDown else { return }
                        // reportStartFailure 使用附属窗口统一的启动失败提示。
                        WindowEngine.reportStartFailure("采集窗口")
                    }
                    return
                }
                self.engine = started.engine
                self.channel = started.channel
                let flutter = started.flutter
                flutter.registrar(forPlugin: "CaptureVideoPreview").register(
                    CapturePreviewFactory(owner: self), withId: AppConstants.captureVideoPreview)
                // makeWindow 从创建时就明确非激活类型，随后 present 按当前媒体状态调整窗口。
                let panel = Self.makeWindow(compact: true)
                panel.delegate = self
                NativeGlassFactory.installContent(flutter, in: panel)
                self.window = panel
                // present 读取确认时的真实阶段；预热完成仍处于 idle 时保持隐藏。
                self.present()
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            })
    }

    /// compact指定采集控制条或视频结果；返回非激活顶层面板或带系统控制的普通窗口。
    static func makeWindow(compact: Bool) -> NSWindow {
        let frame = NSRect(origin: .zero, size: AppConstants.captureControlSize)
        let window: NSWindow
        if compact {
            let panel = CaptureControlPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            // 平台包装视图可能不接受首鼠标；无需键盘的按钮不先消耗一次点击来取得窗口焦点。
            panel.becomesKeyOnlyIfNeeded = true
            window = panel
        } else {
            window = NSWindow(contentRect: frame, styleMask: AppConstants.captureResultWindowStyle,
                backing: .buffered, defer: false)
            window.title = "录制结果"
            window.contentMinSize = Self.recordingResultMinimumSize()
        }
        window.isReleasedWhenClosed = false
        window.isOpaque = !compact
        window.backgroundColor = compact ? .clear : .windowBackgroundColor
        window.hasShadow = !compact
        window.hidesOnDeactivate = false
        window.level = compact ? .statusBar : .normal
        window.collectionBehavior = compact ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
        return window
    }

    /// pixels为源视频像素，scale为来源显示倍率，visible为屏幕可用区；返回包含系统标题栏、等比媒体与工具栏的窗口。
    static func resultFrame(pixels: NSSize, scale: CGFloat, visible: NSRect) -> NSRect {
        let logical = NSSize(width: pixels.width / scale, height: pixels.height / scale)
        let inset = AppConstants.captureControlGap
        // 系统标题栏和边框占用真实窗口空间，Flutter只布局标题栏下方的可用内容。
        let available = NSWindow.contentRect(forFrameRect: visible, styleMask: AppConstants.captureResultWindowStyle).size
        // 右侧48pt工具栏、8pt间隔和左右各8pt外边距；纵向七个按钮含padding共312pt。
        let reservedWidth = AppConstants.captureResultToolbarWidth + inset * 3
        let fit = min(1, min((available.width - reservedWidth) / logical.width,
                             (available.height - inset * 2) / logical.height))
        // 浮点缩放可能在恰好铺满时多出亚像素；窗口边界始终限制在可用屏幕内。
        let contentSize = NSSize(width: min(available.width, logical.width * fit + reservedWidth),
                                 height: min(available.height, max(logical.height * fit, AppConstants.captureResultToolbarHeight) + inset * 2))
        let frame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: AppConstants.captureResultWindowStyle)
        let size = NSSize(width: min(visible.width, frame.width), height: min(visible.height, frame.height))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// 无参数；在资源快照中补充实际采集状态，Flutter与原生窗口使用同一生命周期。
    private func captureState() -> [String: Any] {
        if let liveControlID {
            // 实时翻译同步录制时带上录制时长；未录制时媒体阶段为 idle。
            let recording = [.preparing, .recording, .pausing, .paused].contains(service.phase)
            return [
                "id": liveControlID,
                "phase": livePaused ? CapturePhase.paused.rawValue : CapturePhase.recording.rawValue,
                "kind": "liveTranslation",
                "recording": recording,
                "elapsed": recording ? service.snapshot()["elapsed"] ?? 0 : 0,
                "detail": liveDetail,
                "previewScale": originScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            ]
        }
        var state = service.snapshot()
        state["previewScale"] = originScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return state
    }

    /// id 为本次实时翻译控制身份，screen 为来源所在显示器。显示既有悬浮条，不启动录屏。
    func showLiveControls(id: String, screen: NSScreen?) {
        liveControlID = id
        livePaused = false
        if let screen { originScreen = screen }
        // present 按紧凑控制条显示面板并通知界面，与录制、长截图是同一段流程。
        present()
    }

    /// text 为运行中的状态。暂停和结束后清空，悬浮条回到「实时翻译」。
    func setLiveDetail(_ text: String) {
        guard liveControlID != nil, liveDetail != text else { return }
        liveDetail = text
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    /// paused 为悬浮条上的暂停或恢复。只更新实时翻译控制，不改变录屏阶段。
    func setLivePaused(_ paused: Bool) {
        guard liveControlID != nil else { return }
        livePaused = paused
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    /// 无参数。撤下实时翻译悬浮条。录屏结果仍由媒体阶段决定。
    func hideLiveControls() {
        liveControlID = nil
        livePaused = false
        liveDetail = ""
        // present 按媒体阶段收起控制条，或恢复仍在展示的采集结果。
        present()
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    /// frame 为当前捕获范围。nil 表示移除区域标记。
    func setLiveShade(_ frame: NSRect?) {
        liveShadeFrame = frame
        updateCaptureShades()
    }

    /// force表示用户重新打开隐藏结果；资源通知只同步所需布局和可见录制范围。
    func present(force: Bool = false) {
        guard !shuttingDown, !discarding else { return }
        let previous = lastPhase
        // 实时翻译不占用媒体阶段；进行中时与采集中一样显示紧凑控制条。
        let live = liveControlID != nil
        // 同步录制在实时翻译期间失败时先不记为已处理，实时翻译结束后的下一次调用才提示失败。
        if !(live && service.phase == .failed) { lastPhase = service.phase }
        let showingResult = !live && [.videoReady, .converting, .imageReady].contains(service.phase)
        // 结果先就位再撤遮罩；采集中仍立即更新选区阴影。
        if !showingResult { updateCaptureShades() }
        if !live, [.idle, .failed].contains(service.phase) {
            window?.orderOut(nil)
            compactPresentation = nil
            releasePlayer()
            if previous != service.phase, service.phase == .failed, let message = service.snapshot()["error"] as? String {
                // 采集层已经撤下；先成为可激活应用，失败说明才不会留在正在滚动的应用后面。
                let policy = NSApp.activationPolicy()
                if policy != .regular { _ = NSApp.setActivationPolicy(.regular) }
                NSApp.activate(ignoringOtherApps: true)
                showError(GIFExporter.ExportError(message: message))
                if NSApp.activationPolicy() != policy { _ = NSApp.setActivationPolicy(policy) }
            }
            restoreActivationIfNeeded()
            return
        }
        createPanel()
        // 尚在等待 Dart 确认时由完成回调继续展示，不将暂无窗口当作启动失败。
        guard pendingStartup == nil else { return }
        let compact = live || [.preparing, .recording, .scrolling, .pausing, .paused, .finalizing].contains(service.phase)
        // NSPanel的非激活标记必须在初始化时确定；仅转移内容，不重建Flutter引擎或媒体。
        if let old = window, old.styleMask.contains(.nonactivatingPanel) != compact {
            let content = old.contentViewController
            old.contentViewController = nil
            old.delegate = nil
            old.close()
            let replacement = Self.makeWindow(compact: compact)
            replacement.contentViewController = content
            replacement.delegate = self
            NativeGlassFactory.applyAppearance(to: replacement)
            window = replacement
        }
        guard let window else { return }
        let changed = compactPresentation != compact
        let controlSize = AppConstants.captureControlSize
        let sizeChanged = compact && window.contentView?.frame.size != controlSize
        if changed {
            compactPresentation = compact
            (window.contentViewController as? NativeGlassWindowContent)?.windowCanvas.isHidden = compact
        }
        if live || service.phase == .preparing {
            // 隐藏的idle界面没有可提交内容；先通知准备态或实时翻译状态，再缩放，避免Flutter同步等待空白帧直到超时。
            channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
        }
        if !compact { applyResultChrome(to: window) }
        // 结果只占媒体、工具栏和系统边框，窗口整体限制在来源屏可用区内。
        if changed || sizeChanged {
            if compact { window.setContentSize(controlSize) }
            else if let screen = originScreen ?? NSScreen.main {
                let state = service.snapshot()
                guard let width = state["width"] as? Int, let height = state["height"] as? Int else { return }
                let pixels = NSSize(width: width, height: height)
                let visible = screen.visibleFrame
                // 长图保持逻辑宽度并可滚动；视频才按可用区等比缩小。
                let frame = service.phase == .imageReady
                    ? ScreenshotWindowController.imageResultFrame(pixels: pixels, scale: screen.backingScaleFactor, visible: visible)
                    : Self.resultFrame(pixels: pixels, scale: screen.backingScaleFactor, visible: visible)
                window.setFrame(frame, display: true)
            }
        }
        if compact {
            // placeControls把当前面板放到来源屏可用区的右下角。
            placeControls()
            window.orderFrontRegardless()
        } else if changed || force {
            // 菜单栏应用默认不能盖过正在滚动的前台应用，结果必须先显示出来。
            orderResultFront(window)
        }
        if showingResult { updateCaptureShades() }
    }

    /// window为本次要展示的结果；记住打开前的激活策略，并把它放到当前前台应用之前。
    private func orderResultFront(_ window: NSWindow) {
        if activationBeforeResult == nil { activationBeforeResult = NSApp.activationPolicy() }
        // 菜单栏应用停留在 accessory 时，普通窗口会落在正在滚动的应用后面。
        if NSApp.activationPolicy() != .regular { _ = NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 激活尚未完成时也先显示；层级仍是普通窗口，之后允许其他应用盖住。
        window.orderFrontRegardless()
    }

    /// 无参数/返回值；结果关闭后恢复打开前的菜单栏或普通激活策略。
    private func restoreActivationIfNeeded() {
        guard let previous = activationBeforeResult else { return }
        activationBeforeResult = nil
        if NSApp.activationPolicy() != previous { _ = NSApp.setActivationPolicy(previous) }
    }

    /// window为已经换成普通标题样式的结果窗；长图和视频使用不同标题与最小内容，避免工具栏被裁掉。
    private func applyResultChrome(to window: NSWindow) {
        let image = service.phase == .imageReady
        window.title = image ? "长截图结果" : "录制结果"
        window.contentMinSize = image ? AppConstants.longScreenshotResultMinimumSize : Self.recordingResultMinimumSize()
    }

    /// 无参数；返回录制结果窗的最小内容尺寸，保留右侧六个操作、内外间距和至少1pt视频，缩放不裁掉工具栏。
    private static func recordingResultMinimumSize() -> NSSize {
        NSSize(width: AppConstants.captureResultToolbarWidth + AppConstants.captureControlGap * 3 + 1,
               height: AppConstants.captureResultToolbarHeight + AppConstants.captureControlGap * 2)
    }

    /// 无参数；控制条固定在发起截图显示器的右下角，不随窗口移动或采集范围跳屏。
    private func placeControls() {
        guard let window, let screen = originScreen ?? NSScreen.main else { return }
        // controlOrigin统一可用区与面板尺寸的几何约定，不受图片像素倍率影响。
        window.setFrameOrigin(Self.controlOrigin(visible: screen.visibleFrame, size: window.frame.size))
    }

    /// visible为显示器可用点坐标，size为透明面板尺寸；返回留8pt边距的右下角原点。
    static func controlOrigin(visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: max(visible.minX, visible.maxX - size.width - AppConstants.captureControlGap),
                y: visible.minY + AppConstants.captureControlGap)
    }

    /// 无参数；长截图的新过程提示画在选区中心所在显示器的遮罩里。遮罩属于本应用，已排除在屏幕采集之外，
    /// 且不接收鼠标，提示不会进入长图，滚动仍交给来源应用。自动滚动到底的提示随暂停发布，暂停时也显示（#112）。
    private func showScrollHintIfNeeded() {
        let state = service.snapshot()
        guard [.scrolling, .paused].contains(service.phase), let serial = state["hintSerial"] as? Int,
              let text = state["hint"] as? String, let frame = service.captureFrame else { return }
        let key = "\(state["id"] as? String ?? "")#\(serial)"
        guard key != shownScrollHint else { return }
        shownScrollHint = key
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let shade = captureShades.values.first(where: { $0.frame.contains(center) }) ?? captureShades.values.first,
              let view = shade.contentView as? CaptureShadeView,
              let screen = NSScreen.screens.first(where: { $0.frame == shade.frame }) ?? shade.screen else { return }
        // 可用区、控制面板和缩略图换成遮罩视图坐标；提示避开后两者。
        let origin = shade.frame.origin
        let local = { (rect: NSRect) in rect.offsetBy(dx: -origin.x, dy: -origin.y) }
        let avoiding = [window?.isVisible == true ? window?.frame : nil, scrollPreviewWindow?.frame].compactMap { $0 }.map(local)
        view.showHint(text, isError: state["hintIsError"] as? Bool == true,
                      visible: local(screen.visibleFrame), avoiding: avoiding)
    }

    /// preview为已确认长图底部缩略图，scale为选区所在屏倍率；在控制面板正上方右对齐显示，间距8pt并限制在可用区内。
    private func showScrollPreview(_ preview: ScrollStitcher.Preview, scale: CGFloat) {
        guard [.scrolling, .pausing, .paused].contains(service.phase),
              let screen = originScreen ?? NSScreen.main else { return }
        let panel: NSPanel
        if let current = scrollPreviewWindow { panel = current } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = ScrollPreviewView()
            NativeGlassFactory.applyAppearance(to: panel)
            scrollPreviewWindow = panel
        }
        guard let view = panel.contentView as? ScrollPreviewView else { return }
        let size = view.update(preview, scale: scale)
        let control = window?.frame ?? NSRect(origin: Self.controlOrigin(visible: screen.visibleFrame, size: AppConstants.captureControlSize),
                                              size: AppConstants.captureControlSize)
        panel.setFrame(Self.scrollPreviewFrame(size: size, control: control, visible: screen.visibleFrame), display: true)
        panel.orderFrontRegardless()
    }

    /// size为缩略图外框，control为控制面板，visible为可用区；返回面板正上方8pt、右边对齐且不超出可用区的框。
    static func scrollPreviewFrame(size: NSSize, control: NSRect, visible: NSRect) -> NSRect {
        let x = min(max(control.maxX - size.width, visible.minX), visible.maxX - size.width)
        let y = min(control.maxY + AppConstants.captureControlGap, visible.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 无参数；在与采集范围相交的显示器上绘制实时阴影，透明洞和全部窗口均穿透鼠标。
    private func updateCaptureShades() {
        let mediaFrame = !shuttingDown && [.preparing, .recording, .scrolling, .pausing, .paused].contains(service.phase)
            ? service.captureFrame : nil
        if shuttingDown || ![.scrolling, .pausing, .paused].contains(service.phase) {
            scrollPreviewWindow?.close()
            scrollPreviewWindow = nil
        }
        guard let frame = liveShadeFrame ?? mediaFrame else {
            for window in captureShades.values { window.close() }
            captureShades.removeAll()
            return
        }
        var active = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens where screen.frame.intersects(frame) {
            guard let displayID = screen.displayID else { continue }
            active.insert(displayID)
            let shade: NSWindow
            if let current = captureShades[displayID] {
                shade = current
            } else {
                shade = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                shade.isReleasedWhenClosed = false
                shade.isOpaque = false
                shade.backgroundColor = .clear
                shade.hasShadow = false
                shade.ignoresMouseEvents = true
                shade.level = .floating
                shade.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                shade.contentView = CaptureShadeView(frame: NSRect(origin: .zero, size: screen.frame.size))
                captureShades[displayID] = shade
                shade.orderFrontRegardless()
            }
            shade.setFrame(screen.frame, display: false)
            let view = shade.contentView as! CaptureShadeView
            view.selection = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                .intersection(NSRect(origin: .zero, size: screen.frame.size))
        }
        for displayID in Set(captureShades.keys).subtracting(active) {
            captureShades.removeValue(forKey: displayID)?.close()
        }
    }

    /// sender为用户关闭的结果窗口；返回false，由立即放弃后的资源状态统一撤下窗口。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if liveControlID != nil {
            onLiveCancel?()
            return false
        }
        Task { @MainActor in
            // discard统一系统关闭和Flutter操作；内部窗口切换时不设delegate，不经过此入口。
            await discard()
        }
        return false
    }

    /// 无参数/返回值；单击立即停止当前任务并清理临时媒体，已经保存的文件不参与删除。
    private func discard() async {
        guard !discarding else { return }
        discarding = true
        pendingStartup?.cancel()
        pendingStartup = nil
        defer {
            discarding = false
            // present 在资源清理完成后同步空闲状态，清理中的通知不能重建窗口。
            present()
        }
        // releasePlayer先撤销文件引用，再由cancel结束任务并清理临时目录。
        releasePlayer()
        await service.cancel()
    }

    /// 无参数；由菜单发出停止请求，完成后的状态通知负责展示结果。
    func stop() {
        if liveControlID != nil {
            onLiveStop?()
            return
        }
        Task { @MainActor in
            do { try await service.stop() }
            catch { if service.phase != .failed { showError(error) } }
        }
    }

    /// error为实际业务或系统错误；通过原生提示展示原因，不创建采集准备页面。
    private func showError(_ error: Error) {
        guard !shuttingDown else { return }
        let alert = NSAlert()
        alert.messageText = "无法完成采集操作"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// 无参数；暂停并释放播放器对临时文件的引用，再由资源层处理清理。
    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView?.player = nil
        player = nil
        playerSession = nil
    }

    /// 无参数；返回当前长图的源像素PNG。没有可保存结果时返回nil。
    private func scrollPNG() -> Data? {
        guard service.phase == .imageReady,
              let bytes = service.snapshot()["imageBytes"] as? FlutterStandardTypedData else { return nil }
        return bytes.data
    }

    /// call为当前会话的控制或结果操作；异步入口重复检查身份，不提供准备表单协议。
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                if let liveControlID {
                    guard call.method == AppConstants.getCaptureStateMethod || args["id"] as? String == liveControlID else {
                        throw GIFExporter.ExportError(message: "采集会话已改变，请重试。")
                    }
                    switch call.method {
                    case AppConstants.getCaptureStateMethod:
                        break
                    case AppConstants.setCapturePausedMethod:
                        guard let paused = args["paused"] as? Bool else {
                            throw GIFExporter.ExportError(message: "缺少暂停状态。")
                        }
                        // 先反映到回包，避免异步暂停完成前把界面又刷回运行中。
                        livePaused = paused
                        onLivePause?(paused)
                    case AppConstants.stopCaptureMethod:
                        onLiveStop?()
                    case AppConstants.cancelCaptureMethod:
                        onLiveCancel?()
                    default:
                        throw GIFExporter.ExportError(message: "实时翻译没有这个媒体操作。")
                    }
                    result(captureState())
                    return
                }
                guard call.method == AppConstants.getCaptureStateMethod || args["id"] as? String == service.id else {
                    throw GIFExporter.ExportError(message: "采集会话已改变，请重试。")
                }
                let token = service.id
                switch call.method {
                case AppConstants.getCaptureStateMethod:
                    break
                case AppConstants.setCapturePausedMethod:
                    guard let paused = args["paused"] as? Bool else {
                        throw GIFExporter.ExportError(message: "缺少暂停状态。")
                    }
                    try await service.setPaused(paused)
                case AppConstants.stopCaptureMethod:
                    try await service.stop()
                case AppConstants.cancelCaptureMethod:
                    await discard()
                case AppConstants.saveRecordingMethod:
                    let target = try outputURL(.mp4, date: Date())
                    try service.saveVideo(to: target)
                case AppConstants.previewRecordingMethod:
                    try await preview()
                case AppConstants.trimRecordingMethod:
                    try await trim()
                case AppConstants.exportRecordingGIFMethod, AppConstants.exportRecordingAPNGMethod:
                    let format: GIFExporter.Format = call.method == AppConstants.exportRecordingGIFMethod ? .gif : .apng
                    let requestedAt = Date()
                    let source = try service.recordingURL()
                    let info = try await GIFExporter.metadata(source)
                    guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
                    // 每次导出读取已提交设置；GIF与APNG共用截图设置中的GIF参数，结果窗口不缓存另一份。
                    let settings = AppPreferences.current
                    let options = GIFExporter.Options(
                        framesPerSecond: settings[AppConstants.gifFramesPerSecondKey] as? Int ?? 10,
                        maximumWidth: settings[AppConstants.gifMaximumWidthKey] as? Int)
                    // 帧数上限按裁剪后的时长校验，超限在进入转换前直接失败。
                    _ = try options.validate(duration: service.trim?.duration.seconds ?? info.duration, sourceWidth: info.width)
                    let target = try outputURL(format.kind, date: requestedAt)
                    try service.exportAnimation(format, options: options, to: target)
                case AppConstants.exportRecordingWebMMethod:
                    // WebM 保持原分辨率与原帧时间，不读取GIF设置（#110）。
                    let target = try outputURL(.webm, date: Date())
                    try service.exportWebM(to: target)
                case AppConstants.cancelRecordingExportMethod:
                    service.cancelExport()
                case AppConstants.copyScreenshotMethod:
                    guard let png = scrollPNG() else {
                        throw GIFExporter.ExportError(message: "当前没有可复制的长图。")
                    }
                    let item = NSPasteboardItem()
                    item.setData(png, forType: .png)
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.writeObjects([item]) else {
                        throw GIFExporter.ExportError(message: "无法复制长图，请重试。")
                    }
                case AppConstants.saveScreenshotMethod:
                    guard let png = scrollPNG() else {
                        throw GIFExporter.ExportError(message: "当前没有可保存的长图。")
                    }
                    let name = args["name"] as? String ?? "长截图.png"
                    // datedDirectory创建截图/日期目录；save按源像素写入，不经过裁剪编码。
                    let directory = try ScreenshotStorage.datedDirectory(
                        basePath: UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey),
                        category: .screenshot)
                    let url = try ScreenshotStorage.save(png, directory: directory, name: name)
                    service.noteSavedScroll(url.path)
                default:
                    result(FlutterMethodNotImplemented); return
                }
                result(captureState())
            } catch {
                result(FlutterError(code: AppConstants.captureFailedError, message: error.localizedDescription, details: nil))
            }
        }
    }

    /// kind为导出类型，date为点击操作时刻；返回分类日期路径，文件名与目录共用同一日期，扩展名按类型（APNG为png，WebM为webm）。
    private func outputURL(_ kind: RecordingExport, date: Date) throws -> URL {
        // datedDirectory统一创建媒体分类和日期目录，最终发布再处理同名冲突。
        let directory = try ScreenshotStorage.datedDirectory(
            basePath: UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey),
            category: ScreenshotStorage.Category(kind), date: date)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("录屏-\(formatter.string(from: date)).\(kind.fileExtension)")
    }

    /// id为Flutter结果身份；返回绑定当前完整视频的系统播放器，迟到视图不读取新会话。
    fileprivate func makePreview(id: String) -> NSView {
        let view = AVPlayerView()
        guard id == service.id, [.videoReady, .converting].contains(service.phase) else { return view }
        do {
            let url = try service.previewURL()
            if playerSession != id {
                releasePlayer()
                player = AVPlayer(url: url)
                playerSession = id
            }
            view.player = player
            view.controlsStyle = .floating
            playerView = view
        } catch { showError(error) }
        return view
    }

    /// 无参数；在结果页播放器中从裁剪起点播放到终点（未裁剪为完整视频），不另开窗口。
    private func preview() async throws {
        let token = service.id
        let url = try service.recordingURL()
        let info = try await GIFExporter.metadata(url)
        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        let range = service.trim ?? CMTimeRange(start: .zero, duration: CMTime(seconds: info.duration, preferredTimescale: 60000))
        let item = AVPlayerItem(url: url)
        // 新播放项沿用裁剪端点，再次进入裁剪时手柄停在上次确认的位置。
        item.reversePlaybackEndTime = range.start
        item.forwardPlaybackEndTime = range.end
        if player == nil { player = AVPlayer(); playerSession = token }
        player?.replaceCurrentItem(with: item)
        playerView?.player = player
        await player?.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        guard token == service.id else { return }
        player?.play()
    }

    /// 无参数；让结果页播放器进入系统裁剪模式并等待用户操作。点「裁剪」把区间交给资源层，
    /// 首尾都未移动时恢复完整视频；点「取消」保持原裁剪（#110）。
    private func trim() async throws {
        let token = service.id
        _ = try service.recordingURL()
        guard let playerView, let item = player?.currentItem, playerView.canBeginTrimming else {
            throw GIFExporter.ExportError(message: "播放器尚未就绪，请稍后再试。")
        }
        player?.pause()
        let result = await playerView.beginTrimming()
        guard token == service.id, result == .okButton else { return }
        // 未设置的端点为无效时间，按视频起点或终点处理。
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        try service.setTrim(start <= .zero && end >= item.duration ? nil : CMTimeRange(start: start, end: end))
    }
}

/// Flutter结果页的系统视频视图工厂；创建视图发生在Flutter的macOS主线程。
private final class CapturePreviewFactory: NSObject, FlutterPlatformViewFactory {
    private weak var owner: CaptureWindowController?

    /// owner为媒体资源协调者；工厂不延长工具会话寿命。
    init(owner: CaptureWindowController) { self.owner = owner }

    /// 无参数；返回与Dart创建参数相同的标准编解码器。
    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }

    /// viewId由Flutter分配，args含会话id；返回主线程创建的AVPlayerView。
    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        MainActor.assumeIsolated {
            guard let id = (args as? [String: Any])?["id"] as? String, let owner else { return NSView() }
            return owner.makePreview(id: id)
        }
    }
}

/// 采集悬浮条的非激活面板；按钮可接收键盘，采集不抢主应用。
private final class CaptureControlPanel: NSPanel {
    /// 无参数；允许用户点击后的键盘输入，不主动将本应用变成主窗口。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 录制中的实时选区阴影；不持有冻结图像，不处理输入，绘制内容被系统捕获过滤器排除。
final class CaptureShadeView: NSView {
    /// 应用窗口的本屏局部矩形并集；nil表示普通区域遮罩，空数组表示本屏无应用窗口。
    var contentRects: [NSRect]? { didSet { needsDisplay = true } }
    /// selection为本显示器局部点坐标；变化后重绘阴影和1pt选区边框。
    var selection = NSRect.zero { didSet { needsDisplay = true } }
    private(set) var hintView: NSGlassEffectView?
    private var hintGeneration = 0

    /// text为长截图过程提示，isError选择错误语义色；visible为本屏可用区、avoiding为控制面板和缩略图（均为本视图坐标）。
    /// 按选区上、下、左、右寻找距选区8pt的位置，都放不下才放在选区正中央；显示1000ms。
    /// 样式沿用#67文字反馈：原生玻璃r8、padding水平12/垂直5、正文13/18、最大宽240pt，居中时不超过选区宽减16pt。
    func showHint(_ text: String, isError: Bool, visible: NSRect? = nil, avoiding: [NSRect] = []) {
        hintView?.removeFromSuperview()
        let padding = AppConstants.scrollHintPadding
        let outside = Self.hintTextSize(text, width: AppConstants.scrollHintMaxWidth - padding.width * 2)
        let centeredWidth = min(AppConstants.scrollHintMaxWidth, selection.width - AppConstants.captureControlGap * 2)
        let inside = Self.hintTextSize(text, width: max(1, centeredWidth - padding.width * 2))
        let frame = Self.hintFrame(
            outside: NSSize(width: outside.width + padding.width * 2, height: outside.height + padding.height * 2),
            inside: NSSize(width: inside.width + padding.width * 2, height: inside.height + padding.height * 2),
            selection: selection, visible: visible ?? bounds, avoiding: avoiding)
        let textSize = NSSize(width: frame.width - padding.width * 2, height: frame.height - padding.height * 2)
        let label = NSTextField(wrappingLabelWithString: text)
        label.attributedStringValue = Self.hintText(text, isError: isError)
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: textSize)
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.addSubview(label)
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = AppConstants.scrollHintRadius
        glass.contentView = content
        addSubview(glass)
        hintView = glass
        NSAccessibility.post(element: glass, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hintGeneration += 1
        let generation = hintGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(AppConstants.scrollHintDurationMs))
            guard let self, self.hintGeneration == generation else { return }
            self.hintView?.removeFromSuperview()
            self.hintView = nil
        }
    }

    /// outside/inside为选区外与居中时的提示外框尺寸；返回第一个完整位于可用区、离选区8pt且不压住避让区的位置，
    /// 顺序为上、下、左、右，均不可用时居中于选区。坐标为AppKit本视图坐标。
    static func hintFrame(outside: NSSize, inside: NSSize, selection: NSRect, visible: NSRect, avoiding: [NSRect]) -> NSRect {
        let gap = AppConstants.captureControlGap
        let width = outside.width
        let height = outside.height
        /// value为期望坐标；沿选区边平移进可用区，不改变与选区的8pt间距。
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), high) }
        let candidates = [
            NSRect(x: clamp(selection.midX - width / 2, visible.minX, visible.maxX - width), y: selection.maxY + gap,
                   width: width, height: height),
            NSRect(x: clamp(selection.midX - width / 2, visible.minX, visible.maxX - width), y: selection.minY - gap - height,
                   width: width, height: height),
            NSRect(x: selection.minX - gap - width, y: clamp(selection.midY - height / 2, visible.minY, visible.maxY - height),
                   width: width, height: height),
            NSRect(x: selection.maxX + gap, y: clamp(selection.midY - height / 2, visible.minY, visible.maxY - height),
                   width: width, height: height),
        ]
        for candidate in candidates.map({ NSRect(x: $0.minX.rounded(), y: $0.minY.rounded(), width: $0.width, height: $0.height) }) where visible.contains(candidate)
            && !avoiding.contains(where: { $0.intersects(candidate) }) {
            return candidate
        }
        return NSRect(x: (selection.midX - inside.width / 2).rounded(), y: (selection.midY - inside.height / 2).rounded(),
                      width: inside.width, height: inside.height)
    }

    /// text/isError为提示内容与语义；返回正文13/18、居中的富文本。
    private static func hintText(_ text: String, isError: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isError ? NSColor.systemRed : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    /// text为提示，width为可用文字宽；返回换行后的整点文字尺寸，宽度不超过width。
    private static func hintTextSize(_ text: String, width: CGFloat) -> NSSize {
        let bounds = hintText(text, isError: false).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(min(bounds.width, width)), height: max(18, ceil(bounds.height)))
    }

    /// dirtyRect为系统重绘范围；在选区外输出60%黑色，选区内部保持透明。
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let contentRects {
            // 先绘制遮罩，再以clear逐个开孔，重叠窗口也保持透明。
            NSColor.black.withAlphaComponent(AppConstants.captureShadeOpacity).setFill()
            bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            for rect in contentRects { rect.fill() }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            for rect in contentRects { NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke() }
        } else {
            path.appendRect(selection)
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(AppConstants.captureShadeOpacity).setFill()
            path.fill()
        }
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }
}

/// 长截图实时缩略图：原生玻璃r8、4pt内边距，图像圆角4pt，回退目标用2pt错误语义色框标出；不接收鼠标。
final class ScrollPreviewView: NSView {
    private let glass = NSGlassEffectView()
    private let content = NSView()
    let imageView = NSImageView()
    let targetView = NSView()

    /// 无参数；创建空缩略图，update后才有尺寸。
    init() {
        super.init(frame: .zero)
        glass.cornerRadius = AppConstants.scrollHintRadius
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = AppConstants.scrollPreviewImageRadius
        imageView.layer?.masksToBounds = true
        targetView.wantsLayer = true
        targetView.layer?.borderWidth = AppConstants.scrollPreviewTargetLine
        targetView.isHidden = true
        content.addSubview(imageView)
        content.addSubview(targetView)
        glass.contentView = content
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("ScrollPreviewView requires programmatic initialization") }

    /// preview为长图底部缩略图像素，scale为所在屏倍率；更新图像与回退目标框，返回含内边距的外框尺寸。
    @discardableResult
    func update(_ preview: ScrollStitcher.Preview, scale: CGFloat) -> NSSize {
        let inset = AppConstants.scrollPreviewInset
        let size = NSSize(width: CGFloat(preview.image.width) / scale, height: CGFloat(preview.image.height) / scale)
        setFrameSize(NSSize(width: size.width + inset * 2, height: size.height + inset * 2))
        glass.frame = bounds
        content.frame = glass.bounds
        imageView.frame = NSRect(x: inset, y: inset, width: size.width, height: size.height)
        imageView.image = NSImage(cgImage: preview.image, size: size)
        if let target = preview.target, !target.isEmpty {
            // 目标框为图像像素、顶部原点；换成AppKit点坐标后叠在图像上。
            targetView.layer?.borderColor = NSColor.systemRed.cgColor
            targetView.frame = NSRect(x: inset + target.minX / scale, y: inset + size.height - target.maxY / scale,
                                      width: target.width / scale, height: target.height / scale)
            targetView.isHidden = false
        } else { targetView.isHidden = true }
        return frame.size
    }

    /// point为窗口坐标；缩略图只展示，鼠标穿透到来源应用。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
