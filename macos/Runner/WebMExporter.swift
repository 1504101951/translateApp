import AVFoundation
import Foundation
import VideoToolbox
import WebKit

/// 录制视频的 WebM 导出（#110）：`FrameSource` 按区间读出 NV12 帧并转为 BT.601 矩阵，不挂窗口的 `WKWebView`
/// 用 WebCodecs 编码 VP8，`WebMWriter` 写成文件。保持源分辨率与源帧时间，不新增依赖，不修改源视频。
/// 选用 VP8：WebKit 的 VP9 编码器在码率不足时丢帧（忽略 latencyMode，不支持 quantizer 码率模式），不能保持源帧时间；
/// WebKit 的 VP9 编码不再丢帧或支持 quantizer 码率模式时重新评估。
enum WebMExporter {
    /// 关键帧间隔（微秒）：按时间戳每 2 秒一个，变帧率时与帧数无关。
    private static let keyFrameInterval: Int64 = 2_000_000
    /// 页面内编码队列上限；超过时等待编码器出队，限制排队的未编码帧内存。
    private static let encodeQueueLimit = 4

    /// 源帧色域与传递特性附件值到 WebCodecs 名称与 Matroska Colour 代码（ISO/IEC 23091-4）的映射，按附件键分组；
    /// 只收录 H.264 录制会出现的标注，其他标注直接拒绝导出，不猜测颜色。矩阵固定转为 BT.601，不查表。
    private static let colourTable: [String: [String: (name: String, code: UInt64)]] = [
        kCVImageBufferColorPrimariesKey as String: [
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String: ("bt709", 1),
            kCVImageBufferColorPrimaries_SMPTE_C as String: ("smpte170m", 6),
            kCVImageBufferColorPrimaries_EBU_3213 as String: ("bt470bg", 5),
        ],
        kCVImageBufferTransferFunctionKey as String: [
            kCVImageBufferTransferFunction_ITU_R_709_2 as String: ("bt709", 1),
            kCVImageBufferTransferFunction_sRGB as String: ("iec61966-2-1", 13),
        ],
    ]

    /// source只读；destination必须是新临时路径；range为裁剪区间（nil为完整视频）；progress输出0–1进度；成功返回帧数。
    /// 帧时间取源帧呈现时间减区间起点，码率取源视频轨的 estimatedDataRate。本机 WebKit 不支持 VP8、色彩标注无法写入、
    /// 编码失败或编码器丢帧时抛出 [GIFExporter.ExportError]，并删除未完成的输出。
    /// 编码会话与写文件在主线程，`WKWebView` 只在主线程创建与释放；读帧与色彩转换由 `FrameSource` 在后台执行。
    @MainActor
    static func export(source: URL, destination: URL, range: CMTimeRange?,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GIFExporter.ExportError(message: "录制文件没有可读取的视频画面。")
        }
        // ScreenCaptureKit 写出的录制没有旋转变换，按 naturalSize 编码即为显示尺寸。
        let (size, dataRate) = try await track.load(.naturalSize, .estimatedDataRate)
        let assetDuration = try await asset.load(.duration)
        let window = range ?? CMTimeRange(start: .zero, duration: assetDuration)
        let duration = microseconds(window.duration)
        let width = Int(size.width), height = Int(size.height)
        let frames = try FrameSource(asset: asset, track: track, range: window, width: width, height: height)
        // next 在后台解码并转换下一帧。
        guard var next = try await frames.next() else { throw GIFExporter.ExportError(message: "所选区间没有视频画面。") }
        // colorimetry 读取首帧色彩附件，编码与容器使用同一标注。
        let colour = try colorimetry(of: next.source)
        let session = EncoderSession()
        try await session.load()
        let config: [String: Any] = [
            "codec": "vp8", "width": width, "height": height, "bitrate": Int(dataRate),
            "framerate": AppConstants.recordingFramesPerSecond, "latencyMode": "quality",
        ]
        guard try await session.begin(config: config, colorSpace: colour.webCodecs,
                                      keyFrameInterval: keyFrameInterval, queueLimit: encodeQueueLimit) else {
            throw GIFExporter.ExportError(message: "本机 WebKit 不支持 VP8 编码，无法导出 WebM。")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let writer = try WebMWriter(url: destination, width: width, height: height, duration: duration, colour: colour.matroska)
        var count = 0
        while true {
            try Task.checkCancellation()
            // 区间起点之前开始显示、跨过起点的首帧从 0 计时。
            let timestamp = max(0, microseconds(next.time - window.start))
            // encode 把本帧交给页面编码，返回此前已产出的编码帧。
            for frame in try await session.encode(next.pixels, timestamp: timestamp) { try writer.append(frame) }
            count += 1
            progress(Double(timestamp) / Double(duration))
            guard let frame = try await frames.next() else { break }
            next = frame
        }
        for frame in try await session.finish() { try writer.append(frame) }
        try Task.checkCancellation()
        // 输出帧数须等于读入帧数，否则帧时间不再与源一致，finish 报错不发布。
        try writer.finish(expectedFrames: count)
        completed = true
        return count
    }

