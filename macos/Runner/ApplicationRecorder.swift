import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

/// 应用录制的固定桌面画布；显示器点坐标统一映射到最高倍率，空隙保留黑色。
struct ApplicationCaptureCanvas: Equatable {
    /// id是显示器身份，frame是全局CG点坐标，scale是该显示器实际像素倍率。
    struct Display: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }
    let displays: [Display]
    let bounds: CGRect
    let scale: CGFloat
    let size: CGSize

    /// displays为完整显示器拓扑；返回固定画布，拒绝无效几何，不裁掉任何显示器。
    init(displays: [Display]) throws {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({ $0.scale.isFinite && $0.scale > 0 &&
                !$0.frame.isEmpty && !$0.frame.isInfinite && !$0.frame.isNull &&
                [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].allSatisfy(\.isFinite) }) else {
            throw GIFExporter.ExportError(message: "显示器布局无效，无法建立应用录制画布。")
        }
        self.displays = displays.sorted { $0.id < $1.id }
        bounds = displays.dropFirst().reduce(displays[0].frame) { $0.union($1.frame) }
        scale = displays.map(\.scale).max()!
        // H264需要偶数尺寸；向外补黑边，不截去显示器末端像素。
        size = CGSize(width: ceil(bounds.width * scale / 2) * 2,
                      height: ceil(bounds.height * scale / 2) * 2)
    }

    /// frames为每屏最新完整图像；返回联合画布CI图像，转换CG顶部原点为CI底部原点。
    func composite(_ frames: [CGDirectDisplayID: CIImage]) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        var image = CIImage(color: .black).cropped(to: extent)
        for display in displays {
            guard let frame = frames[display.id] else { continue }
            let rect = CGRect(x: (display.frame.minX - bounds.minX) * scale,
                y: size.height - (display.frame.maxY - bounds.minY) * scale,
                width: display.frame.width * scale, height: display.frame.height * scale)
            // 放大时延伸边缘像素供插值采样，映射后再裁剪，防止透明边缘污染显示器及黑色空区。
            let content = frame.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: rect.width / frame.extent.width, y: rect.height / frame.extent.height))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                .cropped(to: rect)
            image = content.composited(over: image)
        }
        return image.cropped(to: extent)
    }
}

