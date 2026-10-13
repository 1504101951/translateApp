import AppKit
import FlutterMacOS

/// 不抢来源应用焦点的实时翻译结果窗。准备阶段可移动缩放，开始后锁定。
@MainActor
final class LiveRegionWindowController: NSObject, NSWindowDelegate {
    /// 翻译结果窗的默认逻辑尺寸，沿用选区译文窗 720×420。
    static let defaultSize = NSSize(width: 720, height: 420)
    /// 可缩放下限，沿用截图结果窗 320×240。
    static let minimumSize = NSSize(width: 320, height: 240)

    var onClose: (() -> Void)?
    private var engine: FlutterEngine?
    private var channel: FlutterMethodChannel?
    private var panel: NSPanel?
    private var lastState: [String: Any] = [:]
    private var locked = false

    /// screen 为截图所在显示器。把窗口恢复到默认尺寸并允许拖动缩放，不激活应用。
    func show(on screen: NSScreen?) {
        let panel = ensurePanel()
        unlock(panel)
        let visible = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8)
            ?? NSRect(origin: .zero, size: Self.defaultSize)
        let size = NSSize(
            width: min(Self.defaultSize.width, visible.width),
            height: min(Self.defaultSize.height, visible.height)
        )
        panel.setFrame(NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), display: true)
        panel.orderFrontRegardless()
    }

    /// 无参数。固定当前尺寸和位置，暂停也不解除。
    func lock() {
        guard let panel else { return }
        locked = true
        panel.styleMask.remove(.resizable)
        panel.setContentSize(panel.contentRect(forFrameRect: panel.frame).size)
        let size = panel.frame.size
        panel.minSize = size
        panel.maxSize = size
        panel.isMovable = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    /// 无参数。隐藏准备窗。已经开始的会话不从这里关闭。
    func hide() {
        panel?.orderOut(nil)
    }

    /// state 为不含密钥的业务快照。只替换窗口内容。
    func publish(_ state: [String: Any]) {
        lastState = state
        channel?.invokeMethod(AppConstants.liveRegionStateMethod, arguments: state)
    }

    /// 无参数；释放引擎和面板。
    func close() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        lastState = [:]
        locked = false
    }

    /// sender 为用户关闭的结果窗。按放弃处理，窗口由会话结束后关闭。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = LiveRegionPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "实时翻译"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = Self.minimumSize
        panel.delegate = self
        let engine = FlutterEngine(name: AppConstants.liveRegionEntrypoint, project: nil, allowHeadlessExecution: false)
        let channel = FlutterMethodChannel(name: AppConstants.liveRegionChannel, binaryMessenger: engine.binaryMessenger)
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        guard engine.run(withEntrypoint: AppConstants.liveRegionEntrypoint) else {
            engine.shutDownEngine()
            self.panel = panel
            return panel
        }
        RegisterGeneratedPlugins(registry: flutter)
        NativeGlassFactory.register(with: flutter)
        NativeGlassFactory.installContent(flutter, in: panel)
        channel.setMethodCallHandler { [weak self] call, result in
            if call.method == AppConstants.getLiveRegionStateMethod {
                result(self?.lastState ?? [:])
                return
            }
            result(FlutterMethodNotImplemented)
        }
        self.engine = engine
        self.channel = channel
        self.panel = panel
        return panel
    }

    /// panel 为准备阶段窗口。恢复拖动和缩放下限，不记住上一次会话的尺寸。
    private func unlock(_ panel: NSPanel) {
        locked = false
        panel.styleMask.insert(.resizable)
        panel.minSize = Self.minimumSize
        panel.maxSize = NSSize(width: 10000, height: 10000)
        panel.isMovable = true
        panel.standardWindowButton(.zoomButton)?.isEnabled = true
    }
}

/// 实时翻译结果窗不成为 key，避免占用正在被翻译的应用的键盘。
final class LiveRegionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 把整段译文缩进段落块矩形并在矩形内换行。字号可以很小，绘制不超出该矩形。
final class LiveFitTextView: NSView {
    var text = "" { didSet { needsDisplay = true } }

