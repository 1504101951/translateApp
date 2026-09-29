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

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var temporaryDirectory: URL?
    private var video: URL?
    private var scrollTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var finishScroll = false
    private var discardRecording = false
    private var recordingFailure: String?
    private var recordingSegments: [URL] = []
    private var recordingArguments: [String: Any] = [:]
    private var recordedElapsed: TimeInterval = 0
    private var recordingCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var timer: Timer?
    private var startedAt: Date?
    private(set) var phase = CapturePhase.idle
    private(set) var id = UUID().uuidString
    private(set) var region: Region?
    /// 实际录制配置在AppKit屏幕点坐标中的范围，仅供可见选区遮罩使用。
    private(set) var captureFrame: NSRect?
    private var recordingWindowID: CGWindowID?
    private var details: [String: Any] = [:]
    var onChange: (([String: Any]) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

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

    /// 无参数；权限检查成功后返回显示器/窗口列表，不捕获屏幕像素。
    func sources() async throws -> [[String: Any]] {
        guard await ScreenCaptureService.requestAccess() else {
            throw GIFExporter.ExportError(message: "需要屏幕录制权限，请在系统设置中授权后重试。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        var values: [[String: Any]] = content.displays.map { display in
            ["kind": "display", "sourceID": display.displayID, "name": "显示器 \(display.displayID)（\(display.width)×\(display.height)）"]
        }
        values += content.windows.filter {
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.windowLayer == 0 && $0.frame.width >= 32 && $0.frame.height >= 32
        }.map { window in
            ["kind": "window", "sourceID": window.windowID,
             "name": "\(window.owningApplication?.applicationName ?? "应用") — \(window.title ?? "窗口")"]
        }
        return values
    }

    /// args指定显示器、窗口或已确认区域；返回排除自身窗口且像素倍率正确的捕获配置。
    private func configuration(_ args: [String: Any], video: Bool) async throws -> (SCContentFilter, SCStreamConfiguration) {
        guard ScreenCaptureService.isAuthorized() else { throw GIFExporter.ExportError(message: "屏幕录制权限不可用。") }
        let token = id
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard token == id else { throw CancellationError() }
        guard let kind = args["kind"] as? String else { throw GIFExporter.ExportError(message: "缺少采集方式。") }
        let filter: SCContentFilter
        var crop: CGRect?
        var targetFrame: CGRect
        var targetWindowID: CGWindowID? = nil
        if kind == "window", let number = args["sourceID"] as? NSNumber,
           let window = content.windows.first(where: { $0.windowID == number.uint32Value && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            targetFrame = window.frame
            targetWindowID = window.windowID
        } else {
            let displayID = kind == "region" ? region?.displayID : (args["sourceID"] as? NSNumber)?.uint32Value
            guard ["display", "region"].contains(kind),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw GIFExporter.ExportError(message: "捕获目标已不可用，请重新选择。")
            }
            // 应用的控制、翻译、编辑窗口全部从显示器捕获中排除。
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            guard !own.isEmpty else { throw GIFExporter.ExportError(message: "无法排除采集控制窗口，请重新开始。") }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            targetFrame = display.frame
            if kind == "region", let region {
                guard abs(CGFloat(filter.pointPixelScale) - region.scale) < 0.01 else {
                    throw GIFExporter.ExportError(message: "显示器缩放已改变，请重新框选。")
                }
                crop = CGRect(x: region.rect.minX / region.scale, y: region.rect.minY / region.scale,
                              width: region.rect.width / region.scale, height: region.rect.height / region.scale)
                guard CGRect(origin: .zero, size: filter.contentRect.size).contains(crop!) else {
                    throw GIFExporter.ExportError(message: "选区超出当前显示器，请重新框选。")
                }
            }
        }
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = crop?.size ?? filter.contentRect.size
        var width = Int((size.width * scale).rounded(video ? .down : .toNearestOrAwayFromZero))
        var height = Int((size.height * scale).rounded(video ? .down : .toNearestOrAwayFromZero))
        if video { width -= width % 2; height -= height % 2 }
        guard width >= 32, height >= 64 else { throw GIFExporter.ExportError(message: "选区至少需要32×64像素。") }
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = video
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
        recordingWindowID = targetWindowID
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
        recordingWindowID = nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateApp-Capture-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectory = directory
        update(.preparing)
        onActiveChanged?(true)
    }

    /// args为当前目标；创建独立会话并开始第一段无音轨MP4，暂停恢复保留同一会话。
    func startRecording(_ args: [String: Any]) async throws {
        try begin()
        recordingArguments = args
        details["kind"] = "recording"
        try await startRecordingSegment()
    }

    /// 无参数；为已确认目标追加一段MP4，系统开始回调后才允许暂停或结束。
    private func startRecordingSegment() async throws {
        let token = id
        let previousFrame = captureFrame
        details.removeValue(forKey: "error")
        update(.preparing)
        do {
            // 每段重验目标与授权，窗口关闭或缩放变化时明确失败。
            let (filter, config) = try await configuration(recordingArguments, video: true)
            guard token == id else { throw CancellationError() }
            // 无损合并要求所有段尺寸一致；目标尺寸改变时保留已有段供结束保存。
            if !recordingSegments.isEmpty,
               (details["width"] as? Int != config.width || details["height"] as? Int != config.height) {
                throw GIFExporter.ExportError(message: "目标尺寸已改变，请结束并保存当前录制后重新开始。")
            }
            let outputURL = temporaryDirectory!.appendingPathComponent("segment-\(UUID().uuidString).mp4")
            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = outputURL
            outputConfig.videoCodecType = .h264
            outputConfig.outputFileType = .mp4
            let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addRecordingOutput(output)
            self.stream = stream
            recordingOutput = output
            video = outputURL
            discardRecording = false
            recordingFailure = nil
            details["width"] = config.width
            details["height"] = config.height
            try await stream.startCapture()
        } catch {
            if token == id {
                if recordingSegments.isEmpty { await fail(error) }
                else {
                    // 恢复失败不删除已完成内容；撤销本次输出身份，仍可结束合并或明确放弃。
                    let active = stream
                    stream = nil
                    recordingOutput = nil
                    try? await active?.stopCapture()
                    guard token == id else { throw error }
                    video = recordingSegments.last
                    captureFrame = previousFrame
                    update(.paused, ["error": error.localizedDescription])
                }
            }
            throw error
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
            if details["kind"] as? String == "scrolling" { update(.scrolling); return }
            try await startRecordingSegment()
            return
        }
        guard paused, phase == .recording, let stream else {
            throw GIFExporter.ExportError(message: "当前采集状态不能切换暂停。")
        }
        // 系统编码完成前保持pausing，防止恢复动作复用未完成的输出。
        if let startedAt { recordedElapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        timer?.invalidate()
        timer = nil
        update(.pausing, ["elapsed": recordedElapsed])
        do { try await stream.stopCapture() }
        catch { await fail(error); throw error }
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
        guard phase == .recording, let stream else { return }
        update(.finalizing)
        timer?.invalidate()
        timer = nil
        do { try await stream.stopCapture() }
        catch { await fail(error); throw error }
    }

    /// 无参数；取消当前资源或丢弃预览，只清理本会话创建的私有目录。
    func cancel() async {
        exportTask?.cancel()
        if let exportTask { await exportTask.value }
        self.exportTask = nil
        scrollTask?.cancel()
        if let scrollTask { await scrollTask.value }
        self.scrollTask = nil
        if let stream {
            let token = id
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
        let waiters = recordingCompletionWaiters
        recordingCompletionWaiters = []
        timer?.invalidate()
        timer = nil
        stream = nil
        recordingOutput = nil
        video = nil
        recordingSegments = []
        recordingArguments = [:]
        recordedElapsed = 0
        startedAt = nil
        captureFrame = nil
        recordingWindowID = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        details = [:]
        id = UUID().uuidString
        onActiveChanged?(false)
        update(.idle)
        for waiter in waiters { waiter.resume() }
    }

    /// error为系统实际错误；停止占用资源并保留原因，不交付损坏MP4。
    private func fail(_ error: Error) async {
        let active = stream
        stream = nil
        recordingOutput = nil
        try? await active?.stopCapture()
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
                    if let windowID = self.recordingWindowID, let frame = self.captureFrame {
                        // 窗口目标随已有每秒状态同步位置，编码范围和流配置保持固定。
                        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
                              let bounds = windows.first?[kCGWindowBounds as String] as? [String: Any],
                              var target = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                            do { try await self.stop() }
                            catch { /* stop已发布流停止失败并清理资源。 */ }
                            return
                        }
                        target.size = frame.size
                        self.captureFrame = CaptureGeometry.appKitRect(fromCGWindowBounds: target)
                    }
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
            let (filter, config) = try await configuration(["kind": "region"], video: false)
            guard token == id else { throw CancellationError() }
            let edges = region.edges
            guard edges.top >= 0, edges.bottom >= 0, edges.top <= config.height - 64,
                  edges.bottom <= config.height - 64 - edges.top else {
                throw GIFExporter.ExportError(message: "固定区域须为非负整数，正文至少保留64像素。")
            }
            let stitcher = ScrollStitcher(edges: edges)
            finishScroll = false
            update(.scrolling, ["height": config.height, "width": config.width, "frames": 0])
            scrollTask = Task.detached { [weak self] in
                guard let self else { return }
                var warning: String?
                do {
                    while !Task.isCancelled {
                        let state = await MainActor.run {
                            if self.phase == .pausing { self.update(.paused) }
                            return (self.finishScroll, self.phase == .paused)
                        }
                        if state.0 { break }
                        if state.1 {
                            try await Task.sleep(for: .milliseconds(250))
                            continue
                        }
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        try Task.checkCancellation()
                        let accept = await MainActor.run { self.id == token && self.phase == .scrolling }
                        if accept {
                            // CPU拼接留在工作线程；下一轮边界确认暂停，保留当前已接受帧。
                            try stitcher.append(image)
                            await MainActor.run {
                                guard self.id == token else { return }
                                self.update(self.phase, ["height": stitcher.height, "frames": stitcher.acceptedFrames])
                            }
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                } catch is CancellationError { return }
                catch { warning = error.localizedDescription }
                guard !Task.isCancelled else { return }
                do {
                    let result = try stitcher.finish()
                    if result.frames < 2 && warning == nil { warning = "未检测到有效滚动，当前结果只有一屏。" }
                    let finalWarning = warning
                    await MainActor.run {
                        guard self.id == token else { return }
                        self.onActiveChanged?(false)
                        var values: [String: Any] = ["imageBytes": FlutterStandardTypedData(bytes: result.png),
                            "width": result.width, "height": result.height, "frames": result.frames]
                        if let finalWarning { values["warning"] = finalWarning }
                        self.update(.imageReady, values)
                    }
                } catch {
                    let failure = warning ?? error.localizedDescription
                    await MainActor.run {
                        guard self.id == token else { return }
                        self.onActiveChanged?(false)
                        self.update(.failed, ["error": failure])
                    }
                }
            }
        } catch { if token == id { await fail(error) }; throw error }
    }

    /// 无参数；只返回已经可解码的录制路径，未完成或正在导出时拒绝。
    func recordingURL() throws -> URL {
        guard phase == .videoReady, let video else { throw GIFExporter.ExportError(message: "请先完成录制。") }
        return video
    }

    /// 无参数；返回完整录制供系统播放器只读使用，GIF转换期间不改变源文件。
    func previewURL() throws -> URL {
        guard [.videoReady, .converting].contains(phase), let video else {
            throw GIFExporter.ExportError(message: "当前没有可预览的录制。")
        }
        return video
    }

    /// path为系统保存面板确认的路径；原子保存当前录制，并公开已保存状态，不清理预览。
    func saveVideo(to target: URL) throws {
        let source = try recordingURL()
        try GIFExporter.publish(source: source, target: target)
        update(.videoReady, ["savedPath": target.path])
    }

    /// options为已校验片段，target由系统面板确认；后台逐帧编码并报告进度，原MP4保持只读。
    func exportGIF(options: GIFExporter.Options, to target: URL) throws {
        let source = try recordingURL()
        let token = id
        guard let temporaryDirectory else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        let destination = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
        details.removeValue(forKey: "error")
        update(.converting, ["progress": 0.0])
        exportTask = Task.detached { [weak self] in
                guard let self else { return }
            defer { try? FileManager.default.removeItem(at: destination) }
            do {
                _ = try await GIFExporter.export(source: source, destination: destination, options: options) { progress in
                    DispatchQueue.main.async {
                        guard self.id == token, self.phase == .converting else { return }
                        self.update(.converting, ["progress": progress])
                    }
                }
                try Task.checkCancellation()
                try GIFExporter.publish(source: destination, target: target)
                await MainActor.run {
                    guard self.id == token else { return }
                    self.update(.videoReady, ["gifPath": target.path])
                }
            } catch {
                let message = error is CancellationError ? "GIF转换已取消，源视频保持不变。" : error.localizedDescription
                await MainActor.run {
                    guard self.id == token else { return }
                    self.update(.videoReady, ["error": message])
                }
            }
        }
    }

    /// 无参数；取消正在转换的GIF，保持当前MP4和已保存文件。
    func cancelGIF() { exportTask?.cancel() }
}