    /// time为媒体时间；返回四舍五入到微秒的整数。
    private static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }

    /// buffer为首帧源像素缓冲；返回 VideoFrame 的 colorSpace 与 Matroska Colour 代码（矩阵为转换后的 BT.601），
    /// 色域或传递特性附件缺失、不在映射表内时抛出错误。
    private static func colorimetry(of buffer: CVPixelBuffer) throws -> (webCodecs: [String: Any], matroska: WebMWriter.Colour) {
        var names: [String: String] = [:]
        var codes: [String: UInt64] = [:]
        for (key, entries) in colourTable {
            let value = CVBufferCopyAttachment(buffer, key as CFString, nil) as? String
            guard let value, let entry = entries[value] else {
                throw GIFExporter.ExportError(message: "录制视频的色彩标注（\(value ?? "缺失")）无法写入 WebM。")
            }
            names[key] = entry.name
            codes[key] = entry.code
        }
        let primaries = kCVImageBufferColorPrimariesKey as String
        let transfer = kCVImageBufferTransferFunctionKey as String
        // BT.601 矩阵对应 WebCodecs smpte170m 与 Matroska 代码 6；NV12 视频范围对应 fullRange=false 与 Range=1。
        return (["matrix": "smpte170m", "primaries": names[primaries]!, "transfer": names[transfer]!, "fullRange": false],
                .init(matrix: 6, transfer: codes[transfer]!, primaries: codes[primaries]!))
    }

    /// 编码页面：宿主依次调用 begin、每帧一次 step、最后 finish；编码块以 base64 随返回值交回宿主。
    fileprivate static let page = """
    <!doctype html><meta charset="utf-8"><script>
    let encoder = null, frameInit = null, failure = null, wake = null, lastKey = -Infinity, interval = 0, limit = 0;
    const produced = [];
    // 脚本返回值不能携带二进制，编码块转为 base64 字符串。
    const base64 = (bytes) => {
      let text = '';
      for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
      return btoa(text);
    };
    const take = () => { if (failure) throw new Error(failure); return produced.splice(0); };
    async function begin(config, colorSpace, keyInterval, queueLimit) {
      if (!(await VideoEncoder.isConfigSupported(config)).supported) return false;
      encoder = new VideoEncoder({
        output: (chunk) => {
          const bytes = new Uint8Array(chunk.byteLength);
          chunk.copyTo(bytes);
          produced.push({ timestamp: chunk.timestamp, key: chunk.type === 'key', data: base64(bytes) });
        },
        error: (error) => { failure = error.message; if (wake) wake(); },
      });
      encoder.configure(config);
      frameInit = { format: 'NV12', codedWidth: config.width, codedHeight: config.height, colorSpace };
      interval = keyInterval;
      limit = queueLimit;
      return true;
    }
    async function step(timestamp) {
      const buffer = await (await fetch('/frame')).arrayBuffer();
      const frame = new VideoFrame(buffer, { ...frameInit, timestamp });
      const key = timestamp - lastKey >= interval;
      if (key) lastKey = timestamp;
      encoder.encode(frame, { keyFrame: key });
      frame.close();
      // 队列超限时等待出队或编码错误；本次宿主调用期间页面保持活动。
      while (encoder.encodeQueueSize > limit && !failure) {
        await new Promise((resolve) => { wake = resolve; encoder.addEventListener('dequeue', resolve, { once: true }); });
      }
      return take();
    }
    async function finish() {
      await encoder.flush();
      encoder.close();
      return take();
    }
    </script>
    """
}