    /// dirtyRect 为需要重画的区域。白底盖住原文，黑色半粗体缩进框内。
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0xCC / 255).setFill()
        bounds.fill()
        guard !text.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        let fitted = fittedFont
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fitted,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ]
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: bounds.width, height: 10_000),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
        let origin = NSPoint(
            x: 0,
            y: max(0, (bounds.height - measured.height) / 2)
        )
        (text as NSString).draw(
            with: NSRect(origin: origin, size: NSSize(width: bounds.width, height: bounds.height)),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
    }

    /// 无参数。返回能把整段留在当前矩形里的最大半粗体字号。
    private var fittedFont: NSFont {
        var low = 1.0
        var high = max(1, bounds.height)
        var best = low
        while high - low > 0.5 {
            let size = (low + high) / 2
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: bounds.width, height: 10_000),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .paragraphStyle: style]
            )
            if rect.height <= bounds.height + 0.5, rect.width <= bounds.width + 0.5 {
                best = size
                low = size
            } else {
                high = size
            }
        }
        return NSFont.systemFont(ofSize: best, weight: .semibold)
    }
}

/// 点击穿透的译文盖层。每个段落块一个窗口，全部属于本应用，因此不会被再次捕获。
@MainActor
final class LiveTextOverlay {
    private var panels: [NSPanel] = []

    /// chips 为已归属译文的屏幕矩形。空列表撤掉全部盖层。
    func apply(_ chips: [[String: Any]]) {
        while panels.count < chips.count {
            panels.append(makePanel())
        }
        for index in chips.indices {
            let chip = chips[index]
            guard let text = chip["text"] as? String,
                  let x = chip["x"] as? Double,
                  let y = chip["y"] as? Double,
                  let width = chip["width"] as? Double,
                  let height = chip["height"] as? Double,
                  width > 1, height > 1 else {
                panels[index].orderOut(nil)
                continue
            }
            let panel = panels[index]
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            (panel.contentView as? LiveFitTextView)?.text = text
            panel.orderFrontRegardless()
        }
        if chips.count < panels.count {
            for panel in panels[chips.count...] {
                panel.orderOut(nil)
            }
        }
    }

    /// 无参数。隐藏盖层，不释放窗口池。
    func clear() {
        for panel in panels {
            panel.orderOut(nil)
        }
    }

    /// 无参数。返回不接收鼠标、不成为 key 的盖层窗。
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = LiveFitTextView(frame: .zero)
        return panel
    }
}

/// 连接结果窗、未编码捕获和主引擎会话。不保存译文。
@MainActor
final class LiveRegionCoordinator {
    private let bridge: MacPlatformBridge
    private let controls: CaptureWindowController
    private let overlay = LiveTextOverlay()
    private let capture = LiveRegionCapture()
    private var generation = 0
    private var running = false
    private var ended = false
    private var busy = false
    private var source: [String: Any] = [:]
    private var region: MediaCaptureService.Region?

    /// bridge 转发主引擎命令，controls 复用采集悬浮条。
    init(bridge: MacPlatformBridge, controls: CaptureWindowController) {
        self.bridge = bridge
        self.controls = controls
        capture.onRecognized = { [weak self] generation, blocks, failure in
            self?.sendOcr(generation: generation, blocks: blocks, failure: failure)
        }
        capture.onUnavailable = { [weak self] message in
            Task { await self?.unavailable(message) }
        }
        capture.onFrame = { [weak self] frame in
            self?.controls.setLiveShade(frame)
        }
        controls.onLivePause = { [weak self] paused in
            Task { paused ? await self?.pause() : await self?.resume() }
        }
        controls.onLiveStop = { [weak self] in
            Task { await self?.end() }
        }
        controls.onLiveCancel = { [weak self] in
            Task { await self?.discard() }
        }
    }

    /// screen 为截图显示器。准备阶段先建好录制同款控制条，开始前不显示。
    func preview(on screen: NSScreen?) {
        controls.prepareControls()
    }

    /// 无参数。准备阶段没有预览窗可关。
    func cancelPreview() {}