/// 串行处理每屏最新帧与视频编码；所有可变字段仅在queue读写，内存不积累历史帧。
final class ApplicationVideoEncoder: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "TranslateApp.application-video")
    let canvas: ApplicationCaptureCanvas
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var streams: [ObjectIdentifier: CGDirectDisplayID] = [:]
    private var frames: [CGDirectDisplayID: CIImage] = [:]
    private var timer: DispatchSourceTimer?
    private var epoch: CMTime?
    private var lastTime = CMTime.zero
    private var ready: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var finishing = false
    private let onFailure: @Sendable (Error) -> Void

    /// canvas为固定画布，url为本段MP4，onFailure报告实际编码错误；初始化时验证编码器是否支持尺寸。
    init(canvas: ApplicationCaptureCanvas, url: URL, onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.canvas = canvas
        self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // 合成像素为sRGB；明确编码色度矩阵与传递函数，避免播放器按分辨率猜测颜色。
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.size.width), AVVideoHeightKey: Int(canvas.size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 30]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw GIFExporter.ExportError(message: "编码器不支持当前显示器联合画布尺寸，请调整显示器布局后重试。")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.size.width),
                kCVPixelBufferHeightKey as String: Int(canvas.size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        super.init()
        guard writer.canAdd(input) else { throw GIFExporter.ExportError(message: "无法建立应用录制编码轨道。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GIFExporter.ExportError(message: "无法启动应用录制编码器。") }
    }

    /// identities将每个流映射到显示器；启动前注册，无返回值。
    func register(_ identities: [ObjectIdentifier: CGDirectDisplayID]) { queue.sync { streams = identities } }

    /// 无参数；等待全部显示器第一张完整帧，超时明确失败，避免开始录制时静默遗漏某个屏幕。
    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // 启动与放弃可交错入队；结束后不得注册永远收不到首帧的等待者。
                guard !self.finishing else { continuation.resume(throwing: CancellationError()); return }
                if let failure = self.failure { continuation.resume(throwing: failure); return }
                if self.epoch != nil { continuation.resume(); return }
                self.ready = continuation
                self.queue.asyncAfter(deadline: .now() + 5) {
                    guard self.ready != nil else { return }
                    self.report(GIFExporter.ExportError(message: "未能取得全部显示器画面，应用录制未开始。"))
                }
            }
        }
    }

    /// stream为已注册屏幕流，sampleBuffer为系统帧；只接收完整图像，静止帧保持已有内容。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, failure == nil, type == .screen,
              let display = streams[ObjectIdentifier(stream)],
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle || (status == .started && CMSampleBufferGetImageBuffer(sampleBuffer) == nil) { return }
        guard status == .complete || status == .started, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            report(GIFExporter.ExportError(message: "显示器画面已中断，已停止应用录制。"))
            return
        }
        // receive统一接收已校验的屏幕图像；帧合成与系统采集回调保持独立职责。
        receive(CIImage(cvPixelBuffer: buffer), display: display)
    }

    /// image为某屏完整图像，display为画布中的显示器身份；必须在queue调用，返回前只保留最新帧。
    func receive(_ image: CIImage, display: CGDirectDisplayID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing, failure == nil, canvas.displays.contains(where: { $0.id == display }) else { return }
        frames[display] = image
        guard epoch == nil, frames.count == canvas.displays.count else { return }
        writer.startSession(atSourceTime: .zero)
        epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30))
        timer.setEventHandler { [weak self] in self?.appendFrame() }
        self.timer = timer
        timer.resume()
        // 首帧真实写入后才解除准备状态；快速点击暂停也有可保留画面。
        appendFrame()
        guard failure == nil else { return }
        ready?.resume()
        ready = nil
    }

    /// 无参数；将当前每屏帧按同一主机时钟合成，编码背压时保留后续真实时间而不缩短视频。
    private func appendFrame() {
        guard !finishing, failure == nil, let epoch else { return }
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { report(writer.error ?? GIFExporter.ExportError(message: "应用录制编码失败。")) }
            return
        }
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { report(GIFExporter.ExportError(message: "联合画布无法分配像素缓冲，请缩小显示器布局。")); return }
        // composite唯一负责桌面坐标映射；输出始终覆盖完整黑色底画布。
        context.render(canvas.composite(frames), to: buffer, bounds: CGRect(origin: .zero, size: canvas.size),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let time = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), epoch)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            report(writer.error ?? GIFExporter.ExportError(message: "无法追加应用录制画面。")); return
        }
        lastTime = time
    }

    /// error为实际失败；仅报告一次，完成首帧等待并停止产生新输出，已有可解码内容由finish交付。
    private func report(_ error: Error) {
        guard failure == nil, !finishing else { return }
        failure = error
        timer?.cancel()
        timer = nil
        ready?.resume(throwing: error)
        ready = nil
        onFailure(error)
    }

    /// discard为明确放弃；结束串行写入并等待MP4尾部完成，失败不交付坏文件。
    func finish(discard: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.finishing = true
                self.timer?.cancel()
                self.timer = nil
                self.ready?.resume(throwing: CancellationError())
                self.ready = nil
                self.frames = [:]
                if discard || self.epoch == nil {
                    self.writer.cancelWriting()
                    if discard { continuation.resume() }
                    else { continuation.resume(throwing: self.failure ?? GIFExporter.ExportError(message: "没有可保留的应用录制画面。")) }
                    return
                }
                self.writer.endSession(atSourceTime: CMTimeAdd(self.lastTime, CMTime(value: 1, timescale: 30)))
                self.input.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: self.writer.error ?? GIFExporter.ExportError(message: "应用录制未能完成编码。")) }
                }
            }
        }
    }
}

/// 应用录制的逐屏流生命周期；主执行器管理系统资源，编码帧交给独立串行队列。
@MainActor
final class ApplicationRecorder: NSObject, SCStreamDelegate {
    let canvas: ApplicationCaptureCanvas
    private let applicationID: String
    private let encoder: ApplicationVideoEncoder
    private var streams: [SCStream] = []
    private let background = CGColor(gray: 0, alpha: 1)
    private var ended = false
    private var finishTask: Task<Void, Error>?
    private let onFailure: @MainActor (Error) -> Void