/// 按区间顺序读取录制帧并转为 BT.601 矩阵的紧密 NV12 像素（#110）；`next` 在调用方 actor 之外执行解码、转换与拷贝。
private final class FrameSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let transfer: VTPixelTransferSession
    /// 转换目标；每帧拷贝成 Data 后复用。
    private let converted: CVPixelBuffer

    /// asset/track为录制及其视频轨，range为读取区间，width/height为像素尺寸（偶数）；开始读取并创建色彩转换，失败抛出错误。
    init(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, width: Int, height: Int) throws {
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        // 读取解码器的 NV12 视频范围帧，不经过 RGB 往返转换。
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        var session: VTPixelTransferSession?
        var buffer: CVPixelBuffer?
        guard reader.startReading(),
              VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session,
              CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw GIFExporter.ExportError(message: reader.error?.localizedDescription ?? "无法读取录制视频。")
        }
        // VP8 码流只能按 BT.601 解释颜色：按源附件的矩阵重新计算 YCbCr，色域与传递特性不变。
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        transfer = session
        converted = buffer
    }

    /// 无参数；返回下一帧的 BT.601 紧密 NV12 像素（Y 平面后接 UV 平面）、源像素缓冲与呈现时间；读完返回 nil，读取或转换失败抛出错误。
    func next() async throws -> (pixels: Data, source: CVPixelBuffer, time: CMTime)? {
        // 读取器可能交付不含图像的标记样本，跳过它们。
        while let sample = output.copyNextSampleBuffer() {
            guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard VTPixelTransferSessionTransferImage(transfer, from: source, to: converted) == noErr else {
                throw GIFExporter.ExportError(message: "录制视频的色彩转换失败。")
            }
            return (packed(converted), source, CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard reader.status == .completed else {
            throw GIFExporter.ExportError(message: reader.error?.localizedDescription ?? "读取录制视频失败。")
        }
        return nil
    }

    /// buffer为NV12像素缓冲（宽高为偶数）；返回去掉行尾填充、Y平面后接UV平面的紧密像素。
    private func packed(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var data = Data(capacity: width * height * 3 / 2)
        // UV平面每行同样是 width 字节（Cb、Cr 交错），行数为一半。
        for (plane, rows) in [(0, height), (1, height / 2)] {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<rows { data.append(base + row * stride, count: width) }
        }
        return data
    }
}

/// 不挂窗口的 WKWebView 编码会话（#110）：宿主逐帧调用页面，页面经自定义协议读取当前帧并返回已产出的编码块。
/// 已知限制：隐藏页面在没有宿主请求时会被 WebKit 挂起，页面内的定时器、编码器出队事件与 Worker 都会停住，
/// 因此编码循环由宿主驱动，每帧一次 callAsyncJavaScript。WebKit 提供公开的隐藏页面保活能力，或导出出现停滞时重新评估。
@MainActor
private final class EncoderSession: NSObject, WKNavigationDelegate {
    private let server = FrameServer()
    private let webView: WKWebView
    private var loading: CheckedContinuation<Void, Error>?

    /// 无参数；创建注册了编码协议的 WKWebView，尚未加载页面。
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(server, forURLScheme: AppConstants.webMEncoderScheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// 无参数；加载编码页面并等待导航完成，加载失败抛出导航错误。
    func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            webView.load(URLRequest(url: URL(string: "\(AppConstants.webMEncoderScheme)://encoder/index.html")!))
        }
    }

    /// config为 VideoEncoder 配置，colorSpace为 VideoFrame 色彩，keyFrameInterval为关键帧间隔（微秒），queueLimit为编码队列上限；
    /// 返回本机是否支持该配置，支持时页面已创建编码器。
    func begin(config: [String: Any], colorSpace: [String: Any], keyFrameInterval: Int64, queueLimit: Int) async throws -> Bool {
        try await call("return await begin(config, colorSpace, interval, limit)", [
            "config": config, "colorSpace": colorSpace, "interval": keyFrameInterval, "limit": queueLimit,
        ]) as! Bool
    }

    /// frame为紧密排列的NV12像素，timestamp为相对起点的微秒；送入编码器并返回此前已产出的编码帧。
    func encode(_ frame: Data, timestamp: Int64) async throws -> [WebMWriter.Frame] {
        server.frame = frame
        return Self.frames(try await call("return await step(timestamp)", ["timestamp": timestamp]))
    }

    /// 无参数；冲刷编码器并返回剩余编码帧。
    func finish() async throws -> [WebMWriter.Frame] {
        Self.frames(try await call("return await finish()", [:]))
    }

    /// body为页面函数调用，arguments为参数；返回脚本结果，脚本异常与网页进程退出转为可显示的导出错误。
    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch let error as NSError {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw GIFExporter.ExportError(message: "WebM 编码失败：\(message)")
        }
    }

    /// value为页面返回的编码块数组；返回按产出顺序的编码帧。
    private static func frames(_ value: Any?) -> [WebMWriter.Frame] {
        (value as! [[String: Any]]).map {
            WebMWriter.Frame(timestamp: ($0["timestamp"] as! NSNumber).int64Value, key: $0["key"] as! Bool,
                             data: Data(base64Encoded: $0["data"] as! String)!)
        }
    }

    /// webView为编码视图，navigation为页面导航；页面加载完成，结束等待，无返回值。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume()
        loading = nil
    }

    /// webView为编码视图，navigation为页面导航，error为失败原因；以错误结束等待，无返回值。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    /// webView为编码视图，navigation为页面导航，error为失败原因；以错误结束等待，无返回值。
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error)
        loading = nil
    }
}