    /// source 为截图确认的目标，region 为区域选区。锁定预览并开始识别。
    func begin(source: [String: Any], region: MediaCaptureService.Region?) async throws {
        guard !running, !controls.hasPendingCapture else {
            throw GIFExporter.ExportError(message: "请先结束或放弃当前采集。")
        }
        self.source = source
        self.region = region
        generation += 1
        let token = generation
        running = true
        ended = false
        let displayID = (source["sourceID"] as? NSNumber)?.uint32Value
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        overlay.clear()
        bridge.screenshot.hideForCapture()
        controls.showLiveControls(id: "live-\(token)", screen: screen)
        StatusBarController.shared.setLiveAbort(true) { [weak self] in
            Task { await self?.end() }
        }
        do {
            try await command("start", generation: token)
            try await capture.start(source: source, region: region, generation: token)
        } catch {
            generation += 1
            await capture.stop()
            if token != generation { try? await command("discard", generation: generation) }
            running = false
            overlay.clear()
            bridge.screenshot.restoreAfterCapturePreparation()
            controls.hideLiveControls()
            throw error
        }
        guard running, generation == token else { return }
        bridge.screenshot.closeForCapture()
        controls.showLiveControls(id: "live-\(token)", screen: screen)
    }

    private func pause() async {
        guard running, !ended, !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        await capture.pause(generation: generation)
        overlay.clear()
        controls.setLivePaused(true)
        try? await command("pause", generation: generation)
    }

    private func resume() async {
        guard running, !ended, !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        let token = generation
        do {
            try await command("resume", generation: token)
            try await capture.resume(source: source, region: region, generation: token)
            controls.setLivePaused(false)
        } catch {
            await unavailable(error.localizedDescription)
        }
    }

    private func end() async {
        guard running, !ended, !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        ended = true
        running = false
        await capture.stop()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.clear()
        StatusBarController.shared.setLiveAbort(false)
        try? await command("end", generation: generation)
    }

    private func discard() async {
        guard (running || ended || windowVisible), !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        let token = generation
        running = false
        ended = false
        await capture.stop()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.clear()
        StatusBarController.shared.setLiveAbort(false)
        try? await command("discard", generation: token)
    }

    private func unavailable(_ message: String) async {
        guard running || ended else { return }
        generation += 1
        running = false
        ended = true
        await capture.stop()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.clear()
        StatusBarController.shared.setLiveAbort(false)
        try? await command("captureFailed", generation: generation, failure: message)
    }

    private var windowVisible: Bool { running || ended }

    /// action/generation 交给主引擎。failure 只用于采集失效。
    private func command(_ action: String, generation: Int, failure: String? = nil) async throws {
        var arguments: [String: Any] = ["action": action, "generation": generation]
        if let failure { arguments["failure"] = failure }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.requestApplication(AppConstants.liveRegionCommandMethod, arguments: arguments) { result in
                if let error = result as? FlutterError {
                    continuation.resume(throwing: GIFExporter.ExportError(message: error.message ?? error.code))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendOcr(generation: Int, blocks: [[String: Any]]?, failure: String?) {
        var arguments: [String: Any] = ["generation": generation]
        if let blocks {
            arguments["blocks"] = blocks
            arguments["text"] = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let failure { arguments["failure"] = failure }
        bridge.requestApplication(AppConstants.liveRegionOcrMethod, arguments: arguments) { _ in }
    }

    /// state 为主引擎快照。只在运行中把已归属译文盖到段落块上。
    func publish(_ state: [String: Any]) {
        // metrics 为主引擎给出的批次计时，每个批次只出现一次。
        for item in state["metrics"] as? [[String: Any]] ?? [] {
            let fields = ["blocks", "chars", "waitMs", "firstMs", "totalMs", "inflight", "outcome"]
                .map { "\($0)=\(item[$0] ?? "")" }
                .joined(separator: " ")
            LiveRegionLog.note("batch \(fields)")
        }
        let runningNow = state["phase"] as? String == "running"
        let chips = runningNow ? (state["overlays"] as? [[String: Any]] ?? []) : []
        overlay.apply(chips)
        controls.setLiveDetail(runningNow ? (state["status"] as? String ?? "") : "")
    }
}
