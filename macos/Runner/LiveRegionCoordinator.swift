import AppKit
import FlutterMacOS

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

/// 点击穿透的译文盖层。每个显示器一个透明窗口，段落块是窗口里的子视图。
/// 窗口属于本应用，识别用的捕获流不会再次捕获它；同步录制通过窗口编号把它加入录制画面。
@MainActor
final class LiveTextOverlay {
    private var panels: [(screen: NSRect, panel: NSPanel)] = []

    /// 无参数。返回当前盖层窗口的系统窗口编号，供录制把这些窗口加入画面。
    var windowIDs: Set<CGWindowID> {
        Set(panels.map { CGWindowID($0.panel.windowNumber) })
    }

    /// 无参数。在每个显示器上铺一个空的透明窗口并显示；会话开始时调用。
    func open() {
        close()
        for screen in NSScreen.screens {
            let panel = makePanel(frame: screen.frame)
            panel.orderFrontRegardless()
            panels.append((screen.frame, panel))
        }
    }

    /// chips 为已归属译文的屏幕矩形。按矩形中心所在的显示器放进对应窗口；空列表撤掉全部译文。
    func apply(_ chips: [[String: Any]]) {
        var grouped: [[(String, NSRect)]] = panels.map { _ in [] }
        for chip in chips {
            guard let text = chip["text"] as? String,
                  let x = chip["x"] as? Double,
                  let y = chip["y"] as? Double,
                  let width = chip["width"] as? Double,
                  let height = chip["height"] as? Double,
                  width > 1, height > 1 else { continue }
            let rect = NSRect(x: x, y: y, width: width, height: height)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            guard let index = panels.firstIndex(where: { $0.screen.contains(center) }) else { continue }
            // 屏幕坐标换成该窗口内的坐标。
            grouped[index].append((text, rect.offsetBy(dx: -panels[index].screen.minX, dy: -panels[index].screen.minY)))
        }
        for (index, items) in grouped.enumerated() {
            guard let canvas = panels[index].panel.contentView else { continue }
            // 复用已有的段落视图，只补建不够的部分。
            while canvas.subviews.count < items.count {
                canvas.addSubview(LiveFitTextView(frame: .zero))
            }
            for (position, view) in canvas.subviews.enumerated() {
                guard position < items.count, let label = view as? LiveFitTextView else {
                    view.isHidden = true
                    continue
                }
                label.frame = items[position].1
                label.text = items[position].0
                label.isHidden = false
            }
        }
    }

    /// 无参数。撤掉全部译文，窗口保持显示。
    func clear() {
        apply([])
    }

    /// 无参数。关闭全部盖层窗口；会话结束时调用。
    func close() {
        for item in panels {
            item.panel.orderOut(nil)
        }
        panels = []
    }

    /// frame 为显示器的屏幕矩形。返回铺满该显示器、不接收鼠标、不成为 key 的透明窗口。
    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
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
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        return panel
    }
}

/// 连接译文盖层、采集悬浮条、未编码捕获和主引擎会话。不保存译文。
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
    /// 本次实时翻译是否同步录制。
    private var recording = false

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
        let screen = NSScreen.screens.first { $0.displayID == displayID }
        // 是否同步录制取自已保存的设置，对区域、窗口和全屏目标都生效。
        let preferences = AppPreferences.current
        recording = preferences[AppConstants.liveRecordingKey] as? Bool == true
        overlay.open()
        bridge.screenshot.hideForCapture()
        controls.showLiveControls(id: "live-\(token)", screen: screen)
        StatusBarController.shared.setLiveAbort(true) { [weak self] in
            Task { await self?.end() }
        }
        do {
            try await command(.start, generation: token)
            try await capture.start(source: source, region: region, generation: token)
            if recording {
                // 录制与识别各用一路捕获；录制把译文盖层窗口加入画面，控制条和遮罩仍被排除。
                controls.service.includedWindowIDs = overlay.windowIDs
                if let region { try controls.service.select(region) }
                try await controls.service.startRecording(source)
            }
        } catch {
            generation += 1
            await capture.stop()
            await cancelRecording()
            if token != generation { try? await command(.discard, generation: generation) }
            running = false
            overlay.close()
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
        await pauseRecording(true)
        controls.setLivePaused(true)
        try? await command(.pause, generation: generation)
    }

    private func resume() async {
        guard running, !ended, !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        let token = generation
        do {
            try await command(.resume, generation: token)
            try await capture.resume(source: source, region: region, generation: token)
            await pauseRecording(false)
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
        // 先结束录制再撤控制条；控制条随后按媒体阶段显示完成进度与录制结果。
        await stopRecording()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.close()
        StatusBarController.shared.setLiveAbort(false)
        try? await command(.end, generation: generation)
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
        await cancelRecording()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.close()
        StatusBarController.shared.setLiveAbort(false)
        try? await command(.discard, generation: token)
    }

    private func unavailable(_ message: String) async {
        guard running || ended else { return }
        generation += 1
        running = false
        ended = true
        await capture.stop()
        // 采集失效时保留已经录到的内容，交给录制结果窗口处理。
        await stopRecording()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.close()
        StatusBarController.shared.setLiveAbort(false)
        try? await command(.captureFailed, generation: generation, failure: message)
    }

    /// paused 为真暂停录制，为假继续录制。未同步录制时不做任何事；失败写入排查日志。
    private func pauseRecording(_ paused: Bool) async {
        guard recording else { return }
        do {
            try await controls.service.setPaused(paused)
        } catch {
            LiveRegionLog.note("record pause=\(paused) error=\(error.localizedDescription)")
        }
    }

    /// 无参数。结束同步录制并保留结果；未同步录制时不做任何事，失败写入排查日志。
    private func stopRecording() async {
        guard recording else { return }
        recording = false
        controls.service.includedWindowIDs = []
        do {
            try await controls.service.stop()
        } catch {
            LiveRegionLog.note("record stop error=\(error.localizedDescription)")
        }
    }

    /// 无参数。丢弃同步录制及其临时文件；未同步录制时不做任何事。
    private func cancelRecording() async {
        guard recording else { return }
        recording = false
        controls.service.includedWindowIDs = []
        await controls.service.cancel()
    }

    private var windowVisible: Bool { running || ended }

    /// action/generation 交给主引擎。failure 只用于采集失效。
    private func command(_ action: LiveRegionAction, generation: Int, failure: String? = nil) async throws {
        var arguments: [String: Any] = ["action": action.rawValue, "generation": generation]
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
        // 主引擎快照总带阶段；缺少或不认识即两端协议不一致，直接终止（#127）。
        guard let raw = state["phase"] as? String, let phase = LiveRegionPhase(rawValue: raw) else {
            preconditionFailure("实时翻译快照缺少可识别的阶段")
        }
        let runningNow = phase == .running
        let chips = runningNow ? (state["overlays"] as? [[String: Any]] ?? []) : []
        overlay.apply(chips)
        controls.setLiveDetail(runningNow ? (state["status"] as? String ?? "") : "")
    }
}