    /// content为当前授权来源，applicationID为用户选择的Bundle ID，expected为暂停前拓扑，url为本段文件。
    init(content: SCShareableContent, applicationID: String, expected: ApplicationCaptureCanvas?, url: URL,
         onFailure: @escaping @MainActor (Error) -> Void) async throws {
        let apps = content.applications.filter { $0.bundleIdentifier == applicationID }
        guard applicationID != Bundle.main.bundleIdentifier, !apps.isEmpty,
              content.windows.contains(where: { $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 && $0.owningApplication?.bundleIdentifier == applicationID }) else {
            throw GIFExporter.ExportError(message: "所选应用已退出或没有可录制的可见窗口。")
        }
        self.applicationID = applicationID
        self.onFailure = onFailure
        let filters = content.displays.map { display in
            (display, SCContentFilter(display: display, including: apps, exceptingWindows: []))
        }
        canvas = try ApplicationCaptureCanvas(displays: filters.map {
            .init(id: $0.0.displayID, frame: $0.0.frame, scale: CGFloat($0.1.pointPixelScale))
        })
        guard expected == nil || expected == canvas else {
            throw GIFExporter.ExportError(message: "显示器布局或倍率已改变，请结束并保存当前录制后重新开始。")
        }
        // 编码器尺寸探测与硬件初始化是同步系统调用；在后台完成，准备期间主执行器仍可处理取消和绘制。
        let encodingCanvas = canvas
        encoder = try await Task.detached(priority: .userInitiated) {
            try ApplicationVideoEncoder(canvas: encodingCanvas, url: url) { error in
                Task { @MainActor in onFailure(error) }
            }
        }.value
        super.init()
        var identities: [ObjectIdentifier: CGDirectDisplayID] = [:]
        for (display, filter) in filters {
            filter.includeMenuBar = false
            let config = SCStreamConfiguration()
            config.width = Int((display.frame.width * CGFloat(filter.pointPixelScale)).rounded())
            config.height = Int((display.frame.height * CGFloat(filter.pointPixelScale)).rounded())
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.backgroundColor = background
            config.ignoreShadowsDisplay = true
            config.showsCursor = false
            config.capturesAudio = false
            config.captureMicrophone = false
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(encoder, type: .screen, sampleHandlerQueue: encoder.queue)
            streams.append(stream)
            identities[ObjectIdentifier(stream)] = display.displayID
        }
        // 编码器只接受本段流身份，后续回调不能串入其他会话。
        encoder.register(identities)
    }

    /// 无参数；启动所有显示器流并等待完整首帧，任何失败均由调用方统一结束本段资源。
    func start() async throws {
        for stream in streams {
            guard !ended else { throw CancellationError() }
            try await stream.startCapture()
            if ended { try? await stream.stopCapture(); throw CancellationError() }
        }
        try await encoder.waitUntilReady()
    }

    /// 无参数；核对应用存活、可见窗口及完整显示器拓扑，变化时明确失败，不选择其他应用。
    func validate() async throws {
        guard ScreenCaptureService.isAuthorized() else { throw GIFExporter.ExportError(message: "屏幕录制权限已失效。") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard content.windows.contains(where: { $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 && $0.owningApplication?.bundleIdentifier == applicationID }) else {
            throw GIFExporter.ExportError(message: "所选应用已退出或没有可录制的可见窗口。")
        }
        let current = try ApplicationCaptureCanvas(displays: content.displays.map {
            .init(id: $0.displayID, frame: $0.frame,
                  scale: CGFloat(SCContentFilter(display: $0, excludingWindows: []).pointPixelScale))
        })
        guard current == canvas else { throw GIFExporter.ExportError(message: "显示器布局或倍率已改变，已停止并保留录制内容。") }
    }

    /// discard为明确放弃；等待所有流停止和编码完成，仅调用一次，无返回数据。
    func finish(discard: Bool) async throws {
        if let finishTask { return try await finishTask.value }
        ended = true
        let active = streams
        streams = []
        let task = Task { @MainActor in
            for stream in active { try? await stream.stopCapture() }
            try await encoder.finish(discard: discard)
        }
        finishTask = task
        try await task.value
    }

    /// stopped为中断流；系统错误回到主执行器，由会话协调器结束并保留可解码片段。
    nonisolated func stream(_ stopped: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard !ended, streams.contains(where: { $0 === stopped }) else { return }
            onFailure(error)
        }
    }
}
