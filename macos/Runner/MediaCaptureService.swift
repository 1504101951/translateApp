import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import FlutterMacOS
import ScreenCaptureKit

/// 屏幕采集和本地媒体资源；Dart决定用户操作，原生回调只报告实际资源状态。
@MainActor
final class MediaCaptureService: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    /// 已由截图编辑器确认的显示器内像素选区。
    struct Region {
        let displayID: CGDirectDisplayID
        let rect: CGRect
        let scale: CGFloat
        let edges: ScrollStitcher.Edges
    }

    private var applicationRecorder: ApplicationRecorder?
    private var applicationCanvas: ApplicationCaptureCanvas?
    private var applicationSegmentID: UUID?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var temporaryDirectory: URL?
    private var video: URL?
    private var scrollTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var finishScroll = false
    /// 长截图自动滚动（#112）：available 为本次会话仍可自动滚动（设置为自动且未改为手动），active 为当前由 App 滚动；
    /// 用户在选区内滚动时关闭 active，来源不支持或无辅助功能权限时同时关闭两者。
    private var autoScrollAvailable = false
    private var autoScrollActive = false
    /// 自动滚动期间的只读全局滚轮监听，用于判定用户接管。
    private var scrollWheelMonitor: Any?
    /// 长截图过程提示序号；采集循环与接管监听共用，同一提示只显示一次。
    private var scrollHintSerial = 0
    private var discardRecording = false
    private var recordingFailure: String?
    private var recordingSegments: [URL] = []
    private var recordingArguments: [String: Any] = [:]
    private var recordedElapsed: TimeInterval = 0
    private var recordingCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var timer: Timer?
    private var startedAt: Date?
    /// 当前分段请求到真正开始写入的单调时钟起点，只用于本地启动诊断。
    private var recordingRequestedAt: ContinuousClock.Instant?
    private(set) var phase = CapturePhase.idle
    private(set) var id = UUID().uuidString
    /// 结果页确认的裁剪区间；nil为完整视频。只在视频结果中设置，关闭结果后随会话丢弃（#110）。
    private(set) var trim: CMTimeRange?
    private(set) var region: Region?
    /// 实际录制配置在AppKit屏幕点坐标中的范围，仅供可见选区遮罩使用。
    private(set) var captureFrame: NSRect?
    private var details: [String: Any] = [:]
    var onChange: (([String: Any]) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?
    /// 长截图实时缩略图与所在屏倍率；确认帧或回退目标变化时在主线程通知。
    var onScrollPreview: ((ScrollStitcher.Preview, CGFloat) -> Void)?
    /// 本应用中需要进入录制画面的窗口编号；为空时本应用窗口全部排除。
    var includedWindowIDs: Set<CGWindowID> = []

    /// 无参数；返回仍占有采集/编码资源的状态，供菜单和窗口关闭判断。
    var isBusy: Bool { [.preparing, .recording, .pausing, .paused, .finalizing, .scrolling, .converting].contains(phase) }

    /// 无参数；返回会话身份、实际阶段、预览或错误元数据，不携带外部凭据。
    func snapshot() -> [String: Any] {
        var value = details
        value["id"] = id
        value["phase"] = phase.rawValue
        return value
    }

    /// next为真实生命周期阶段，values合并元数据；通知当前窗口与菜单，无返回值。
    private func update(_ next: CapturePhase, _ values: [String: Any] = [:]) {
        // 真实开始回调才结束总耗时；计时通知、迟到回调和取消不会重复写入。
        if next == .recording, let requested = recordingRequestedAt {
            CaptureStartupLog.record("recording-ready", since: requested)
            recordingRequestedAt = nil
        }
        if [.idle, .failed].contains(next) { recordingRequestedAt = nil }
        phase = next
        details.merge(values) { _, new in new }
        onChange?(snapshot())
    }

    /// selection为确认后的单显示器选区；只在空闲期更新，不覆盖正在录制的坐标。
    func select(_ selection: Region) throws {
        guard !isBusy else { throw GIFExporter.ExportError(message: "请先结束当前采集。") }
        region = selection
        update(phase)
    }

    /// preferredApplicationID为截图前台应用；返回按应用去重的身份、名称和PNG图标，不采集屏幕像素。
    func sources(preferredApplicationID: String?) async throws -> [[String: Any]] {
        guard await ScreenCaptureService.requestAccess() else {
            throw GIFExporter.ExportError(message: AppConstants.screenRecordingRequiredMessage)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let visible = Set(content.windows.filter {
            $0.frame.width > 0 && $0.frame.height > 0 && $0.isOnScreen
        }.compactMap { $0.owningApplication?.bundleIdentifier })
        var applications: [String: [String: Any]] = [:]
        for app in content.applications where visible.contains(app.bundleIdentifier) && app.bundleIdentifier != Bundle.main.bundleIdentifier {
            guard applications[app.bundleIdentifier] == nil else { continue }
            // 来源身份不依赖图标；直接栅格化16pt@2x，避免在主线程编码整套TIFF表示。
            let running = NSRunningApplication(processIdentifier: app.processID)
            let icon = running?.icon ?? running?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            var source: [String: Any] = ["kind": CaptureTarget.application.rawValue, "applicationID": app.bundleIdentifier,
                "name": app.applicationName,
                "windows": content.windows.filter { $0.isOnScreen && $0.owningApplication?.bundleIdentifier == app.bundleIdentifier }
                    .map { ["x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height] }]
            // applicationIconPNG只负责图标像素；缺失资产由界面明确显示通用应用图标，不能删掉可录来源。
            if let png = Self.applicationIconPNG(icon) { source["icon"] = FlutterStandardTypedData(bytes: png) }
            applications[app.bundleIdentifier] = source
        }
        // 当前应用依据截图前保存的身份置顶，其余按名称及稳定应用身份排序。
        return applications.values.sorted { lhs, rhs in
            let left = lhs["applicationID"] as! String, right = rhs["applicationID"] as! String
            if left == preferredApplicationID { return true }
            if right == preferredApplicationID { return false }
            let order = (lhs["name"] as! String).localizedStandardCompare(rhs["name"] as! String)
            return order == .orderedSame ? left < right : order == .orderedAscending
        }
    }

    /// image为系统应用图标（可能缺失或为矢量表示）；返回32×32 PNG，缺失时返回nil供界面标识。
    static func applicationIconPNG(_ image: NSImage?) -> Data? {
        guard let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// args指定显示器或已确认区域，video决定偶数像素对齐；返回排除自身窗口的过滤器和原生采集配置。
    private func configuration(_ args: [String: Any], video: Bool) async throws -> (SCContentFilter, SCStreamConfiguration) {
        // DisplayCapture 集中显示器采集的权限、来源、选区与尺寸校验（#125）。
        try DisplayCapture.requireAuthorization()
        let token = id
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard token == id else { throw CancellationError() }
        guard let kind = args["kind"] as? String else { throw GIFExporter.ExportError(message: "缺少采集方式。") }
        let filter: SCContentFilter
        var crop: CGRect?
        var targetFrame: CGRect
        do {
            let displayID = kind == CaptureTarget.region.rawValue ? region?.displayID : (args["sourceID"] as? NSNumber)?.uint32Value
            guard [CaptureTarget.display.rawValue, CaptureTarget.region.rawValue].contains(kind) else {
                throw GIFExporter.ExportError(message: "捕获目标已不可用，请重新选择。")
            }
            let display = try DisplayCapture.display(displayID, in: content)
            // 应用的控制、翻译、编辑窗口全部从显示器捕获中排除。
            let own = try DisplayCapture.ownApplications(in: content)
            // 指定的本应用窗口作为例外留在画面里；找不全时明确失败，不录制缺少这些窗口的画面。
            let included = content.windows.filter { includedWindowIDs.contains($0.windowID) }
            guard included.count == includedWindowIDs.count else {
                throw GIFExporter.ExportError(message: "无法把译文盖层加入录制，请重新开始。")
            }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: included)
            targetFrame = display.frame
            if kind == CaptureTarget.region.rawValue, let region {
                crop = try DisplayCapture.crop(region, in: filter)
            }
        }
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = crop?.size ?? filter.contentRect.size
        var width = Int((size.width * scale).rounded(video ? .down : .toNearestOrAwayFromZero))
        var height = Int((size.height * scale).rounded(video ? .down : .toNearestOrAwayFromZero))
        if video { width -= width % 2; height -= height % 2 }
        try DisplayCapture.requireMinimumSize(width: width, height: height)
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: AppConstants.recordingFramesPerSecond)
        config.showsCursor = video
        // 「录制时显示鼠标点击」由设置页写入偏好字典，默认关闭；静帧截图不绘制点击（#110）。
        config.showMouseClicks = video && AppPreferences.current[
            AppConstants.recordingShowsClicksKey
        ] as? Bool == true
        config.capturesAudio = false
        config.captureMicrophone = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        if video {
            // H264偶数尺寸向内裁掉边缘，不通过改变输出宽高拉伸整个奇数选区。
            config.sourceRect = CGRect(origin: crop?.origin ?? .zero,
                size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        } else if let crop { config.sourceRect = crop }
        // 两种采集共享实际屏幕范围；视频使用偶数像素内裁，静帧使用原始选区。
        let actualCrop = video ? config.sourceRect : crop ?? CGRect(origin: .zero, size: filter.contentRect.size)
        targetFrame.origin.x += actualCrop.minX
        targetFrame.origin.y += actualCrop.minY
        targetFrame.size = actualCrop.size
        captureFrame = CaptureGeometry.appKitRect(fromCGWindowBounds: targetFrame)
        return (filter, config)
    }

    /// 无参数；准备新的私有输出目录。调用方须先明确丢弃上一份未保存结果。
    private func begin() throws {
        // 失败会话的临时资源由创建者清理，再建立新的会话身份。
        if phase == .failed { clear() }
        guard !isBusy, video == nil, details["imageBytes"] == nil else {
            throw GIFExporter.ExportError(message: "请先保存或丢弃当前结果。")
        }
        id = UUID().uuidString
        details = [:]
        captureFrame = nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateApp-Capture-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectory = directory
        update(.preparing)
        onActiveChanged?(true)
    }

    /// args为当前目标；创建独立会话并开始第一段无音轨MP4，暂停恢复保留同一会话。
    func startRecording(_ args: [String: Any]) async throws {
        let started = ContinuousClock.now
        defer { CaptureStartupLog.record("start-recording-await", since: started) }
        try begin()
        recordingArguments = args
        details["kind"] = "recording"
        try await startRecordingSegment()
    }

    /// 无参数；为已确认目标追加一段MP4，系统开始回调后才允许暂停或结束。
    private func startRecordingSegment() async throws {
        let token = id
        // 系统开始回调可能早于startCapture返回；错误清理须绑定本次创建的流。
        var startingStream: SCStream?
        recordingRequestedAt = .now
        let previousFrame = captureFrame
        details.removeValue(forKey: "error")
        update(.preparing)
        do {
            if recordingArguments["kind"] as? String == CaptureTarget.application.rawValue {
                // 应用录制统一逐屏捕获和合成，暂停分段仍复用同一会话与输出画布。
                try await startApplicationSegment()
                return
            }
            // 每段重验目标与授权，目标关闭或缩放变化时明确失败。
            let configurationStarted = ContinuousClock.now
            let (filter, config) = try await configuration(recordingArguments, video: true)
            CaptureStartupLog.record("screen-configuration-await", since: configurationStarted)
            guard token == id else { throw CancellationError() }
            // 无损合并要求所有段尺寸一致；目标尺寸改变时保留已有段供结束保存。
            if !recordingSegments.isEmpty,
               (details["width"] as? Int != config.width || details["height"] as? Int != config.height) {
                throw GIFExporter.ExportError(message: "目标尺寸已改变，请结束并保存当前录制后重新开始。")
            }
            let outputURL = temporaryDirectory!.appendingPathComponent("segment-\(UUID().uuidString).mp4")
            let resourceStarted = ContinuousClock.now
            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = outputURL
            outputConfig.videoCodecType = .h264
            outputConfig.outputFileType = .mp4
            let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addRecordingOutput(output)
            startingStream = stream
            CaptureStartupLog.record("screen-resources-sync", since: resourceStarted)
            self.stream = stream
            recordingOutput = output
            video = outputURL
            discardRecording = false
            recordingFailure = nil
            details["width"] = config.width
            details["height"] = config.height
            let captureStarted = ContinuousClock.now
            try await stream.startCapture()
            CaptureStartupLog.record("screen-start-await", since: captureStarted)
        } catch {
            guard token == id else { throw error }
            // 同一会话暂停恢复也会更换流；旧启动等待不得清理后续分段。
            if let startingStream, stream !== startingStream { throw error }
            if recordingSegments.isEmpty {
                await fail(error)
                throw error
            }
            // 恢复失败保留已完成分段；结束本次录制器后，再确认清理权仍属于当前请求。
            if let recorder = applicationRecorder {
                try? await recorder.finish(discard: true)
                guard token == id, applicationRecorder === recorder else { throw error }
                applicationRecorder = nil
            }
            let active = stream
            stream = nil
            recordingOutput = nil
            try? await active?.stopCapture()
            guard token == id else { throw error }
            video = recordingSegments.last
            captureFrame = previousFrame
            update(.paused, ["error": error.localizedDescription])
            throw error
        }
    }

    /// 无参数；创建应用的逐屏流和联合画布编码器，全部首帧到齐后才进入录制状态。
    private func startApplicationSegment() async throws {
        let started = ContinuousClock.now
        defer { CaptureStartupLog.record("application-segment-await", since: started) }
        let token = id
        try DisplayCapture.requireAuthorization()
        guard let applicationID = recordingArguments["applicationID"] as? String else {
            throw GIFExporter.ExportError(message: "捕获目标已不可用，请重新选择。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard token == id else { throw CancellationError() }
        let url = temporaryDirectory!.appendingPathComponent("application-\(UUID().uuidString).mp4")
        let segmentID = UUID()
        applicationSegmentID = segmentID
        let recorder = try await ApplicationRecorder(content: content, applicationID: applicationID,
            expected: applicationCanvas, url: url, includedWindowIDs: includedWindowIDs) { [weak self] error in
            guard let self, self.id == token, self.applicationSegmentID == segmentID, self.phase == .recording else { return }
            // 系统中断保留本段已编码画面及以前完成的分段，错误随结果交付。
            Task { @MainActor in
                // 异步任务实际执行时再次核对段身份，暂停恢复不能接收旧段错误。
                guard self.id == token, self.applicationSegmentID == segmentID else { return }
                await self.finishApplicationSegment(paused: false, warning: error.localizedDescription)
            }
        }
        // 后台编码初始化可跨越取消；过期段必须结束，不能重新挂接到新会话。
        guard token == id, applicationSegmentID == segmentID else {
            try? await recorder.finish(discard: true)
            throw CancellationError()
        }
        applicationRecorder = recorder
        applicationCanvas = recorder.canvas
        captureFrame = CaptureGeometry.appKitRect(fromCGWindowBounds: recorder.canvas.bounds)
        video = url
        details["width"] = Int(recorder.canvas.size.width)
        details["height"] = Int(recorder.canvas.size.height)
        try await recorder.start()
        guard token == id, applicationRecorder === recorder else { throw CancellationError() }
        startedAt = Date()
        update(.recording, ["elapsed": recordedElapsed])
        var validating = false
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.id == token, self.phase == .recording,
                      self.applicationRecorder === recorder, !validating else { return }
                validating = true
                defer { validating = false }
                do {
                    // validate检查实际应用窗口和显示器拓扑，不能把任意黑帧当成正常录制。
                    try await recorder.validate()
                    guard self.id == token, self.applicationRecorder === recorder, self.phase == .recording, let start = self.startedAt else { return }
                    self.update(.recording, ["elapsed": self.recordedElapsed + Date().timeIntervalSince(start)])
                } catch {
                    guard self.id == token, self.applicationRecorder === recorder, self.phase == .recording else { return }
                    await self.finishApplicationSegment(paused: false, warning: error.localizedDescription)
                }
            }
        }
    }

    /// paused为保留后继续的意图，warning为系统中断原因；等待编码完成再公开暂停或视频结果。
    private func finishApplicationSegment(paused: Bool, warning: String? = nil) async {
        guard let recorder = applicationRecorder, phase == .recording else { return }
        let token = id
        timer?.invalidate()
        timer = nil
        if let startedAt { recordedElapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        update(paused ? .pausing : .finalizing, ["elapsed": recordedElapsed])
        if let warning { details["error"] = warning }
        do {
            // finish等待所有屏幕流及MP4尾部；完成前不得复用编码器或删除临时文件。
            try await recorder.finish(discard: false)
            guard id == token, applicationRecorder === recorder, let video else { return }
            applicationRecorder = nil
            recordingSegments.append(video)
            if paused { update(.paused) }
            else { finishRecording() }
        } catch {
            // 放弃会先撤销录制器身份；迟到的结束错误不得重新发布会话状态或合并分段。
            guard id == token, applicationRecorder === recorder else { return }
            applicationRecorder = nil
            if recordingSegments.isEmpty { await fail(error); return }
            details["error"] = error.localizedDescription
            finishRecording()
        }
    }

    /// paused为期望暂停状态；暂停保留会话与选区，恢复继续追加内容，不创建第二个会话。
    func setPaused(_ paused: Bool) async throws {
        if paused, phase == .scrolling {
            // 工作线程完成已接受帧后确认paused，拼接运算不占用界面主执行器。
            update(.pausing)
            return
        }
        if !paused, phase == .paused {
            if details["kind"] as? String == "scrolling" {
                // 「继续」恢复自动滚动；本次已改为手动时保持手动（#112）。
                autoScrollActive = autoScrollAvailable
                update(.scrolling)
                return
            }
            try await startRecordingSegment()
            return
        }
        if paused, phase == .recording, applicationRecorder != nil {
            await finishApplicationSegment(paused: true)
            return
        }
        guard paused, phase == .recording, let stream else {
            throw GIFExporter.ExportError(message: "当前采集状态不能切换暂停。")
        }
        let token = id
        // 系统编码完成前保持pausing，防止恢复动作复用未完成的输出。
        if let startedAt { recordedElapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        timer?.invalidate()
        timer = nil
        update(.pausing, ["elapsed": recordedElapsed])
        do { try await stream.stopCapture() }
        catch {
            // 暂停等待可能跨越放弃或下一分段；只清理仍由该流持有的会话。
            if token == id, self.stream === stream { await fail(error) }
            throw error
        }
    }

    /// 无参数；显式结束活动或已暂停的采集，过渡态不执行清理，完成回调之前保持finalizing。
    func stop() async throws {
        if phase == .scrolling || (phase == .paused && details["kind"] as? String == "scrolling") {
            finishScroll = true
            update(.finalizing)
            return
        }
        if phase == .paused {
            finishRecording()
            return
        }
        if phase == .recording, applicationRecorder != nil {
            await finishApplicationSegment(paused: false)
            return
        }
        guard phase == .recording, let stream else { return }
        let token = id
        update(.finalizing)
        timer?.invalidate()
        timer = nil
        do { try await stream.stopCapture() }
        catch {
            // 完成回调已接管或会话已替换时，迟到的停止错误不再拥有清理权。
            if token == id, self.stream === stream { await fail(error) }
            throw error
        }
    }

    /// 无参数；取消当前资源或丢弃预览，只清理本会话创建的私有目录。
    func cancel() async {
        let token = id
        if let recorder = applicationRecorder {
            // 先撤销可提交身份，正在等待编码的结束任务不能再次发布结果。
            applicationRecorder = nil
            update(.finalizing)
            try? await recorder.finish(discard: true)
            // 其他清理路径可能已完成并开放新采集；过期取消不能继续操作共享字段。
            guard id == token else { return }
        }
        exportTask?.cancel()
        if let exportTask {
            await exportTask.value
            guard id == token else { return }
        }
        self.exportTask = nil
        scrollTask?.cancel()
        if let scrollTask {
            await scrollTask.value
            guard id == token else { return }
        }
        self.scrollTask = nil
        if let stream {
            let alreadyStopping = [.pausing, .finalizing].contains(phase)
            discardRecording = true
            update(.finalizing)
            if !alreadyStopping {
                do { try await stream.stopCapture() }
                catch { if token == id { await fail(error) } }
            }
            // stopCapture返回不代表MP4尾部已编码；输出完成/失败清理时唤醒等待者。
            if token == id, recordingOutput != nil {
                await withCheckedContinuation { recordingCompletionWaiters.append($0) }
            }
            if id == token { clear() }
            return
        }
        clear()
    }

    /// 无参数；释放计时器与本会话文件，保留用户的选区和已保存文件。
    func clear() {
        stopWatchingScrollTakeover()
        autoScrollAvailable = false
        autoScrollActive = false
        let waiters = recordingCompletionWaiters
        recordingCompletionWaiters = []
        timer?.invalidate()
        timer = nil
        stream = nil
        recordingOutput = nil
        video = nil
        recordingSegments = []
        recordingArguments = [:]
        applicationRecorder = nil
        applicationCanvas = nil
        applicationSegmentID = nil
        recordedElapsed = 0
        startedAt = nil
        captureFrame = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        details = [:]
        trim = nil
        id = UUID().uuidString
        onActiveChanged?(false)
        update(.idle)
        for waiter in waiters { waiter.resume() }
    }

    /// error为系统实际错误；停止占用资源并保留原因，不交付损坏MP4。
    private func fail(_ error: Error) async {
        let token = id
        if let recorder = applicationRecorder {
            applicationRecorder = nil
            try? await recorder.finish(discard: true)
            // 结束编码期间可能已放弃并开始新会话；旧失败不得继续读取新资源。
            guard id == token else { return }
        }
        let active = stream
        stream = nil
        recordingOutput = nil
        try? await active?.stopCapture()
        // 停止捕获会让出主执行器，恢复后只清理发起失败的会话。
        guard id == token else { return }
        clear()
        update(.failed, ["error": error.localizedDescription])
    }

    /// output为开始写入的录制对象；拒绝旧回调，启动可见时长通知。
    nonisolated func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        let identity = ObjectIdentifier(output)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingOutput.map(ObjectIdentifier.init) == identity, self.phase == .preparing else { return }
            self.startedAt = Date()
            self.update(.recording, ["elapsed": self.recordedElapsed])
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startedAt, self.phase == .recording else { return }
                    self.update(.recording, ["elapsed": self.recordedElapsed + Date().timeIntervalSince(start)])
                }
            }
        }
    }

    /// output为失败对象；error保持系统原因，异步释放对应流。
    nonisolated func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.recordingOutput === output else { return }
            await self.fail(error)
        }
    }

    /// output为完成对象；通过实际首帧解码后公开预览，取消时只清理。
    nonisolated func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.recordingOutput === output, let video = self.video else { return }
            self.stream = nil
            self.recordingOutput = nil
            self.timer?.invalidate()
            self.timer = nil
            if self.discardRecording { self.clear(); return }
            if let failure = self.recordingFailure {
                await self.fail(GIFExporter.ExportError(message: failure)); return
            }
            self.recordingSegments.append(video)
            if self.phase == .pausing {
                self.update(.paused)
                return
            }
            self.finishRecording()
        }
    }

    /// 无参数；结束时按段顺序合并并验证解码，异步任务归本会话所有，可被放弃取消。
    private func finishRecording() {
        let token = id
        let segments = recordingSegments
        let destination = temporaryDirectory!.appendingPathComponent("recording.mp4")
        update(.finalizing)
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.joinRecordingSegments(segments, destination: destination)
                try Task.checkCancellation()
                let info = try await GIFExporter.metadata(result)
                guard self.id == token else { return }
                self.video = result
                self.onActiveChanged?(false)
                self.update(.videoReady, ["duration": info.duration, "width": info.width, "height": info.height])
            } catch is CancellationError { return }
            catch { if self.id == token { await self.fail(error) } }
        }
    }

    /// sources为同一目标按时间排序的无音轨MP4段，destination为会话私有输出；返回可供校验的连续视频路径。
    static func joinRecordingSegments(_ sources: [URL], destination: URL) async throws -> URL {
        guard let first = sources.first else { throw GIFExporter.ExportError(message: "没有可保留的录制内容。") }
        if sources.count == 1 { return first }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw GIFExporter.ExportError(message: "无法建立录制视频轨道。")
        }
        var cursor = CMTime.zero
        for url in sources {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw GIFExporter.ExportError(message: "录制分段缺少视频轨道。")
            }
            let range = try await source.load(.timeRange)
            guard range.duration.isNumeric, range.duration > .zero else {
                throw GIFExporter.ExportError(message: "录制分段没有有效画面。")
            }
            if cursor == .zero { track.preferredTransform = try await source.load(.preferredTransform) }
            // 每段直接接到前一段结尾，不使用墙钟时间，暂停区间没有占位帧。
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw GIFExporter.ExportError(message: "无法完成录制分段合并。")
        }
        try await exporter.export(to: destination, as: .mp4)
        try Task.checkCancellation()
        return destination
    }

    /// stopped为中断的流；系统中断不能经正常结束回调被标为成功。
    nonisolated func stream(_ stopped: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stopped else { return }
            self.recordingFailure = error.localizedDescription
            await self.fail(error)
        }
    }

    /// 无参数；使用已确认区域及固定边界启动串行截图，来源应用直接接收手动滚动。
    func startScrolling() async throws {
        try begin()
        let token = id
        details["kind"] = "scrolling"
        do {
            guard let region else { throw GIFExporter.ExportError(message: "请先明确框选长截图区域。") }
            let (filter, config) = try await configuration(["kind": CaptureTarget.region.rawValue], video: false)
            guard token == id else { throw CancellationError() }
            let edges = region.edges
            let pointScale = region.scale
            guard edges.top >= 0, edges.bottom >= 0, edges.top <= config.height - 64,
                  edges.bottom <= config.height - 64 - edges.top else {
                throw GIFExporter.ExportError(message: "固定区域须为非负整数，正文至少保留64像素。")
            }
            let stitcher = ScrollStitcher(edges: edges)
            finishScroll = false
            // 自动滚动只在设置为自动时启用；选区中心是辅助功能命中测试的位置（#112）。
            let automatic = AppPreferences.current[
                AppConstants.scrollCaptureModeKey
            ] as? String == ScrollCaptureMode.automatic.rawValue
            autoScrollAvailable = automatic
            autoScrollActive = automatic
            scrollHintSerial = 0
            if automatic { watchScrollTakeover() }
            // configuration 已按实际采集范围设置 captureFrame。
            let center = CaptureGeometry.cgPoint(fromAppKitPoint: NSPoint(x: captureFrame!.midX, y: captureFrame!.midY))
            update(.scrolling, ["height": config.height, "width": config.width, "frames": 0])
            scrollTask = Task.detached { [weak self] in
                guard let self else { return }
                var warning: String?
                // 最近一次移动接不上时的原因；之后接上或回到参照画面即清除，结束时仍未接上则随结果说明。
                var unmatched: String?
                var lastHint: ContinuousClock.Instant?
                // 自动滚动：plan 计算步进，target 在首次开始时按选区中心解析，driving 为本轮是否正由 App 滚动，
                // previousValue 为最近一步之前的滚动条值，供接缝失败时退回。
                var plan = AutoScrollPlan(height: config.height)
                var target: AutoScrollTarget?
                var driving = false
                var previousValue: Double?
                // 缩略图只在确认帧数或回退目标状态变化时重绘。
                var previewFrames = 0
                var previewMarked = false
                let clock = ContinuousClock()
                do {
                    while !Task.isCancelled {
                        let state = await MainActor.run {
                            if self.phase == .pausing { self.update(.paused) }
                            return (self.finishScroll, self.phase == .paused, self.autoScrollActive)
                        }
                        if state.0 { break }
                        // 暂停或用户接管都结束本轮自动滚动；恢复后重新开始一轮。
                        if state.1 || !state.2 { driving = false }
                        if state.1 {
                            try await Task.sleep(for: .milliseconds(100))
                            continue
                        }
                        // 以采集开始时刻计100ms周期；截图和拼接耗时包含在周期内，避免快滚时额外空等。
                        let nextCapture = clock.now.advanced(by: .milliseconds(100))
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        try Task.checkCancellation()
                        let accept = await MainActor.run { self.id == token && self.phase == .scrolling }
                        if accept {
                            // CPU拼接留在工作线程；下一轮边界确认暂停，保留当前已接受帧。
                            var hint: (text: String, isError: Bool)?
                            var action = AutoScrollPlan.Action.wait
                            let heightBefore = stitcher.height
                            let framesBefore = stitcher.acceptedFrames
                            do {
                                // 单帧位移超过允许最大值的60%即预警，在接不上之前提醒放慢；自动滚动由步进控制，不提示。
                                if try stitcher.append(image), !driving, stitcher.lastShiftRatio > 0.6 {
                                    hint = ("滚动较快，请放慢", false)
                                }
                                unmatched = nil
                                // 首帧之后新增的长图高度即本帧正文位移。
                                if driving { action = plan.frame(shift: framesBefore > 0 ? stitcher.height - heightBefore : 0, now: clock.now) }
                            } catch let failure as ScrollStitcher.Failure where failure.recoverable {
                                // 本帧丢弃，参照帧仍是最后一张已确认画面；用户回滚到重叠范围即可继续，自动滚动退回上一位置后减半重试。
                                unmatched = failure.message
                                if driving { action = plan.mismatch(now: clock.now) }
                                else { hint = ("请往回滚，直到右下角红框里的内容回到选区", true) }
                            }
                            // 提示显示1000ms，同一会话至少间隔1000ms再提示，避免每帧刷新文字。
                            if hint != nil, let last = lastHint, clock.now - last < .milliseconds(1000) { hint = nil }
                            if hint != nil { lastHint = clock.now }
                            let shown = hint
                            var preview: ScrollStitcher.Preview?
                            // 自动滚动接不上时由 App 退回重试，缩略图不标回滚红框；改为手动后才标出（#112）。
                            let marked = unmatched != nil && !driving
                            if stitcher.acceptedFrames != previewFrames || marked != previewMarked {
                                previewFrames = stitcher.acceptedFrames
                                previewMarked = marked
                                // 缩略图图像宽152pt、最大高240pt，按选区所在屏倍率换成像素；不放大小选区。
                                preview = stitcher.preview(
                                    width: Int(((AppConstants.scrollPreviewWidth - AppConstants.scrollPreviewInset * 2) * pointScale).rounded()),
                                    maxHeight: Int((AppConstants.scrollPreviewMaxImageHeight * pointScale).rounded()),
                                    markTarget: previewMarked)
                            }
                            let thumbnail = preview
                            await MainActor.run {
                                guard self.id == token else { return }
                                var values: [String: Any] = ["height": stitcher.height, "frames": stitcher.acceptedFrames]
                                if let shown {
                                    self.scrollHintSerial += 1
                                    values["hint"] = shown.text
                                    values["hintIsError"] = shown.isError
                                    values["hintSerial"] = self.scrollHintSerial
                                }
                                // 缩略图先就位，提示避让时才能读取它的位置。
                                if let thumbnail { self.onScrollPreview?(thumbnail, pointScale) }
                                self.update(self.phase, values)
                            }
                            // 自动滚动在首帧之后开始；首次开始时确认权限并解析选区中心的滚动条（#112）。
                            if state.2, !driving, stitcher.acceptedFrames > 0 {
                                let trusted = AXIsProcessTrusted()
                                // AutoScrollTarget 在选区中心命中来源窗口并找到可设置的纵向滚动条。
                                if target == nil, trusted { target = AutoScrollTarget(point: center) }
                                if let target {
                                    driving = true
                                    // 已在底部时直接按到底处理，不误报不支持。
                                    action = (target.value ?? 0) >= 0.999 ? .bottom : plan.start(now: clock.now)
                                } else {
                                    await self.endAutoScroll(token: token, hint: trusted
                                        ? MediaCaptureService.unsupportedScrollHint : "自动滚动需要辅助功能权限，已改为手动滚动")
                                }
                            }
                            switch action {
                            case .wait:
                                break
                            case .scroll(let step):
                                // 记住本步之前的位置供退回，再写入新的滚动条值；读取或写入失败按不支持处理，
                                // 避免画面不动被误判为到底（#112）。
                                previousValue = target?.value
                                guard let target, let previousValue, target.set(previousValue + step) else {
                                    driving = false
                                    await self.endAutoScroll(token: token, hint: MediaCaptureService.unsupportedScrollHint)
                                    break
                                }
                            case .rewind:
                                // 退回失败同样按不支持处理（#112）。
                                guard let target, let previousValue, target.set(previousValue) else {
                                    driving = false
                                    await self.endAutoScroll(token: token, hint: MediaCaptureService.unsupportedScrollHint)
                                    break
                                }
                            case .bottom:
                                driving = false
                                await MainActor.run {
                                    guard self.id == token, self.phase == .scrolling else { return }
                                    self.showScrollHint("已到底部，已暂停", isError: false, phase: .paused)
                                }
                            case .unsupported:
                                driving = false
                                await self.endAutoScroll(token: token, hint: MediaCaptureService.unsupportedScrollHint)
                            }
                        }
                        if clock.now < nextCapture { try await clock.sleep(until: nextCapture) }
                    }
                } catch is CancellationError { return }
                catch { warning = error.localizedDescription }
                warning = warning ?? unmatched
                guard !Task.isCancelled else { return }
                let delivered: (png: Data, width: Int, height: Int, frames: Int)?
                do {
                    let result = try stitcher.finish()
                    if result.frames < 2 && warning == nil { warning = "未检测到有效滚动，当前结果只有一屏。" }
                    delivered = result
                } catch {
                    // confirmedFrame只编码已接受的首帧；完整合成失败时仍留下可保存的图。
                    warning = warning ?? error.localizedDescription
                    delivered = stitcher.acceptedFrames > 0 ? try? stitcher.confirmedFrame() : nil
                }
                let note = warning
                let image = delivered
                await MainActor.run {
                    self.publishFinishedScroll(png: image?.png, width: image?.width ?? 0, height: image?.height ?? 0,
                        frames: image?.frames ?? 0, failure: note, token: token)
                }
            }
        } catch { if token == id { await fail(error) }; throw error }
    }

    /// png为已编码长图，width/height/frames为源像素与已接受帧数，failure为停止原因，token为会话身份。
    /// 有图像时进入可保存结果并保留原因；没有图像时只记录失败，不交出空图。
    func publishFinishedScroll(png: Data?, width: Int, height: Int, frames: Int, failure: String?, token: String) {
        guard id == token else { return }
        stopWatchingScrollTakeover()
        onActiveChanged?(false)
        guard let png else {
            update(.failed, ["error": failure ?? "无法完成长截图。"])
            return
        }
        var values: [String: Any] = ["imageBytes": FlutterStandardTypedData(bytes: png),
            "width": width, "height": height, "frames": frames, "kind": "scrolling"]
        if let failure { values["warning"] = failure }
        update(.imageReady, values)
    }

    /// text为提示文字，isError为错误样式，phase为发布的阶段（缺省保持当前）；递增提示序号并发布，由采集窗口显示 1000ms。
    private func showScrollHint(_ text: String, isError: Bool, phase target: CapturePhase? = nil) {
        scrollHintSerial += 1
        update(target ?? phase, ["hint": text, "hintIsError": isError, "hintSerial": scrollHintSerial])
    }

    /// 来源不支持自动滚动（没有可设置的滚动条、读写滚动条失败或首步不移动）时的提示（#112）。
    private static let unsupportedScrollHint = "该区域无法自动滚动，已改为手动滚动"

    /// token为会话身份，hint为改为手动的原因；本次会话改为手动滚动并显示错误提示，移除接管监听，无返回值（#112）。
    private func endAutoScroll(token: String, hint: String) {
        guard id == token else { return }
        autoScrollAvailable = false
        autoScrollActive = false
        stopWatchingScrollTakeover()
        showScrollHint(hint, isError: true)
    }

    /// 无参数；自动滚动期间安装只读全局滚轮监听：用户在采集选区内滚动时本次改为手动并提示，选区外滚动不影响（#112）。
    /// 自动滚动只写滚动条值、不产生滚轮事件，监听到的都是用户操作；监听不消费事件。
    private func watchScrollTakeover() {
        scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, self.autoScrollActive, self.phase == .scrolling,
                      self.captureFrame?.contains(location) == true else { return }
                self.autoScrollActive = false
                self.showScrollHint("已切换为手动滚动", isError: false)
            }
        }
    }

    /// 无参数；移除接管监听，无返回值。
    private func stopWatchingScrollTakeover() {
        if let scrollWheelMonitor { NSEvent.removeMonitor(scrollWheelMonitor) }
        scrollWheelMonitor = nil
    }

    /// path为已经写入日期目录的PNG；保留当前长图，只公开保存路径。
    func noteSavedScroll(_ path: String) {
        guard phase == .imageReady else { return }
        update(.imageReady, ["savedPath": path])
    }

    /// 无参数；只返回已经可解码的录制路径，未完成或正在导出时拒绝。
    func recordingURL() throws -> URL {
        guard phase == .videoReady, let video else { throw GIFExporter.ExportError(message: "请先完成录制。") }
        return video
    }

    /// 无参数；返回完整录制供系统播放器只读使用，转换期间不改变源文件。
    func previewURL() throws -> URL {
        guard [.videoReady, .converting].contains(phase), let video else {
            throw GIFExporter.ExportError(message: "当前没有可预览的录制。")
        }
        return video
    }

    /// range为结果页确认的区间，nil恢复完整视频；只在视频结果空闲时更新，不改写源文件（#110）。
    func setTrim(_ range: CMTimeRange?) throws {
        _ = try recordingURL()
        trim = range
    }

    /// target为分类日期目录内的默认路径；未裁剪时直接发布源MP4，裁剪后在后台重新编码所选区间。
    /// 发布时防覆盖，公开实际保存路径并保留预览。
    func saveVideo(to target: URL) throws {
        let source = try recordingURL()
        guard let trim else {
            let saved = try ScreenshotStorage.publish(source: source, target: target)
            update(.videoReady, ["savedPath": saved.path])
            return
        }
        // trimVideo按区间重新编码到临时路径，转换流程负责进度、取消与发布。
        try convert(.mp4, to: target, pathKey: "savedPath") { destination, progress in
            try await Self.trimVideo(source: source, range: trim, destination: destination, progress: progress)
        }
    }

    /// source为只读录制，range为裁剪区间，destination为新临时MP4路径，progress回报0–1进度；
    /// 按区间重新编码，无返回值。直通复制只能从关键帧起切，时长会与所选区间不一致，因此不用直通。
    static func trimVideo(source: URL, range: CMTimeRange, destination: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source),
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw GIFExporter.ExportError(message: "无法创建视频导出，请重试。")
        }
        session.timeRange = range
        // states按间隔报告编码进度；导出结束后取消观察。
        let observer = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { observer.cancel() }
        // 任务取消时系统同步取消导出并抛出CancellationError。
        try await session.export(to: destination, as: .mp4)
    }

    /// format为GIF或APNG，options为截图设置中的导出设置，target为分类日期路径；
    /// 后台按裁剪区间（未裁剪为完整视频）逐帧编码，源MP4保持只读。
    func exportAnimation(_ format: GIFExporter.Format, options: GIFExporter.Options, to target: URL) throws {
        let source = try recordingURL()
        let range = trim
        try convert(format.kind, to: target, pathKey: format.pathKey) { destination, progress in
            _ = try await GIFExporter.export(source: source, destination: destination, options: options,
                                             format: format, range: range, progress: progress)
        }
    }

    /// target为分类日期路径；后台按裁剪区间（未裁剪为完整视频）把源视频编码为保持原分辨率与原帧时间的 VP8 WebM，
    /// 源MP4保持只读（#110）。
    func exportWebM(to target: URL) throws {
        let source = try recordingURL()
        let range = trim
        try convert(.webm, to: target, pathKey: "webmPath") { destination, progress in
            // WebMExporter 把帧转为 BT.601 矩阵，经不挂窗口的 WebKit 编码 VP8 并写成 WebM。
            _ = try await WebMExporter.export(source: source, destination: destination, range: range, progress: progress)
        }
    }

    /// kind为导出类型，target为分类日期路径，pathKey为成功后公开保存路径的详情键；
    /// work在后台把结果写入给定临时路径并回报0–1进度。转换期间公开exporting与progress，结束后回到视频结果。
    private func convert(_ kind: RecordingExport, to target: URL, pathKey: String,
                         work: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void) throws {
        let token = id
        guard let temporaryDirectory else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        let destination = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(kind.fileExtension)")
        details.removeValue(forKey: "error")
        update(.converting, ["progress": 0.0, "exporting": kind.rawValue])
        exportTask = Task.detached { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: destination) }
            let outcome: (key: String, value: String)
            do {
                try await work(destination) { progress in
                    DispatchQueue.main.async {
                        guard self.id == token, self.phase == .converting else { return }
                        self.update(.converting, ["progress": progress])
                    }
                }
                try Task.checkCancellation()
                outcome = (pathKey, try ScreenshotStorage.publish(source: destination, target: target).path)
            } catch {
                outcome = ("error", error is CancellationError ? "转换已取消，源视频保持不变。" : error.localizedDescription)
            }
            // 成功与失败都结束转换：撤下exporting，再公开保存路径或原因。
            await MainActor.run {
                guard self.id == token else { return }
                self.details.removeValue(forKey: "exporting")
                self.update(.videoReady, [outcome.key: outcome.value])
            }
        }
    }

    /// 无参数；取消正在进行的MP4/GIF/APNG/WebM转换，保持当前MP4和已保存文件。
    func cancelExport() { exportTask?.cancel() }
}
