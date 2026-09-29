import AppKit
import AVKit
import FlutterMacOS
import UniformTypeIdentifiers

/// 采集工具协调者；截图层确认选区，采集与暂停时显示实时阴影与三按钮悬浮条，完成后展示结果。
@MainActor
final class CaptureWindowController: NSObject, NSWindowDelegate {
    let service = MediaCaptureService()
    private let screenshot: ScreenshotWindowController
    private var engine: FlutterEngine?
    private var channel: FlutterMethodChannel?
    private var window: CaptureControlPanel?
    private var player: AVPlayer?
    private weak var playerView: AVPlayerView?
    private var playerSession: String?
    private var regionTarget = false
    private var choosing = false
    private var shuttingDown = false
    private var compactPresentation: Bool?
    private var lastPhase = CapturePhase.idle
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
            // 先更新原生承载尺寸，再把同一资源快照交给Flutter。
            self.present()
            self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
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
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }

    /// kind为已校验的录制目标，scrolling指定长截图；复用当前截图，准备失败抛出并保留编辑内容。
    func prepare(kind: String, scrolling: Bool, region: MediaCaptureService.Region?) throws {
        guard !shuttingDown, !hasPendingCapture, !choosing else {
            throw GIFExporter.ExportError(message: "请先结束或处理当前采集。")
        }
        guard kind == "region" else {
            // 屏幕和窗口保留实时枚举能力，取消目标菜单不会关闭截图编辑器。
            chooseRecordingSource(kind: kind)
            return
        }
        if scrolling {
            guard let region else { throw GIFExporter.ExportError(message: "长截图缺少当前选区。") }
            start(["kind": "region"], scrolling: true, region: region)
            return
        }
        let token = service.id
        // 在当前冻结帧上建立确认回调；Dart的选区和标注草稿保持原样。
        try screenshot.prepareSelection() { [weak self] region in
            guard let self else { return }
            self.choosing = false
            guard !self.shuttingDown, token == self.service.id, let region else { return }
            self.start(["kind": "region"], scrolling: scrolling, region: region)
        }
        choosing = true
    }

    /// kind为display或window；实时查询目标，以系统菜单显式选择并开始，无准备表单。
    private func chooseRecordingSource(kind: String) {
        guard !shuttingDown else { return }
        guard !hasPendingCapture else { present(force: true); return }
        guard !choosing else { return }
        guard let screenshotID = screenshot.liveCaptureID else { return }
        choosing = true
        let token = service.id
        let point = NSEvent.mouseLocation
        originScreen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        Task { @MainActor in
            defer { choosing = false }
            do {
                let sources = try await service.sources().filter { $0["kind"] as? String == kind }
                guard !shuttingDown, token == service.id, screenshot.liveCaptureID == screenshotID else { return }
                guard !sources.isEmpty else { throw GIFExporter.ExportError(message: "没有可录制的目标。") }
                let menu = NSMenu()
                menu.autoenablesItems = false
                for source in sources {
                    let item = NSMenuItem(title: source["name"] as? String ?? "", action: #selector(recordSource(_:)), keyEquivalent: "")
                    item.target = self
                    // 菜单跟踪期间截图仍可能被全局快捷键替换，动作必须带上打开菜单的截图身份。
                    var choice = source
                    choice["captureID"] = screenshotID
                    item.representedObject = choice
                    menu.addItem(item)
                }
                // 菜单跟踪时Escape/回车属于系统菜单，不能被截图的全局按键路由消费。
                screenshot.nativeMenuOpen = true
                defer { screenshot.nativeMenuOpen = false }
                menu.popUp(positioning: nil, at: point, in: nil)
            } catch { showError(error) }
        }
    }

    /// item携带用户在目标菜单确认的来源；调用资源层前不保留可变菜单引用。
    @objc private func recordSource(_ item: NSMenuItem) {
        guard let source = item.representedObject as? [String: Any], !hasPendingCapture,
              let screenshotID = source["captureID"] as? String,
              screenshotID == screenshot.liveCaptureID else { return }
        start(source, scrolling: false)
    }

    /// source为明确目标，scrolling决定静帧或视频，region为本次选区；返回后异步启动资源。
    private func start(_ source: [String: Any], scrolling: Bool, region: MediaCaptureService.Region? = nil) {
        let token = service.id
        guard let screenshotID = screenshot.liveCaptureID else { return }
        Task { @MainActor in
            guard !shuttingDown, token == service.id, !hasPendingCapture,
                  screenshotID == screenshot.liveCaptureID else { return }
            do {
                // 目标已经由用户确认；先撤下冻结编辑层，再由实时遮罩承载录制。
                screenshot.closeForCapture()
                // 选区与开始在同一主执行器任务中提交，排队命令不能替换本次目标。
                if let region { try service.select(region) }
                regionTarget = source["kind"] as? String == "region"
                if source["kind"] as? String == "display", let id = source["sourceID"] as? NSNumber {
                    originScreen = NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id.uint32Value
                    }
                }
                if scrolling { try await service.startScrolling() }
                else { try await service.startRecording(source) }
            } catch is CancellationError {
                // 准备期间用户停止已清理会话，不把明确取消显示成采集故障。
            } catch {
                if service.phase != .failed { showError(error) }
            }
        }
    }

    /// 无参数；懒建透明Flutter面板，只承载当前状态，不负责选区或来源准备。
    private func createPanel() {
        guard window == nil else { return }
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
        let panel = CaptureControlPanel(contentRect: NSRect(origin: .zero, size: AppConstants.captureControlSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NativeGlassFactory.installContent(flutter, in: panel)
        window = panel
    }

    /// 无参数；在资源快照中补充实际采集状态，Flutter与原生窗口使用同一生命周期。
    private func captureState() -> [String: Any] {
        service.snapshot()
    }

    /// force表示用户重新打开隐藏结果；资源通知只同步所需布局和可见录制范围。
    func present(force: Bool = false) {
        let previous = lastPhase
        lastPhase = service.phase
        guard !shuttingDown else { return }
        // 采集与暂停都保留固定可见区域，结束或放弃才撤下。
        updateCaptureShades()
        if [.idle, .failed].contains(service.phase) {
            window?.orderOut(nil)
            compactPresentation = nil
            releasePlayer()
            if previous != service.phase, let message = service.snapshot()["error"] as? String {
                showError(GIFExporter.ExportError(message: message))
            }
            return
        }
        if service.phase == .imageReady, previous != .imageReady {
            let state = service.snapshot()
            guard let bytes = state["imageBytes"] as? FlutterStandardTypedData,
                  let width = state["width"] as? Int, let height = state["height"] as? Int else { return }
            window?.orderOut(nil)
            // 图片编辑器接管内存结果后释放采集会话，不再显示额外的长图结果页面。
            screenshot.presentImage(bytes.data, width: width, height: height, warning: state["warning"] as? String)
            service.clear()
            return
        }
        createPanel()
        guard let window else { return }
        let compact = [.preparing, .recording, .scrolling, .pausing, .paused, .finalizing].contains(service.phase)
        let changed = compactPresentation != compact
        let controlSize = AppConstants.captureControlSize
        let sizeChanged = compact && window.contentView?.frame.size != controlSize
        if changed {
            compactPresentation = compact
            window.styleMask = compact
                ? [.borderless, .nonactivatingPanel, .fullSizeContentView]
                : [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel, .fullSizeContentView]
            (window.contentViewController as? NativeGlassWindowContent)?.windowCanvas.isHidden = compact
            window.title = "录制结果"
        }
        if changed || sizeChanged {
            window.minSize = compact ? controlSize : AppConstants.captureResultMinimumSize
            window.setContentSize(compact ? controlSize : AppConstants.captureResultSize)
            if !compact { window.center() }
        }
        // 操作按钮始终高于同应用的阴影窗口；全部由捕获过滤器排除。
        window.level = service.phase == .recording ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .floating
        if compact { placeControls() }
        if changed || sizeChanged || force {
            if compact { window.orderFrontRegardless() }
            else { window.makeKeyAndOrderFront(nil) }
        }
    }

    /// 无参数；把控制面板放在实际录制范围或已确认选区附近，并限制在目标屏幕可见范围。
    private func placeControls() {
        guard let window else { return }
        let regionScreen = regionTarget ? service.region.flatMap { region in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID }
        } : nil
        var target = service.captureFrame
        if target == nil, let region = service.region, let regionScreen {
            target = NSRect(x: regionScreen.frame.minX + region.rect.minX / region.scale,
                y: regionScreen.frame.maxY - region.rect.maxY / region.scale,
                width: region.rect.width / region.scale, height: region.rect.height / region.scale)
        }
        let targetScreen = target.flatMap { frame in
            NSScreen.screens.filter { $0.frame.intersects(frame) }.max {
                let first = $0.frame.intersection(frame)
                let second = $1.frame.intersection(frame)
                return first.width * first.height < second.width * second.height
            }
        }
        guard let screen = targetScreen ?? regionScreen ?? originScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let gap = AppConstants.captureControlGap
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + gap)
        if let target {
            origin.x = target.minX
            origin.y = target.minY - size.height - gap >= visible.minY
                ? target.minY - size.height - gap : target.maxY + gap
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(origin)
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

    /// sender为已完成结果窗口；关闭仅隐藏并暂停播放器，结果与菜单入口仍保留。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        player?.pause()
        sender.orderOut(nil)
        return false
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

    /// call为当前会话的控制或结果操作；异步入口重复检查身份，不提供准备表单协议。
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
                    guard let window else { break }
                    let alert = NSAlert()
                    alert.messageText = "放弃当前采集？"
                    alert.informativeText = "未保存的录制或长图将被删除，已经保存的文件会保留。"
                    alert.addButton(withTitle: "继续保留")
                    alert.addButton(withTitle: "放弃")
                    let response = await alert.beginSheetModal(for: window)
                    guard response == .alertSecondButtonReturn else { break }
                    guard token == service.id else { throw GIFExporter.ExportError(message: "采集会话已改变，请重试。") }
                    releasePlayer()
                    await service.cancel()
                case AppConstants.saveRecordingMethod:
                    _ = try service.recordingURL()
                    if let target = await chooseOutput(type: .mpeg4Movie, name: "录屏-\(filenameTimestamp()).mp4") {
                        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
                        try service.saveVideo(to: target)
                    }
                case AppConstants.previewRecordingMethod:
                    try await preview(args)
                case AppConstants.exportRecordingGIFMethod:
                    let source = try service.recordingURL()
                    let info = try await GIFExporter.metadata(source)
                    guard let start = args["start"] as? Double, let end = args["end"] as? Double,
                          let fps = args["fps"] as? Int, let width = args["width"] as? Int else {
                        throw GIFExporter.ExportError(message: "缺少GIF片段、帧率或宽度。")
                    }
                    let options = GIFExporter.Options(start: start, end: end, framesPerSecond: fps, width: width)
                    _ = try options.validate(duration: info.duration, sourceWidth: info.width)
                    if let target = await chooseOutput(type: .gif, name: "录屏-\(filenameTimestamp()).gif") {
                        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
                        try service.exportGIF(options: options, to: target)
                    }
                case AppConstants.cancelGIFExportMethod:
                    service.cancelGIF()
                default:
                    result(FlutterMethodNotImplemented); return
                }
                result(captureState())
            } catch {
                result(FlutterError(code: AppConstants.captureFailedError, message: error.localizedDescription, details: nil))
            }
        }
    }

    /// type/name为输出类型和默认名；取消返回nil，系统面板承担覆盖确认。
    private func chooseOutput(type: UTType, name: String) async -> URL? {
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url : nil
    }

    /// 无参数；返回不携带来源窗口标题的本地媒体文件时间戳。
    private func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
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

    /// args为可选起止秒数；在结果页播放器中预览完整视频或片段，不另开准备窗口。
    private func preview(_ args: [String: Any]) async throws {
        let token = service.id
        let url = try service.recordingURL()
        let info = try await GIFExporter.metadata(url)
        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        let start = args["start"] as? Double ?? 0
        let end = args["end"] as? Double ?? info.duration
        guard start.isFinite, end.isFinite, start >= 0, start < end, end <= info.duration else {
            throw GIFExporter.ExportError(message: "预览时间必须位于录制范围内。")
        }
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 60000)
        if player == nil { player = AVPlayer(); playerSession = token }
        player?.replaceCurrentItem(with: item)
        playerView?.player = player
        await player?.seek(to: CMTime(seconds: start, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
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

/// 悬浮条与结果共享的非激活面板；结果数值字段可接收键盘，采集不抢主应用。
private final class CaptureControlPanel: NSPanel {
    /// 无参数；允许用户点击后的键盘输入，不主动将本应用变成主窗口。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 录制中的实时选区阴影；不持有冻结图像，不处理输入，绘制内容被系统捕获过滤器排除。
final class CaptureShadeView: NSView {
    /// selection为本显示器局部点坐标；变化后重绘阴影和1pt选区边框。
    var selection = NSRect.zero { didSet { needsDisplay = true } }

    /// dirtyRect为系统重绘范围；在选区外输出60%黑色，选区内部保持透明。
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.appendRect(selection)
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(AppConstants.captureShadeOpacity).setFill()
        path.fill()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }
}