/// 编码页面的自定义协议处理：/index.html 返回编码页面，/frame 返回宿主当前待编码的一帧。
@MainActor
private final class FrameServer: NSObject, WKURLSchemeHandler {
    /// 当前待编码帧；宿主每次调用 step 前替换。
    var frame = Data()

    /// webView为编码视图，task为页面请求；按路径返回页面或当前帧，其他路径返回404，无返回值。
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        let (status, type, body): (Int, String, Data) = switch url.path {
        case "/index.html": (200, "text/html", Data(WebMExporter.page.utf8))
        case "/frame": (200, "application/octet-stream", frame)
        default: (404, "text/plain", Data())
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type])!)
        task.didReceive(body)
        task.didFinish()
    }

    /// webView为编码视图，task为已取消的请求；响应同步完成，无需处理，无返回值。
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// WebM（Matroska 子集）写出器（#110）：EBML 头与 Segment（SeekHead、Info、Tracks、Cluster、Cues），时间码精度 1ms。
/// Segment 大小与 SeekHead 中的 Cues 位置先写定宽占位，finish 时回填；最后一帧写成带时长的 BlockGroup。
final class WebMWriter {
    /// 一个编码帧：timestamp为相对起点的微秒，key为是否关键帧，data为VP8编码数据。
    struct Frame {
        let timestamp: Int64
        let key: Bool
        let data: Data
    }

