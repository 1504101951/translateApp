import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 本地视频的有界GIF/APNG导出；按时间顺序逐帧解码，不修改源视频。
enum GIFExporter {
    /// 逐帧导出的动图格式；GIF 与 APNG 共用取样、帧数与尺寸校验，只在编码类型与帧属性上区分（#110）。
    enum Format {
        case gif, apng

        /// 无参数；返回提示文字中的格式名。
        var label: String { self == .gif ? "GIF" : "APNG" }

        /// 无参数；返回对应的录制导出类型，用于保存分类、文件扩展名与转换中详情。
        var kind: RecordingExport { self == .gif ? .gif : .apng }

        /// 无参数；返回导出成功后公开保存路径的详情键。
        var pathKey: String { self == .gif ? "gifPath" : "apngPath" }

        /// 无参数；返回 ImageIO 编码类型，APNG 的标准类型即 PNG。
        var type: UTType { self == .gif ? .gif : .png }

        /// 无参数；返回无限循环的文件级属性。
        var fileProperties: CFDictionary {
            switch self {
            case .gif: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
            case .apng: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary
            }
        }

        /// delay 为本帧显示秒数；返回帧级延时属性。
        func frameProperties(delay: Double) -> CFDictionary {
            switch self {
            case .gif:
                [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]] as CFDictionary
            case .apng:
                [kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGDelayTime: delay,
                    kCGImagePropertyAPNGUnclampedDelayTime: delay,
                ]] as CFDictionary
            }
        }
    }

    /// 完整录制的GIF设置；最大宽度以像素计，缺省保留原宽。
    struct Options {
        let framesPerSecond: Int
        let maximumWidth: Int?

        /// framesPerSecond为每秒采样数，maximumWidth为可选正整数上限；不持有逐视频草稿。
        init(framesPerSecond: Int = 10, maximumWidth: Int? = nil) {
            self.framesPerSecond = framesPerSecond
            self.maximumWidth = maximumWidth
        }

        /// duration/sourceWidth为真实元数据；返回完整视频帧数，非法配置与资源超限在编码前失败。
        func validate(duration: Double, sourceWidth: Int) throws -> Int {
            guard duration.isFinite, duration > 0, sourceWidth > 0,
                  (1...30).contains(framesPerSecond), maximumWidth.map({ $0 > 0 }) ?? true else {
                throw ExportError(message: "GIF/APNG帧率须为1–30，最大宽度须为正整数或不限制。")
            }
            // 消除十进制端点的浮点余量，完整视频不足一帧时仍输出一帧。
            let count = max(1, ceil(duration * Double(framesPerSecond) - 1e-9))
            guard count.isFinite, count <= 1800 else {
                throw ExportError(message: "GIF/APNG最多1800帧，请在截图设置中降低帧率、缩短录制时长或裁剪。")
            }
            return Int(count)
        }
    }

    /// 媒体校验或编码错误；message可直接显示给用户。
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// url为本地视频；返回有限正时长与应用视频变换后的像素尺寸，失败不创建文件。
    static func metadata(_ url: URL) async throws -> (duration: Double, width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError(message: "录制文件没有可读取的视频画面。")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = Int(abs(rect.width).rounded())
        let height = Int(abs(rect.height).rounded())
        guard width > 0, height > 0 else { throw ExportError(message: "视频尺寸无效。") }
        // 实际解码首帧，不能仅依赖容器元数据判定录制成功。
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        _ = try await generator.image(at: .zero)
        return (duration, width, height)
    }

    /// source只读；destination必须是新临时路径；options指定帧率和最大宽度；format为GIF或APNG；
    /// range为裁剪区间（nil为完整视频）；progress输出0–1进度，成功返回帧数。
    static func export(source: URL, destination: URL, options: Options, format: Format = .gif,
                       range: CMTimeRange? = nil, progress: @escaping (Double) -> Void) async throws -> Int {
        // 先解码校验与参数校验，再创建目标文件，避免非法输入留下空文件。
        let info = try await metadata(source)
        let start = range?.start.seconds ?? 0
        let duration = range?.duration.seconds ?? info.duration
        let count = try options.validate(duration: duration, sourceWidth: info.width)
        let outputWidth = min(info.width, options.maximumWidth ?? info.width)
        let outputHeight = max(1, Int((Double(info.height) * Double(outputWidth) / Double(info.width)).rounded()))
        guard outputWidth * outputHeight <= 33_554_432,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExportError(message: "\(format.label)尺寸超过33554432像素，或临时输出已存在。")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        guard let encoder = CGImageDestinationCreateWithURL(destination as CFURL, format.type.identifier as CFString, count, nil) else {
            throw ExportError(message: "无法创建\(format.label)，请检查磁盘空间与目录权限。")
        }
        CGImageDestinationSetProperties(encoder, format.fileProperties)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: outputWidth, height: outputHeight)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // 延时以百分之一秒取整（GIF 的精度，APNG 沿用）；累计边界取整防止非整除帧率累积时间漂移。
        // 取样时间从裁剪起点开始，延时只按区间内的相对时间计算。
        for index in 0..<count {
            try Task.checkCancellation()
            let offset = Double(index) / Double(options.framesPerSecond)
            let sample = try await generator.image(at: CMTime(seconds: start + offset, preferredTimescale: 60000))
            try Task.checkCancellation()
            let next = min(duration, Double(index + 1) / Double(options.framesPerSecond))
            let delay = max(0.01, (round(next * 100) - round(offset * 100)) / 100)
            CGImageDestinationAddImage(encoder, sample.image, format.frameProperties(delay: delay))
            progress(Double(index + 1) / Double(count))
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(encoder),
              let decoded = CGImageSourceCreateWithURL(destination as CFURL, nil),
              CGImageSourceGetCount(decoded) == count,
              CGImageSourceCreateImageAtIndex(decoded, count - 1, nil) != nil else {
            throw ExportError(message: "\(format.label)编码或文件校验失败，未发布结果。")
        }
        completed = true
        return count
    }

}
