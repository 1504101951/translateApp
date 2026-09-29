import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 本地视频的有界GIF导出；按时间顺序逐帧解码，不修改源视频。
enum GIFExporter {
    /// 从录屏中选择的时间范围和尺寸；宽度以输出像素计，纵横比保持不变。
    struct Options {
        let start: Double
        let end: Double
        let framesPerSecond: Int
        let width: Int

        /// duration/sourceWidth为解码后的视频元数据；返回计划帧数，非法参数直接抛错。
        func validate(duration: Double, sourceWidth: Int) throws -> Int {
            guard duration.isFinite, start.isFinite, end.isFinite,
                  start >= 0, end > start, end <= duration,
                  (1...30).contains(framesPerSecond), width > 0, width <= sourceWidth else {
                throw ExportError(message: "GIF参数无效：起止须位于视频内且结束大于开始，帧率1–30，宽度不得超过原视频。")
            }
            // 消除十进制端点的浮点余量，不追加位于结束时间上的额外帧。
            let count = max(1, ceil((end - start) * Double(framesPerSecond) - 1e-9))
            guard count >= 1, count <= 1800 else {
                throw ExportError(message: "GIF最多1800帧，请缩短片段或降低帧率。")
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

    /// source只读；destination必须是新临时路径；options指定片段；progress输出0–1进度，成功返回帧数。
    static func export(source: URL, destination: URL, options: Options,
                       progress: @escaping (Double) -> Void) async throws -> Int {
        // 先解码校验与参数校验，再创建GIF目标，避免非法输入留下空文件。
        let info = try await metadata(source)
        let count = try options.validate(duration: info.duration, sourceWidth: info.width)
        let outputHeight = max(1, Int((Double(info.height) * Double(options.width) / Double(info.width)).rounded()))
        guard options.width * outputHeight <= 33_554_432,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExportError(message: "GIF尺寸超过33554432像素，或临时输出已存在。")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        guard let encoder = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ExportError(message: "无法创建GIF，请检查磁盘空间与目录权限。")
        }
        CGImageDestinationSetProperties(encoder, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.width, height: outputHeight)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // GIF以百分之一秒表示延时；累计边界取整防止非整除帧率累积时间漂移。
        for index in 0..<count {
            try Task.checkCancellation()
            let offset = Double(index) / Double(options.framesPerSecond)
            let sample = try await generator.image(at: CMTime(seconds: options.start + offset, preferredTimescale: 60000))
            try Task.checkCancellation()
            let next = min(options.end - options.start, Double(index + 1) / Double(options.framesPerSecond))
            let delay = max(0.01, (round(next * 100) - round(offset * 100)) / 100)
            CGImageDestinationAddImage(encoder, sample.image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]] as CFDictionary)
            progress(Double(index + 1) / Double(count))
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(encoder),
              let decoded = CGImageSourceCreateWithURL(destination as CFURL, nil),
              CGImageSourceGetCount(decoded) == count,
              CGImageSourceCreateImageAtIndex(decoded, count - 1, nil) != nil else {
            throw ExportError(message: "GIF编码或文件校验失败，未发布结果。")
        }
        completed = true
        return count
    }

    /// source为已校验的临时文件，target为系统面板确认的目标；以同目录暂存文件原子发布，无返回值。
    static func publish(source: URL, target: URL) throws {
        guard source.standardizedFileURL != target.standardizedFileURL else { return }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".TranslateApp-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}