    /// 视频轨的 Colour 代码（ISO/IEC 23091-4）：矩阵、传递特性与色域；范围固定为有限范围（NV12视频范围）。
    struct Colour {
        let matrix: UInt64
        let transfer: UInt64
        let primaries: UInt64
    }

    /// 用到的 Matroska 元素 ID。
    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3, ebmlVersion: UInt32 = 0x4286, ebmlReadVersion: UInt32 = 0x42F7
        static let ebmlMaxIDLength: UInt32 = 0x42F2, ebmlMaxSizeLength: UInt32 = 0x42F3
        static let docType: UInt32 = 0x4282, docTypeVersion: UInt32 = 0x4287, docTypeReadVersion: UInt32 = 0x4285
        static let segment: UInt32 = 0x1853_8067, seekHead: UInt32 = 0x114D_9B74, seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966, timecodeScale: UInt32 = 0x2A_D7B1, duration: UInt32 = 0x4489
        static let muxingApp: UInt32 = 0x4D80, writingApp: UInt32 = 0x5741
        static let tracks: UInt32 = 0x1654_AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7
        static let trackUID: UInt32 = 0x73C5, trackType: UInt32 = 0x83, codecID: UInt32 = 0x86, flagLacing: UInt32 = 0x9C
        static let video: UInt32 = 0xE0, pixelWidth: UInt32 = 0xB0, pixelHeight: UInt32 = 0xBA, colour: UInt32 = 0x55B0
        static let matrixCoefficients: UInt32 = 0x55B1, range: UInt32 = 0x55B9
        static let transferCharacteristics: UInt32 = 0x55BA, primaries: UInt32 = 0x55BB
        static let cluster: UInt32 = 0x1F43_B675, timecode: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0, block: UInt32 = 0xA1, blockDuration: UInt32 = 0x9B, referenceBlock: UInt32 = 0xFB
        static let cues: UInt32 = 0x1C53_BB6B, cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7, cueTrack: UInt32 = 0xF7, cueClusterPosition: UInt32 = 0xF1
    }

    private let handle: FileHandle
    private let durationMs: Int64
    /// Segment 数据起点的文件偏移；Cluster 与 Cues 位置都相对它。
    private let segmentStart: UInt64
    /// SeekHead 中 Cues 位置（8 字节）的文件偏移。
    private let cuesPositionField: UInt64
    private var cluster = Data()
    private var clusterTime: Int64?
    private var cuePoints = Data()
    /// 已收到但尚未写出的帧；收到下一帧或结束时才知道它是否为最后一帧。
    private var held: Frame?
    private var lastTime: Int64?
    /// 已收到的帧数，结束时与读入帧数核对。
    private var received = 0

    /// url为新文件路径，width/height为像素尺寸，duration为总时长（微秒），colour为色彩标注；
    /// 创建文件并写入 EBML 头、Segment 起点、SeekHead、Info 与 Tracks。
    init(url: URL, width: Int, height: Int, duration: Int64, colour: Colour) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw GIFExporter.ExportError(message: "无法创建WebM，请检查磁盘空间与目录权限。")
        }
        handle = try FileHandle(forWritingTo: url)
        durationMs = Self.milliseconds(duration)
        let header = Self.element(ID.ebml, Self.uint(ID.ebmlVersion, 1) + Self.uint(ID.ebmlReadVersion, 1) +
            Self.uint(ID.ebmlMaxIDLength, 4) + Self.uint(ID.ebmlMaxSizeLength, 8) + Self.string(ID.docType, "webm") +
            Self.uint(ID.docTypeVersion, 4) + Self.uint(ID.docTypeReadVersion, 2))
        // Segment 大小先写 8 字节「未知长度」，结束时回填实际长度。
        let segment = Self.id(ID.segment) + Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        // SeekHead 只登记 Cues，位置用定宽 8 字节占位并放在末尾，便于回填。
        let seekHead = Self.element(ID.seekHead, Self.element(ID.seek,
            Self.element(ID.seekID, Self.id(ID.cues)) + Self.uint(ID.seekPosition, 0, width: 8)))
        let info = Self.element(ID.info, Self.uint(ID.timecodeScale, 1_000_000) + Self.float(ID.duration, Double(durationMs)) +
            Self.string(ID.muxingApp, "TranslateApp") + Self.string(ID.writingApp, "TranslateApp"))
        let colourElement = Self.element(ID.colour, Self.uint(ID.matrixCoefficients, colour.matrix) + Self.uint(ID.range, 1) +
            Self.uint(ID.transferCharacteristics, colour.transfer) + Self.uint(ID.primaries, colour.primaries))
        let tracks = Self.element(ID.tracks, Self.element(ID.trackEntry,
            Self.uint(ID.trackNumber, 1) + Self.uint(ID.trackUID, 1) + Self.uint(ID.trackType, 1) +
            Self.string(ID.codecID, "V_VP8") + Self.uint(ID.flagLacing, 0) +
            Self.element(ID.video, Self.uint(ID.pixelWidth, UInt64(width)) + Self.uint(ID.pixelHeight, UInt64(height)) + colourElement)))
        try handle.write(contentsOf: header + segment + seekHead + info + tracks)
        segmentStart = UInt64(header.count + segment.count)
        cuesPositionField = segmentStart + UInt64(seekHead.count - 8)
    }

    /// frame为按时间顺序的编码帧；写出上一帧并暂存本帧，无返回值。
    func append(_ frame: Frame) throws {
        if let held { try write(held, last: false) }
        held = frame
        received += 1
    }

    /// expectedFrames为读入编码器的帧数；收到的帧数不等时抛出错误（编码器丢帧），否则把暂存的最后一帧写成带时长的
    /// BlockGroup，写出 Cues，回填 Segment 大小与 Cues 位置并关闭文件，无返回值。
    func finish(expectedFrames: Int) throws {
        guard received == expectedFrames, let held else {
            throw GIFExporter.ExportError(message: "WebM 编码器丢弃了 \(expectedFrames - received) 帧，帧时间无法与源一致，未保存结果。")
        }
        try write(held, last: true)
        try flushCluster()
        let cuesPosition = try handle.offset() - segmentStart
        try handle.write(contentsOf: Self.element(ID.cues, cuePoints))
        let segmentSize = try handle.offset() - segmentStart
        // 8 字节尺寸字段：首字节 0x01 标记长度，其后 7 字节为大端值。
        try handle.seek(toOffset: segmentStart - 8)
        try handle.write(contentsOf: Data([0x01]) + Self.bigEndian(segmentSize, width: 7))
        try handle.seek(toOffset: cuesPositionField)
        try handle.write(contentsOf: Self.bigEndian(cuesPosition, width: 8))
        try handle.close()
    }

    /// frame为待写帧，last为是否最后一帧；关键帧或相对时间码超出 Int16 时开新 Cluster，无返回值。
    private func write(_ frame: Frame, last: Bool) throws {
        let time = Self.milliseconds(frame.timestamp)
        if frame.key || clusterTime.map({ time - $0 > Int64(Int16.max) }) ?? true {
            try flushCluster()
            clusterTime = time
            // 只为以关键帧开头的 Cluster 建立索引，拖动定位到可独立解码的位置。
            if frame.key { cuePoints += cuePoint(time: time, position: try handle.offset() - segmentStart) }
        }
        let relative = UInt16(bitPattern: Int16(time - clusterTime!))
        let blockHeader = Self.vint(1) + Data([UInt8(relative >> 8), UInt8(relative & 0xFF)])
        if last {
            // 最后一帧显示到总时长；非关键帧用 ReferenceBlock 指向上一帧，避免被当作关键帧。
            var group = Self.element(ID.block, blockHeader + Data([0x00]) + frame.data) +
                Self.uint(ID.blockDuration, UInt64(durationMs - time))
            if !frame.key, let lastTime { group += Self.signed(ID.referenceBlock, lastTime - time) }
            cluster += Self.element(ID.blockGroup, group)
        } else {
            cluster += Self.element(ID.simpleBlock, blockHeader + Data([frame.key ? 0x80 : 0x00]) + frame.data)
        }
        lastTime = time
    }

    /// 无参数；写出当前 Cluster（尚无 Cluster 时不写），无返回值。
    private func flushCluster() throws {
        guard let clusterTime else { return }
        try handle.write(contentsOf: Self.element(ID.cluster, Self.uint(ID.timecode, UInt64(clusterTime)) + cluster))
        cluster = Data()
    }

    /// time为关键帧毫秒，position为 Cluster 相对 Segment 数据起点的偏移；返回一个 CuePoint 元素。
    private func cuePoint(time: Int64, position: UInt64) -> Data {
        Self.element(ID.cuePoint, Self.uint(ID.cueTime, UInt64(time)) +
            Self.element(ID.cueTrackPositions, Self.uint(ID.cueTrack, 1) + Self.uint(ID.cueClusterPosition, position)))
    }

    /// microseconds为非负微秒；返回四舍五入的毫秒（TimecodeScale 1ms）。
    static func milliseconds(_ microseconds: Int64) -> Int64 { (microseconds + 500) / 1000 }

    /// value为元素 ID；返回去掉前导零字节的 ID 字节（ID 自带长度标记）。
    private static func id(_ value: UInt32) -> Data {
        let bytes = bigEndian(UInt64(value), width: 4)
        return bytes.drop { $0 == 0 }
    }

    /// value为元素数据长度；返回最短的 EBML 可变长度整数，全 1 值保留给「未知长度」。
    private static func vint(_ value: UInt64) -> Data {
        let length = (1...8).first { value < (UInt64(1) << (7 * UInt64($0))) - 1 }!
        var bytes = bigEndian(value, width: length)
        bytes[bytes.startIndex] |= UInt8(0x80 >> (length - 1))
        return bytes
    }

    /// value为无符号数，width为字节数；返回大端字节。
    private static func bigEndian(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }

    /// id为元素 ID，payload为数据；返回 ID、长度与数据拼成的元素。
    private static func element(_ id: UInt32, _ payload: Data) -> Data { Self.id(id) + vint(UInt64(payload.count)) + payload }

    /// id为元素 ID，value为无符号整数，width为定宽字节数（nil为最短表示）；返回整数元素。
    private static func uint(_ id: UInt32, _ value: UInt64, width: Int? = nil) -> Data {
        let length = width ?? max(1, (64 - value.leadingZeroBitCount + 7) / 8)
        return element(id, bigEndian(value, width: length))
    }

    /// id为元素 ID，value为有符号整数；返回二进制补码最短表示的整数元素。
    private static func signed(_ id: UInt32, _ value: Int64) -> Data {
        var bytes = bigEndian(UInt64(bitPattern: value), width: 8)
        // 去掉不改变符号的前导 0x00/0xFF 字节。
        while bytes.count > 1, let first = bytes.first, let second = bytes.dropFirst().first,
              (first == 0x00 && second & 0x80 == 0) || (first == 0xFF && second & 0x80 != 0) {
            bytes = bytes.dropFirst()
        }
        return element(id, Data(bytes))
    }

    /// id为元素 ID，value为 UTF-8 文本；返回字符串元素。
    private static func string(_ id: UInt32, _ value: String) -> Data { element(id, Data(value.utf8)) }

    /// id为元素 ID，value为浮点数；返回 8 字节大端双精度元素。
    private static func float(_ id: UInt32, _ value: Double) -> Data { element(id, bigEndian(value.bitPattern, width: 8)) }
}
