import AVFoundation
import Cocoa
import CoreGraphics
import CoreVideo
import FlutterMacOS
import ImageIO
import XCTest

@testable import translate_app

/// 使用真实位图与本地编码文件验证输出；不调用屏幕权限，不控制其他应用。
final class CaptureMediaTests: XCTestCase {
    /// 无参数；没有真实冻结帧时，即使请求结构完整也必须拒绝启动，不能把任意ID当作屏幕身份。
    @MainActor
    func testCaptureToolbarRejectsMissingScreenFrame() throws {
        let controller = ScreenshotWindowController()
        controller.onPrepareCapture = { _, _, _ in }
        var response: Any?
        // 通过真实截图通道处理入口验证拒绝结果，不申请权限或创建编辑窗口。
        controller.handle(FlutterMethodCall(methodName: AppConstants.prepareCaptureMethod,
            arguments: ["id": "non-screen-image", "kind": "region", "scrolling": false])) {
            response = $0
        }
        let error = try XCTUnwrap(response as? FlutterError)
        XCTAssertEqual(error.code, AppConstants.badArgsError)
        XCTAssertNil(controller.liveCaptureID)
    }

    /// 无参数；实际绘制的选区中心必须透明，外侧像素保持截图约定的60%黑色。
    @MainActor
    func testRecordingShadeLeavesLiveSelectionTransparent() throws {
        let shade = CaptureShadeView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        shade.selection = NSRect(x: 32, y: 32, width: 64, height: 64)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 512, bitsPerPixel: 32))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(shade.bounds)
        // 取中心与远离1pt边框的外侧点，直接验证输出像素而非下游绘制调用。
        shade.draw(shade.bounds)
        let inside = try XCTUnwrap(bitmap.colorAt(x: 64, y: 64))
        let outside = try XCTUnwrap(bitmap.colorAt(x: 8, y: 8))
        XCTAssertEqual(inside.alphaComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(outside.alphaComponent, 0.6, accuracy: 1.0 / 255)
        XCTAssertEqual(outside.redComponent, 0, accuracy: 1.0 / 255)
    }

    /// 无参数；320×48无标题采集面板应完整承载内容，切换结果尺寸后仍保留有效布局。
    @MainActor
    func testCapturePanelLayoutSupportsControlAndResultModes() throws {
        let engine = FlutterEngine(name: "capture-layout-test", project: nil, allowHeadlessExecution: true)
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: AppConstants.captureControlSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close(); engine.shutDownEngine() }
        // 使用录屏和长截图共有的安装入口复现无标题窗口布局，不能只验证普通窗口。
        NativeGlassFactory.installContent(flutter, in: panel)
        // 与采集控制器的present一致，在安装内容后提交最终控制尺寸再进行布局。
        panel.setContentSize(AppConstants.captureControlSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(flutter.view.frame.width, 320, accuracy: 0.01)
        XCTAssertEqual(flutter.view.frame.height, 48, accuracy: 0.01)
        // 同一个面板切换为结果窗口；布局须随真实内容尺寸更新。
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView]
        panel.setContentSize(AppConstants.captureResultSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(flutter.view.frame.width, 560, accuracy: 0.01)
        XCTAssertGreaterThan(flutter.view.frame.height, 0)
        XCTAssertLessThanOrEqual(flutter.view.frame.height, 720)
    }

    /// width/height为像素尺寸，offset为滚动，top/bottom为固定带，repeatRows指定重复周期；返回真实位图。
    private func frame(width: Int = 96, height: Int = 192, offset: Int, top: Int = 12,
                       bottom: Int = 16, cornerOnly: Bool = false, changedHeader: Bool = false,
                       repeatRows: Int = 0) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color: [UInt8]
                if y < top { color = changedHeader ? [30, 40, 50] : [220, 230, 240] }
                else if y >= height - bottom && !cornerOnly { color = [80, 90, 100] }
                else {
                    // 非周期二维纹理提供唯一位移；颜色来自行列，输出不用相似度容差蒙混过关。
                    let row = y - top + offset
                    let contentRow = repeatRows > 0 ? row % repeatRows : row
                    let seed = UInt32(contentRow) &* 73856093 ^ UInt32(x) &* 19349663
                    color = [UInt8(truncatingIfNeeded: seed), UInt8(truncatingIfNeeded: seed >> 8), UInt8(truncatingIfNeeded: seed >> 16)]
                }
                let isButton = cornerOnly && x >= width - 16 && y >= height - 12
                let index = (y * width + x) * 4
                bytes[index] = isButton ? 255 : color[0]
                bytes[index + 1] = isButton ? 0 : color[1]
                bytes[index + 2] = isButton ? 255 : color[2]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// image为任意可解码图；返回统一RGBA行序，避免不同解码器通道布局影响断言。
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// result为PNG输出；解码后返回真实图像，空数据及坏容器都会失败。
    private func decode(_ result: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// 无参数；首尾固定带各一次，40像素位移低于164像素正文的75%上限，逐像素验证完整拼接。
    func testAutomaticTopAndBottomAreKeptExactlyOnce() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        for offset in [0, 40, 80] { try stitcher.append(frame(offset: offset)) }
        let result = try stitcher.finish()
        XCTAssertEqual(result.frames, 3)
        XCTAssertEqual(result.height, 272)
        let expected = try frame(height: 272, offset: 0)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(expected))
    }

    /// 无参数；手动底带覆盖局部角落按钮，正文连续且按钮只存在于最后一屏底带。
    func testManualBandExcludesCornerButtonWithoutInventingCoveredPixels() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 12, bottom: 24, automatic: false))
        for offset in [0, 32, 64] { try stitcher.append(frame(offset: offset, bottom: 24, cornerOnly: true)) }
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, 256)
        let expected = try frame(height: 256, offset: 0, bottom: 24, cornerOnly: true)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(expected))
    }

    /// 无参数；静止等待，反向、固定导航变化和8行周期歧义均保留最后确认像素。
    func testIdleReverseAndChangedHeaderPreserveConfirmedResult() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        XCTAssertFalse(try stitcher.append(frame(offset: 0)))
        XCTAssertFalse(try stitcher.append(frame(offset: 0)))
        XCTAssertEqual(stitcher.acceptedFrames, 1)
        XCTAssertTrue(try stitcher.append(frame(offset: 40)))
        let before = try stitcher.finish().png
        XCTAssertThrowsError(try stitcher.append(frame(offset: 20)))
        XCTAssertEqual(try stitcher.finish().png, before)
        XCTAssertThrowsError(try stitcher.append(frame(offset: 80, changedHeader: true)))
        XCTAssertEqual(try stitcher.finish().png, before)
        // 周期8行的正文可对应多个位移；即使误差为0，也不能猜测采用其中一个接缝。
        let repeating = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: false))
        try repeating.append(frame(offset: 0, top: 0, bottom: 0, repeatRows: 8))
        let unchanged = try repeating.finish().png
        XCTAssertThrowsError(try repeating.append(frame(offset: 1, top: 0, bottom: 0, repeatRows: 8)))
        XCTAssertEqual(try repeating.finish().png, unchanged)
    }

    /// 无参数；64像素正文为合法最小值，63像素、超长边及不一致尺寸均不能发布追加内容。
    func testStitchDimensionsAndEmptyResultFailClearly() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: false))
        XCTAssertThrowsError(try stitcher.finish())
        try stitcher.append(frame(width: 32, height: 64, offset: 0, top: 0, bottom: 0))
        XCTAssertEqual(try stitcher.finish().height, 64)
        let confirmed = try stitcher.finish().png
        XCTAssertThrowsError(try stitcher.append(frame(width: 32, height: 63, offset: 0, top: 0, bottom: 0)))
        XCTAssertThrowsError(try stitcher.append(frame(width: 33, height: 64, offset: 0, top: 0, bottom: 0)))
        XCTAssertEqual(try stitcher.finish().png, confirmed)
        let oversized = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: false))
        XCTAssertThrowsError(try oversized.append(frame(width: 32769, height: 64, offset: 0, top: 0, bottom: 0)))
    }

    /// url为本用例私有路径；写入30帧64×48无声H264，三段颜色用于核验时间顺序。
    private func writeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(10)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw GIFExporter.ExportError(message: "测试视频写入超时。") }
                try await Task.sleep(for: .milliseconds(10))
            }
            var optionalBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &optionalBuffer)
            XCTAssertEqual(status, kCVReturnSuccess)
            let buffer = try XCTUnwrap(optionalBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<48 { for x in 0..<64 {
                let offset = y * rowBytes + x * 4
                address[offset] = index >= 20 ? 255 : 0
                address[offset + 1] = (10..<20).contains(index) ? 255 : 0
                address[offset + 2] = index < 10 ? 255 : 0
                address[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    /// 无参数；两个1秒分段合并为2秒，跨接缝颜色顺序和源文件不变证明暂停没有占位画面。
    func testPausedRecordingSegmentsJoinWithoutTimeGap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureSegments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        // 使用真实H264输入覆盖原生合并与解码链路。
        try await writeMovie(first)
        try FileManager.default.copyItem(at: first, to: second)
        let original = try Data(contentsOf: first)
        let output = try await MediaCaptureService.joinRecordingSegments([first, second], destination: directory.appendingPathComponent("joined.mp4"))
        let info = try await GIFExporter.metadata(output)
        XCTAssertEqual(info.duration, 2, accuracy: 1.0 / 30)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var colors: [Int] = []
        for seconds in [0.1, 0.9, 1.1, 1.9] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            // 解码像素的主色顺序应在第二段重新开始，而非延长第一段结尾。
            let rgb = Array(try pixels(image).prefix(3))
            colors.append(try XCTUnwrap(rgb.indices.max(by: { rgb[$0] < rgb[$1] })))
        }
        XCTAssertEqual(colors, [0, 2, 0, 2])
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), original)
    }

    /// 无参数；非帧边界0.21–0.84秒覆盖7个10fps采样，验证尺寸、顺序、累计延时和原文件不变。
    func testGIFRealVideoHasOrderedFramesAndAccurateDuration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        try await writeMovie(video)
        let original = try Data(contentsOf: video)
        let gif = directory.appendingPathComponent("result.gif")
        let options = GIFExporter.Options(start: 0.21, end: 0.84, framesPerSecond: 10, width: 32)
        let count = try await GIFExporter.export(source: video, destination: gif, options: options) { _ in }
        XCTAssertEqual(count, 7)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 7)
        var delays = 0.0
        var colors: [Int] = []
        for index in 0..<count {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, 32)
            XCTAssertEqual(image.height, 24)
            let rgb = Array(try pixels(image).prefix(3))
            colors.append(try XCTUnwrap(rgb.indices.max(by: { rgb[$0] < rgb[$1] })))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gifProperties = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            delays += try XCTUnwrap(gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        }
        XCTAssertEqual(colors.first, 0)
        XCTAssertEqual(colors.last, 2)
        XCTAssertEqual(colors, colors.sorted())
        XCTAssertEqual(delays, 0.63, accuracy: 0.011)
        XCTAssertEqual(try Data(contentsOf: video), original)
        // 原子发布覆盖已有目标，并保持私有源文件可供继续预览或再次导出。
        let published = directory.appendingPathComponent("saved.gif")
        try Data("existing".utf8).write(to: published)
        try GIFExporter.publish(source: gif, target: published)
        XCTAssertEqual(try Data(contentsOf: published), try Data(contentsOf: gif))
    }

    /// 无参数；预先取消任务不得留下输出，空片段、越界和1801帧拒绝，1800帧边界允许。
    func testGIFCancellationAndValidationProtectSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureCancelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        try await writeMovie(video)
        let original = try Data(contentsOf: video)
        let target = directory.appendingPathComponent("cancelled.gif")
        let task = Task {
            try await GIFExporter.export(source: video, destination: target,
                options: .init(start: 0, end: 1, framesPerSecond: 30, width: 32)) { _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消任务不能成功") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: video), original)
        for options in [GIFExporter.Options(start: 0, end: 0, framesPerSecond: 10, width: 32),
                        .init(start: 0, end: 2, framesPerSecond: 10, width: 32),
                        .init(start: .nan, end: 1, framesPerSecond: 10, width: 32),
                        .init(start: 0, end: 1, framesPerSecond: 31, width: 32),
                        .init(start: 0, end: 1, framesPerSecond: 10, width: 65)] {
            XCTAssertThrowsError(try options.validate(duration: 1, sourceWidth: 64))
        }
        XCTAssertEqual(try GIFExporter.Options(start: 0, end: 60, framesPerSecond: 30, width: 32).validate(duration: 61, sourceWidth: 64), 1800)
        // 0.2到0.8秒在10fps下恰好六帧，浮点尾差不得采到结束边界外。
        XCTAssertEqual(try GIFExporter.Options(start: 0.2, end: 0.8, framesPerSecond: 10, width: 32).validate(duration: 1, sourceWidth: 64), 6)
        XCTAssertThrowsError(try GIFExporter.Options(start: 0, end: 60.01, framesPerSecond: 30, width: 32).validate(duration: 61, sourceWidth: 64))
    }
}
