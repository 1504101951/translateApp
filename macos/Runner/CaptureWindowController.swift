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

    /// 无参数；返回菜单与悬浮条停止可作用的真实资源阶段。
    var canStop: Bool { [.recording, .scrolling, .paused].contains(service.phase) }

    /// 无参数；有资源或结果时必须明确处理，不能被另一工具入口覆盖。
    var hasPendingCapture: Bool { ![.idle, .failed].contains(service.phase) }

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
            if phase != .preparing {
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            }
            // 只记录启动阶段切换的同步UI工作，录制计时通知不产生逐秒诊断日志。
            if transition && [.preparing, .recording].contains(phase) {
                CaptureStartupLog.record("ui-\(phase.rawValue)-sync", since: started)
            }
        }
        service.onActiveChanged = { [weak self] active in self?.onActiveChanged?(active) }
    }

    /// 无参数；终止任务并释放播放器文件引用，再关闭本工具的面板和引擎。
    func shutdown() async {
        shuttingDown = true
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
                    originScreen = NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id.uint32Value
                    }
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

    /// 无参数；懒建透明Flutter面板，只承载当前状态，不负责选区或来源准备。
    private func createPanel() {
        guard window == nil else { return }
        let started = ContinuousClock.now
        // 记录真实采集引擎初始化，便于区分界面准备与ScreenCaptureKit启动耗时。
        defer { CaptureStartupLog.record("capture-ui-create-sync", since: started) }
        let engine = FlutterEngine(name: AppConstants.captureEntrypoint, project: nil, allowHeadlessExecution: false)
        let channel = FlutterMethodChannel(name: AppConstants.captureChannel, binaryMessenger: engine.binaryMessenger)
        self.engine = engine
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        guard engine.run(withEntrypoint: AppConstants.captureEntrypoint) else {
            channel.setMethodCallHandler(nil)
            engine.shutDownEngine()
            self.engine = nil
            self.channel = nil
            return
        }
        RegisterGeneratedPlugins(registry: flutter)
        NativeGlassFactory.register(with: flutter)
        flutter.registrar(forPlugin: "CaptureVideoPreview").register(
            CapturePreviewFactory(owner: self), withId: AppConstants.captureVideoPreview)
        // makeWindow从创建时就明确是否非激活，避免结果窗口继承采集控制条的焦点约束。
        let panel = Self.makeWindow(compact: true)
        panel.delegate = self
        NativeGlassFactory.installContent(flutter, in: panel)
        window = panel
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
            // 最小内容保留右侧四个操作、内外间距和至少1pt视频，缩放不裁掉工具栏。
            window.contentMinSize = NSSize(width: AppConstants.captureResultToolbarWidth + AppConstants.captureControlGap * 3 + 1,
                height: AppConstants.captureResultToolbarHeight + AppConstants.captureControlGap * 2)
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
        // 右侧48pt工具栏、8pt间隔和左右各8pt外边距；纵向四气泡含padding共180pt。
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
        var state = service.snapshot()
        state["previewScale"] = originScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return state
    }

    /// force表示用户重新打开隐藏结果；资源通知只同步所需布局和可见录制范围。
    func present(force: Bool = false) {
        let previous = lastPhase
        lastPhase = service.phase
        guard !shuttingDown else { return }
        let showingResult = [.videoReady, .converting, .imageReady].contains(service.phase)
        // 结果先就位再撤遮罩；采集中仍立即更新选区阴影。
        if !showingResult { updateCaptureShades() }
        if [.idle, .failed].contains(service.phase) {
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
        let compact = [.preparing, .recording, .scrolling, .pausing, .paused, .finalizing].contains(service.phase)
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
        guard let window else {
            if showingResult { showError(GIFExporter.ExportError(message: "无法打开结果窗口。")) }
            return
        }
        let changed = compactPresentation != compact
        let controlSize = AppConstants.captureControlSize
        let sizeChanged = compact && window.contentView?.frame.size != controlSize
        if changed {
            compactPresentation = compact
            (window.contentViewController as? NativeGlassWindowContent)?.windowCanvas.isHidden = compact
        }
        if service.phase == .preparing {
            // 隐藏的idle界面没有可提交内容；先通知准备态，再缩放，避免Flutter同步等待空白帧直到超时。
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
        window.contentMinSize = image
            ? NSSize(width: 320, height: 240)
            : NSSize(width: AppConstants.captureResultToolbarWidth + AppConstants.captureControlGap * 3 + 1,
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

    /// 无参数；在与采集范围相交的显示器上绘制实时阴影，透明洞和全部窗口均穿透鼠标。
    private func updateCaptureShades() {
        guard !shuttingDown, [.preparing, .recording, .scrolling, .pausing, .paused].contains(service.phase),
              let frame = service.captureFrame else {
            for window in captureShades.values { window.close() }
            captureShades.removeAll()
            return
        }
        var active = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens where screen.frame.intersects(frame) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = number.uint32Value
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
        Task { @MainActor in
            // discard统一系统关闭和Flutter操作；内部窗口切换已移除delegate，不经过此入口。
            await discard()
        }
        return false
    }

    /// 无参数/返回值；单击立即停止当前任务并清理临时媒体，已经保存的文件不参与删除。
    private func discard() async {
        guard !discarding else { return }
        discarding = true
        defer { discarding = false }
        // releasePlayer先撤销文件引用，再由cancel结束任务并清理临时目录。
        releasePlayer()
        await service.cancel()
    }

    /// 无参数；由菜单发出停止请求，完成后的状态通知负责展示结果。
    func stop() {
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
                    let target = try outputURL(extension: "mp4", date: Date())
                    try service.saveVideo(to: target)
                case AppConstants.previewRecordingMethod:
                    try await preview()
                case AppConstants.exportRecordingGIFMethod:
                    let requestedAt = Date()
                    let source = try service.recordingURL()
                    let info = try await GIFExporter.metadata(source)
                    guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
                    // 每次导出读取已提交设置；结果窗口不缓存另一份可编辑GIF参数。
                    let settings = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) ?? [:]
                    let options = GIFExporter.Options(
                        framesPerSecond: settings[AppConstants.gifFramesPerSecondKey] as? Int ?? 10,
                        maximumWidth: settings[AppConstants.gifMaximumWidthKey] as? Int)
                    _ = try options.validate(duration: info.duration, sourceWidth: info.width)
                    let target = try outputURL(extension: "gif", date: requestedAt)
                    try service.exportGIF(options: options, to: target)
                case AppConstants.cancelGIFExportMethod:
                    service.cancelGIF()
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
                        extension: "png")
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

    /// fileExtension为mp4或gif，date为点击操作时刻；返回分类日期路径，文件名与目录共用同一日期。
    private func outputURL(extension fileExtension: String, date: Date) throws -> URL {
        // datedDirectory统一创建媒体分类和日期目录，最终发布再处理同名冲突。
        let directory = try ScreenshotStorage.datedDirectory(
            basePath: UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey),
            extension: fileExtension, date: date)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("录屏-\(formatter.string(from: date)).\(fileExtension)")
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

    /// 无参数；在结果页播放器中从头播放完整视频，不另开窗口。
    private func preview() async throws {
        let token = service.id
        let url = try service.recordingURL()
        let info = try await GIFExporter.metadata(url)
        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: info.duration, preferredTimescale: 60000)
        if player == nil { player = AVPlayer(); playerSession = token }
        player?.replaceCurrentItem(with: item)
        playerView?.player = player
        await player?.seek(to: CMTime.zero, toleranceBefore: .zero, toleranceAfter: .zero)
        guard token == service.id else { return }
        player?.play()
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
