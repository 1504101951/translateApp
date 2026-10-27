import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// 设备 OCR 的单槽。忙时只保留最新一帧；旧操作结束不能清掉新代次的待处理帧。
struct LiveOcrSlot {
    private(set) var busy = false
    private var pending = false
    private(set) var acceptedGeneration = 0
    private var pendingGeneration = 0

    /// generation 为当前捕获代次。丢弃旧待处理帧，不把正在执行的识别标成已结束。
    mutating func adopt(_ generation: Int) {
        acceptedGeneration = generation
        pending = false
    }

    /// generation 为这帧所属代次。可以立刻开始时返回 true；忙时只替换待处理帧。
    mutating func offer(generation: Int) -> Bool {
        guard generation == acceptedGeneration else { return false }
        if busy {
            pending = true
            pendingGeneration = generation
            return false
        }
        busy = true
        return true
    }

    /// 无参数。执行槽释放后，仅当前代次的待处理帧可以开始；返回是否应开始下一次。
    mutating func finish() -> Bool {
        busy = false
        guard pending, pendingGeneration == acceptedGeneration else {
            pending = false
            return false
        }
        pending = false
        busy = true
        return true
    }
}

/// 实时翻译的屏幕流。帧直接交给设备 OCR，不创建录屏文件或视频编码器。
@MainActor
final class LiveRegionCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    /// generation 为识别开始时的代次。blocks 为屏幕坐标段落块，failure 为识别错误。
    var onRecognized: ((Int, [[String: Any]]?, String?) -> Void)?
    /// message 为捕获失效原因。调用方不得改去捕获其他屏幕。
    var onUnavailable: ((String) -> Void)?
    /// frame 为当前捕获范围的 AppKit 矩形，供区域标记使用。
    var onFrame: ((NSRect) -> Void)?

    private let queue = DispatchQueue(label: "translateapp.live-frames")
    /// SCStreamConfiguration.backgroundColor 为 assign/unowned，必须由本类持有，避免临时 CGColor 立刻释放。
    private let background = CGColor(gray: 0, alpha: 1)
    private var slot = LiveOcrSlot()
    private var streams: [SCStream] = []
    private var frames: [ObjectIdentifier: CMSampleBuffer] = [:]
    private var frameBounds: [ObjectIdentifier: NSRect] = [:]
    private var running = false
    private var targetDisplayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?

    /// source 含 kind、sourceID 和应用身份，region 为区域目标的已校验选区，generation 为本次代次。
    /// 启动排除本应用窗口的 SCStream。失败时不保留半开的流。
    func start(
        source: [String: Any],
        region: MediaCaptureService.Region?,
        generation: Int
    ) async throws {
        // DisplayCapture 集中显示器采集的权限、来源、选区与尺寸校验（#125）。
        try DisplayCapture.requireAuthorization()
        await stopStreams()
        slot.adopt(generation)
        frames.removeAll()
        frameBounds.removeAll()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let kind = source["kind"] as? String else {
            throw GIFExporter.ExportError(message: "缺少采集方式。")
        }
        let built = try build(kind: kind, source: source, region: region, content: content)
        targetDisplayID = built.displayID
        onFrame?(built.shade)
        for item in built.streams {
            try item.stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            streams.append(item.stream)
            frameBounds[ObjectIdentifier(item.stream)] = item.bounds
        }
        running = true
        observeSystem()
        for item in built.streams {
            guard running else { throw CancellationError() }
            try await item.stream.startCapture()
        }
    }

    /// generation 为暂停后的代次。停止供帧并作废旧识别，不释放尚未结束的执行槽。
    func pause(generation: Int) async {
        slot.adopt(generation)
        running = false
        frames.removeAll()
        frameBounds.removeAll()
        await stopStreams()
    }

    /// source/region 与开始时相同，generation 为恢复后的代次。重新校验目标后继续供帧。
    func resume(source: [String: Any], region: MediaCaptureService.Region?, generation: Int) async throws {
        try await start(source: source, region: region, generation: generation)
    }

    /// 无参数。停止流和系统观察，不再提交识别结果。
    func stop() async {
        running = false
        slot.adopt(slot.acceptedGeneration + 1)
        frames.removeAll()
        frameBounds.removeAll()
        await stopStreams()
        removeObservers()
    }

    /// sampleBuffer 为系统画面，type 为输出种类。只收下完整画面并立即返回，识别放到后台槽位。
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle || (status == .started && CMSampleBufferGetImageBuffer(sampleBuffer) == nil) { return }
        guard status == .complete || status == .started,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let retained = sampleBuffer
        let identity = ObjectIdentifier(stream)
        Task { @MainActor in
            self.receive(identity, sample: retained)
        }
    }

    /// stopped 为中断的流，error 为系统原因。不改捕其他显示器。
    nonisolated func stream(_ stopped: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.running, self.streams.contains(where: { $0 === stopped }) else { return }
            self.fail(error.localizedDescription)
        }
    }

    private func receive(_ identity: ObjectIdentifier, sample: CMSampleBuffer) {
        guard running else { return }
        frames[identity] = sample
        guard slot.offer(generation: slot.acceptedGeneration) else { return }
        recognize(slot.acceptedGeneration)
    }

    /// generation 为这次识别开始时的代次。完成后先提交该次结果，再处理最新待处理帧。
    private func recognize(_ generation: Int) {
        let batch = frames.map { ($0.key, $0.value) }
        let bounds = frameBounds
        // 识别在主线程之外执行；单槽保证同一时刻只有这一个任务。
        Task.detached {
            let started = ContinuousClock.now
            var pixels = 0.0
            let outcome: Result<[[String: Any]], Error>
            do {
                var blocks: [[String: Any]] = []
                for (identity, sample) in batch {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample),
                          let imageBounds = bounds[identity] else { continue }
                    // recognizeParagraphs 返回该帧的段落块，折行文字已合成一段。
                    let found = try await ScreenCaptureService.recognizeParagraphs(pixelBuffer: buffer)
                    let pixelWidth = Double(CVPixelBufferGetWidth(buffer))
                    let pixelHeight = Double(CVPixelBufferGetHeight(buffer))
                    guard pixelWidth > 0, pixelHeight > 0 else { continue }
                    pixels += pixelWidth * pixelHeight
                    for item in found {
                        guard let text = item["text"] as? String,
                              let x = item["x"] as? Double,
                              let y = item["y"] as? Double,
                              let width = item["width"] as? Double,
                              let height = item["height"] as? Double else { continue }
                        // 图像左上原点换成该帧在屏幕上的左下原点，盖层才能盖住整段原文。
                        let rect = NSRect(
                            x: imageBounds.minX + x / pixelWidth * imageBounds.width,
                            y: imageBounds.maxY - (y + height) / pixelHeight * imageBounds.height,
                            width: width / pixelWidth * imageBounds.width,
                            height: height / pixelHeight * imageBounds.height
                        )
                        blocks.append([
                            "text": text,
                            "x": rect.minX,
                            "y": rect.minY,
                            "width": rect.width,
                            "height": rect.height,
                        ])
                    }
                }
                blocks.sort { lhs, rhs in
                    let ly = lhs["y"] as? Double ?? 0
                    let ry = rhs["y"] as? Double ?? 0
                    let lh = lhs["height"] as? Double ?? 0
                    let rh = rhs["height"] as? Double ?? 0
                    if abs((ly + lh) - (ry + rh)) > 1 { return ly + lh > ry + rh }
                    return (lhs["x"] as? Double ?? 0) < (rhs["x"] as? Double ?? 0)
                }
                // 记录识别耗时、画面像素数与段落数，用于判断延迟是否来自识别。
                let elapsed = started.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                LiveRegionLog.note("ocr ms=\(Int(milliseconds)) pixels=\(Int(pixels)) paragraphs=\(blocks.count)")
                outcome = .success(blocks)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                let follow = self.slot.finish()
                if generation == self.slot.acceptedGeneration, self.running {
                    switch outcome {
                    case let .success(blocks):
                        self.onRecognized?(generation, blocks, nil)
                    case let .failure(error):
                        self.onRecognized?(generation, nil, error.localizedDescription)
                    }
                }
                if follow, self.running {
                    self.recognize(self.slot.acceptedGeneration)
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard running else { return }
        running = false
        onUnavailable?(message)
    }

    private func observeSystem() {
        removeObservers()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteScreens() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fail("屏幕已锁定或进入睡眠。") }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fail("屏幕已锁定或进入睡眠。") }
        }
    }

    private func noteScreens() {
        guard running, let targetDisplayID else { return }
        let ids = NSScreen.screens.compactMap(\.displayID)
        if !ids.contains(targetDisplayID) {
            fail("目标显示器已移除。")
        }
    }

    private func removeObservers() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        screenObserver = nil
        sleepObserver = nil
        lockObserver = nil
    }

    private func stopStreams() async {
        let active = streams
        streams = []
        for stream in active {
            try? await stream.stopCapture()
        }
    }

    /// kind/source/region/content 描述本次目标。返回已配置但尚未启动的流、遮罩矩形和必须仍存在的显示器。
    private func build(
        kind: String,
        source: [String: Any],
        region: MediaCaptureService.Region?,
        content: SCShareableContent
    ) throws -> (streams: [(stream: SCStream, displayID: CGDirectDisplayID, bounds: NSRect)], shade: NSRect, displayID: CGDirectDisplayID) {
        if kind == CaptureTarget.application.rawValue {
            guard let applicationID = source["applicationID"] as? String else {
                throw GIFExporter.ExportError(message: "请选择要翻译的应用。")
            }
            let apps = content.applications.filter { $0.bundleIdentifier == applicationID }
            guard applicationID != Bundle.main.bundleIdentifier, !apps.isEmpty,
                  content.windows.contains(where: {
                      $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 &&
                      $0.owningApplication?.bundleIdentifier == applicationID
                  }) else {
                throw GIFExporter.ExportError(message: "所选应用已退出或没有可识别的可见窗口。")
            }
            let filters = content.displays.map { display in
                (display, SCContentFilter(display: display, including: apps, exceptingWindows: []))
            }
            let canvas = try ApplicationCaptureCanvas(displays: filters.map {
                .init(id: $0.0.displayID, frame: $0.0.frame, scale: CGFloat($0.1.pointPixelScale))
            })
            let interval = CMTime(value: CMTimeValue(AppConstants.liveCaptureMinIntervalMs), timescale: 1000)
            var streams: [(SCStream, CGDirectDisplayID, NSRect)] = []
            for (display, filter) in filters {
                filter.includeMenuBar = false
                let config = baseConfig(width: Int((display.frame.width * CGFloat(filter.pointPixelScale)).rounded()),
                                         height: Int((display.frame.height * CGFloat(filter.pointPixelScale)).rounded()),
                                         interval: interval)
                config.backgroundColor = background
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                streams.append((
                    stream,
                    display.displayID,
                    CaptureGeometry.appKitRect(fromCGWindowBounds: display.frame)
                ))
            }
            let sourceID = (source["sourceID"] as? NSNumber)?.uint32Value ?? filters[0].0.displayID
            return (streams, CaptureGeometry.appKitRect(fromCGWindowBounds: canvas.bounds), sourceID)
        }
        let displayID = kind == CaptureTarget.region.rawValue
            ? region?.displayID
            : (source["sourceID"] as? NSNumber)?.uint32Value
        let display = try DisplayCapture.display(displayID, in: content)
        let own = try DisplayCapture.ownApplications(in: content)
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        var crop: CGRect?
        if kind == CaptureTarget.region.rawValue, let region {
            crop = try DisplayCapture.crop(region, in: filter)
        }
        let scale = CGFloat(filter.pointPixelScale)
        let size = crop?.size ?? filter.contentRect.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        try DisplayCapture.requireMinimumSize(width: width, height: height)
        let config = baseConfig(
            width: width,
            height: height,
            interval: CMTime(value: CMTimeValue(AppConstants.liveCaptureMinIntervalMs), timescale: 1000)
        )
        if let crop { config.sourceRect = crop }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        var target = display.frame
        let actual = crop ?? CGRect(origin: .zero, size: filter.contentRect.size)
        target.origin.x += actual.minX
        target.origin.y += actual.minY
        target.size = actual.size
        let bounds = CaptureGeometry.appKitRect(fromCGWindowBounds: target)
        return ([(stream, display.displayID, bounds)], bounds, display.displayID)
    }

    /// width/height 为输出像素，interval 为已批准的供帧间隔。返回不编码、不采集鼠标和音频的配置。
    private func baseConfig(width: Int, height: Int, interval: CMTime) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = interval
        config.showsCursor = false
        config.capturesAudio = false
        config.captureMicrophone = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 3
        return config
    }
}
