import AVFoundation
import Cocoa
import CoreGraphics
import CoreImage
import CoreVideo
import CoreText
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
        // 两个重叠窗口必须构成透明并集；不能因奇偶填充让重叠区域变暗。
        shade.selection = shade.bounds
        shade.contentRects = [NSRect(x: 16, y: 16, width: 64, height: 64),
                              NSRect(x: 48, y: 48, width: 64, height: 64)]
        graphics.cgContext.clear(shade.bounds)
        shade.draw(shade.bounds)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 64, y: 64)).alphaComponent, 0, accuracy: 1.0 / 255)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 8, y: 8)).alphaComponent, 0.6, accuracy: 1.0 / 255)

    }

    /// 无参数；320×84采集面板切换到带标题栏结果窗后，同一Flutter内容须避开系统按钮且保留完整高度。
    @MainActor
    func testCapturePanelLayoutSupportsControlAndResultModes() throws {
        let engine = FlutterEngine(name: "capture-layout-test", project: nil, allowHeadlessExecution: true)
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        let panel = CaptureWindowController.makeWindow(compact: true)
        let result = CaptureWindowController.makeWindow(compact: false)
        defer { panel.close(); result.close(); engine.shutDownEngine() }
        // 使用录屏和长截图共有的安装入口复现无标题窗口布局，不能只验证普通窗口。
        NativeGlassFactory.installContent(flutter, in: panel)
        // 与采集控制器的present一致，在安装内容后提交最终控制尺寸再进行布局。
        panel.setContentSize(AppConstants.captureControlSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(flutter.view.frame.width, 320, accuracy: 0.01)
        XCTAssertEqual(flutter.view.frame.height, 84, accuracy: 0.01)
        // 检查项目材料/Flutter承载后的真实命中叶，不能让透明装饰吞掉首次鼠标。
        let hit = try XCTUnwrap(panel.contentView?.hitTest(NSPoint(x: 160, y: 42)))
        XCTAssertTrue(hit.acceptsFirstMouse(for: nil))

        // 转移真实内容到普通结果窗，标题栏占用不能落到Flutter媒体或操作区域中。
        let content = panel.contentViewController
        panel.contentViewController = nil
        result.contentViewController = content
        result.setContentSize(NSSize(width: 1280, height: 800))
        result.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(flutter.view.frame.width, 1280, accuracy: 0.01)
        XCTAssertEqual(flutter.view.frame.height, 800, accuracy: 0.01)
        XCTAssertLessThan(flutter.view.convert(flutter.view.bounds, to: nil).maxY, result.frame.height)
    }

    /// 无参数；活动采集须跨Space置顶，媒体结果须能激活且允许普通应用和系统对话框位于其上。
    @MainActor
    func testCaptureAndResultWindowsUseSeparateActivationAndLevels() {
        let controls = CaptureWindowController.makeWindow(compact: true)
        let result = CaptureWindowController.makeWindow(compact: false)
        defer { controls.close(); result.close() }
        XCTAssertEqual(controls.level, .statusBar)
        XCTAssertGreaterThan(controls.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertTrue(controls.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(controls.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(controls.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(result.level, .normal)
        XCTAssertLessThan(result.level.rawValue, NSWindow.Level.modalPanel.rawValue)
        XCTAssertFalse(result.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(result.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(result.canBecomeKey)
        // AppKit只让已显示的普通窗口成为主窗口，按用户打开结果后的真实状态验证。
        result.makeKeyAndOrderFront(nil)
        XCTAssertTrue(result.canBecomeMain)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotNil(result.standardWindowButton(button))
            XCTAssertEqual(result.standardWindowButton(button)?.isEnabled, true)
        }
    }

    /// 无参数/返回值；非key面板首个down/up须改变按钮状态，窗口焦点和应用激活态均保持不变。
    @MainActor
    func testCaptureFirstClickChangesControlWithoutStealingFocus() throws {
        let panel = CaptureWindowController.makeWindow(compact: true)
        let control = CaptureButtonEventFixture(frame: NSRect(origin: .zero, size: AppConstants.captureControlSize))
        // 真实玻璃穿透命中后，包装层沿用NSView默认首鼠标策略，复现平台视图的事件边界。
        control.addSubview(NativeGlassView(frame: control.bounds))
        panel.contentView = control
        panel.alphaValue = 0.01
        defer { panel.close() }
        // 默认面板策略在宿主激活或未激活时都会吞首击；不依赖外部应用接管测试宿主焦点。
        panel.orderFrontRegardless()
        let wasActive = NSApp.isActive
        XCTAssertFalse(panel.isKeyWindow)
        let point = NSPoint(x: 160, y: 42)
        XCTAssertTrue(panel.contentView?.hitTest(point) === control)
        XCTAssertFalse(control.acceptsFirstMouse(for: nil))
        // 只将一组事件交给本进程的真实面板，不使用全局鼠标注入或第二次激活点击。
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
        XCTAssertTrue(control.isPaused)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(NSApp.isActive, wasActive)
    }

    /// 无参数；853×434媒体占925×450内容区，系统标题栏计入窗口边界，全屏及宽/高极值均须完整容纳。
    @MainActor
    func testVideoResultBoundsDoNotCreateAnInvisibleDesktopOverlay() {
        let visible = NSRect(x: -1920, y: 24, width: 1920, height: 1056)
        let ordinary = CaptureWindowController.resultFrame(pixels: NSSize(width: 1706, height: 868), scale: 2, visible: visible)
        let content = NSWindow.contentRect(forFrameRect: ordinary, styleMask: AppConstants.captureResultWindowStyle)
        XCTAssertEqual(content.size, NSSize(width: 925, height: 450))
        XCTAssertGreaterThan(ordinary.height, content.height)
        XCTAssertFalse(ordinary.contains(NSPoint(x: visible.minX + 1, y: visible.minY + 1)))
        for pixels in [NSSize(width: 72, height: 48), NSSize(width: 20000, height: 1000),
                       NSSize(width: 720, height: 4800), NSSize(width: 3840, height: 2160)] {
            let frame = CaptureWindowController.resultFrame(pixels: pixels, scale: 2, visible: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertGreaterThanOrEqual(frame.width, 73)
            XCTAssertGreaterThan(frame.height, 196)
        }
    }

    /// 无参数/返回值；点击真实红按钮一次即结束会话，不进入会阻塞结果窗口的确认循环。
    @MainActor
    func testVideoResultSystemCloseImmediatelyEndsSession() async throws {
        let controller = CaptureWindowController(screenshot: ScreenshotWindowController())
        let result = CaptureWindowController.makeWindow(compact: false)
        result.delegate = controller
        result.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        defer { result.delegate = nil; result.close() }
        let token = controller.service.id
        let ended = expectation(description: "单击关闭完成资源清理")
        controller.onActiveChanged = { active in
            if !active && controller.service.id != token { ended.fulfill() }
        }
        result.makeKeyAndOrderFront(nil)
        // 系统关闭入口走完整的异步资源状态转换，检查最终身份与阶段而不是下游调用。
        try XCTUnwrap(result.standardWindowButton(.closeButton)).performClick(nil)
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertNotEqual(controller.service.id, token)
        XCTAssertEqual(controller.service.phase, .idle)
        XCTAssertNil(NSApp.modalWindow)
        controller.onActiveChanged = nil
    }

    /// 无参数；负坐标副屏和上/下排列都以可用区右下角定位，保留8pt边距和全部提示空间。
    @MainActor
    func testCaptureControlsAnchorToVisibleBottomRight() {
        for visible in [NSRect(x: -1920, y: 24, width: 1920, height: 1056),
                        NSRect(x: 1440, y: -900, width: 1440, height: 876)] {
            let origin = CaptureWindowController.controlOrigin(visible: visible, size: AppConstants.captureControlSize)
            let frame = NSRect(origin: origin, size: AppConstants.captureControlSize)
            XCTAssertEqual(frame.maxX, visible.maxX - 8)
            XCTAssertEqual(frame.minY, visible.minY + 8)
            XCTAssertTrue(visible.contains(frame))
        }
    }

    /// 无参数；真实矢量图标栅格化为16pt@2x PNG；缺失图标是可展示的空资产，不是来源列表错误。
    @MainActor
    func testApplicationIconRendersVectorAndHandlesMissingAsset() throws {
        let vector = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(MediaCaptureService.applicationIconPNG(vector))
        let image = try decode(png)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 32)
        XCTAssertGreaterThan(try pixels(image)[(16 * 32 + 16) * 4], 250)
        XCTAssertNil(MediaCaptureService.applicationIconPNG(nil))
    }

    /// 无参数；负坐标、显示器间空隙及1x/2x混合倍率必须保留桌面位置，黑色填充其余画布。
    func testApplicationCanvasKeepsMixedScaleDisplaysAndBlackGaps() throws {
        let canvas = try ApplicationCaptureCanvas(displays: [
            .init(id: 1, frame: CGRect(x: -64, y: -32, width: 64, height: 48), scale: 1),
            .init(id: 2, frame: CGRect(x: 0, y: 0, width: 64, height: 48), scale: 2),
        ])
        XCTAssertEqual(canvas.size, CGSize(width: 256, height: 160))
        let frames: [CGDirectDisplayID: CIImage] = [
            1: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)),
            2: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 96)),
        ]
        // composite输出真实CI像素，通过统一RGBA读取核对每个像素，不断言绘制调用。
        let image = try XCTUnwrap(CIContext().createCGImage(canvas.composite(frames), from: CGRect(origin: .zero, size: canvas.size)))
        let bytes = try pixels(image)
        for y in 0..<160 {
            for x in 0..<256 {
                let expected: [UInt8] = x < 128 && y < 96 ? [255, 0, 0, 255] :
                    (x >= 128 && y >= 64 ? [0, 0, 255, 255] : [0, 0, 0, 255])
                XCTAssertEqual(Array(bytes[(y * 256 + x) * 4..<(y * 256 + x + 1) * 4]), expected)
            }
        }
        // 奇数尺寸向外补黑边，不裁掉最后一列/行；相同尺寸的拓扑移动也不能视为同一画布。
        let odd = try ApplicationCaptureCanvas(displays: [.init(id: 1,
            frame: CGRect(x: 0, y: 0, width: 65, height: 65), scale: 1)])
        XCTAssertEqual(odd.size, CGSize(width: 66, height: 66))
        XCTAssertThrowsError(try ApplicationCaptureCanvas(displays: []))
    }

    /// 无参数；两路合成实际编码H264并解码，验证尺寸、黑底及左右来源均进入同一MP4。
    func testApplicationEncoderProducesDecodableCompositeVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("application.mp4")
        let canvas = try ApplicationCaptureCanvas(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1),
            .init(id: 2, frame: CGRect(x: 128, y: 0, width: 64, height: 64), scale: 1),
        ])
        let encoder = try ApplicationVideoEncoder(canvas: canvas, url: url) { error in
            XCTFail(error.localizedDescription)
        }
        encoder.queue.async {
            // 两屏输入使用实际CI图像，进入与ScreenCaptureKit相同的帧接收/编码入口。
            encoder.receive(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), display: 1)
            encoder.receive(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), display: 2)
        }
        try await encoder.waitUntilReady()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await encoder.finish(discard: false)
        let info = try await GIFExporter.metadata(url)
        XCTAssertEqual(info.width, 192)
        XCTAssertEqual(info.height, 64)
        XCTAssertGreaterThan(info.duration, 0)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let result = try await generator.image(at: .zero)
        let bytes = try pixels(result.image)
        // 距接缝32像素的中心色允许5级有损误差，同时检查非主色通道及显示器间黑色空隙。
        for (x, expected) in [(32, [255, 0, 0]), (96, [0, 0, 0]), (160, [0, 0, 255])] {
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[(32 * 192 + x) * 4 + channel]) - expected[channel]), 5)
            }
        }
    }

    /// 无参数；放弃先于首帧等待入队时必须返回取消，不能留下无法完成的启动任务。
    func testDiscardBeforeFirstFrameCancelsReadiness() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let canvas = try ApplicationCaptureCanvas(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1),
        ])
        let encoder = try ApplicationVideoEncoder(canvas: canvas, url: folder.appendingPathComponent("cancel.mp4")) { error in
            XCTFail(error.localizedDescription)
        }
        // finish模拟真实放弃先完成的状态；waitUntilReady必须观察已结束的编码器身份。
        try await encoder.finish(discard: true)
        do {
            try await encoder.waitUntilReady()
            XCTFail("已放弃的录制不能继续等待或进入可录制状态。")
        } catch is CancellationError {
            // 取消为预期业务结果，不要求调用方等待首帧超时。
        }
    }

    /// width/height为像素尺寸，offset为滚动，top/bottom为固定带，repeatRows指定重复周期、blankRows指定正文空白行范围；返回真实位图。
    private func frame(width: Int = 96, height: Int = 192, offset: Int, top: Int = 12,
                       bottom: Int = 16, cornerOnly: Bool = false, changedHeader: Bool = false,
                       repeatRows: Int = 0, blankRows: [Range<Int>] = []) throws -> CGImage {
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
                    color = blankRows.contains(where: { $0.contains(contentRow) }) ? [255, 255, 255] :
                        [UInt8(truncatingIfNeeded: seed), UInt8(truncatingIfNeeded: seed >> 8), UInt8(truncatingIfNeeded: seed >> 16)]
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

    /// 无参数；没有帧时只失败，已有首帧时停止原因仍进入可保存结果；过期会话不能覆盖当前图。
    @MainActor
    func testScrollFailureKeepsConfirmedImageAndEmptyCaptureFails() throws {
        let empty = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: false))
        XCTAssertThrowsError(try empty.confirmedFrame())
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: false))
        let source = try frame(offset: 0)
        try stitcher.append(source)
        let confirmed = try stitcher.confirmedFrame()
        XCTAssertEqual(confirmed.frames, 1)
        XCTAssertEqual(confirmed.width, source.width)
        XCTAssertEqual(confirmed.height, source.height)
        let failed = MediaCaptureService()
        failed.publishFinishedScroll(png: nil, width: 0, height: 0, frames: 0, failure: "还没有捕获到图像。", token: failed.id)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertNil(failed.snapshot()["imageBytes"])
        XCTAssertEqual(failed.snapshot()["error"] as? String, "还没有捕获到图像。")
        let ready = MediaCaptureService()
        let reason = "相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。"
        ready.publishFinishedScroll(png: confirmed.png, width: confirmed.width, height: confirmed.height,
            frames: confirmed.frames, failure: reason, token: ready.id)
        XCTAssertEqual(ready.phase, .imageReady)
        XCTAssertEqual((ready.snapshot()["imageBytes"] as? FlutterStandardTypedData)?.data, confirmed.png)
        XCTAssertEqual(ready.snapshot()["warning"] as? String, reason)
        ready.publishFinishedScroll(png: confirmed.png, width: 1, height: 1, frames: 9, failure: nil, token: "stale")
        XCTAssertEqual(ready.snapshot()["width"] as? Int, confirmed.width)
        XCTAssertEqual(ready.phase, .imageReady)
    }

    /// 无参数；保存后重复放弃只清空当前结果，已保存文件和下一份会话不受旧交付影响。
    @MainActor
    func testSavedScrollSurvivesRepeatedDiscardAndRejectsOldDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScrollOwnership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: false))
        // 一张确认帧是可保留结果的最小边界，不申请屏幕权限或依赖实际滚动。
        try stitcher.append(frame(offset: 0))
        let image = try stitcher.finish()
        let service = MediaCaptureService()
        let previousID = service.id
        service.publishFinishedScroll(png: image.png, width: image.width, height: image.height,
            frames: image.frames, failure: nil, token: previousID)
        // save写入真实独立目录，noteSavedScroll只公开已经成功写入的路径。
        let saved = try ScreenshotStorage.save(image.png, directory: directory, name: "长截图.png")
        service.noteSavedScroll(saved.path)
        await service.cancel()
        await service.cancel()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertFalse(service.isBusy)
        XCTAssertNil(service.snapshot()["imageBytes"])
        XCTAssertEqual(try Data(contentsOf: saved), image.png)

        // 同一服务复用新会话身份，前一次采集的迟到交付不能覆盖新结果或回填保存路径。
        let currentID = service.id
        XCTAssertNotEqual(currentID, previousID)
        service.publishFinishedScroll(png: image.png, width: image.width, height: image.height,
            frames: image.frames, failure: nil, token: currentID)
        service.publishFinishedScroll(png: image.png, width: 1, height: 1, frames: 99,
            failure: "旧会话", token: previousID)
        XCTAssertEqual(service.phase, .imageReady)
        XCTAssertEqual(service.snapshot()["width"] as? Int, image.width)
        XCTAssertEqual(service.snapshot()["frames"] as? Int, image.frames)
        XCTAssertNil(service.snapshot()["warning"])
        XCTAssertNil(service.snapshot()["savedPath"])
        await service.cancel()
        XCTAssertEqual(try Data(contentsOf: saved), image.png)
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

    /// 无参数；正文空白跨过首帧对边缘，第三帧文字进入边缘仍应连续；40小于可靠重叠上限。
    func testScrollingBlankParagraphEdgesAreNotFixedBars() throws {
        let blanks = [0..<70, 150..<240]
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        // 三帧覆盖空白重合与退出空白两个边界，不以调用次数代替输出像素验证。
        for offset in [0, 40, 80] {
            try stitcher.append(frame(offset: offset, top: 0, bottom: 0, blankRows: blanks))
        }
        let result = try stitcher.finish()
        let expected = try frame(height: 272, offset: 0, top: 0, bottom: 0, blankRows: blanks)
        XCTAssertEqual(result.frames, 3)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(expected))
    }

    /// 无参数；真实12/16像素固定栏旁的正文空白不能被并入固定栏，固定栏仍仅保留一次。
    func testFixedBarsBesideScrollingBlankParagraphsAreKeptOnce() throws {
        let blanks = [0..<70, 140..<220]
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        for offset in [0, 40, 80] {
            try stitcher.append(frame(offset: offset, blankRows: blanks))
        }
        let result = try stitcher.finish()
        let expected = try frame(height: 272, offset: 0, blankRows: blanks)
        XCTAssertEqual(result.frames, 3)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(expected))
    }

    /// 无参数；16×12角落按钮只遮住局部正文，自动模式须按真实位移去重且不误判其余正文变化。
    func testAutomaticBandExcludesCornerButtonWithoutDuplicatingIt() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        for offset in [0, 32, 64] {
            try stitcher.append(frame(offset: offset, bottom: 24, cornerOnly: true))
        }
        let result = try stitcher.finish()
        let expected = try frame(height: 256, offset: 0, bottom: 24, cornerOnly: true)
        XCTAssertEqual(result.frames, 3)
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

    /// 无参数；静止等待、反向和8行周期歧义保留确认像素，固定导航变色仍按正文位移追加。
    func testIdleReverseAndDynamicHeaderPreserveConfirmedResult() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        XCTAssertFalse(try stitcher.append(frame(offset: 0)))
        XCTAssertFalse(try stitcher.append(frame(offset: 0)))
        XCTAssertEqual(stitcher.acceptedFrames, 1)
        XCTAssertTrue(try stitcher.append(frame(offset: 40)))
        let before = try stitcher.finish().png
        XCTAssertThrowsError(try stitcher.append(frame(offset: 20)))
        XCTAssertEqual(try stitcher.finish().png, before)
        // 顶部固定内容变色不破坏正文接缝；输出保留首帧顶部并追加80像素正文。
        XCTAssertTrue(try stitcher.append(frame(offset: 80, changedHeader: true)))
        XCTAssertEqual(try pixels(decode(stitcher.finish().png)), try pixels(frame(height: 272, offset: 0)))
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

    /// 无参数；全长1秒视频以10fps导出10帧，验证等比缩小、顺序、累计延时和原文件不变。
    func testGIFRealVideoHasOrderedFramesAndAccurateDuration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        try await writeMovie(video)
        let original = try Data(contentsOf: video)
        let gif = directory.appendingPathComponent("result.gif")
        let options = GIFExporter.Options(framesPerSecond: 10, maximumWidth: 32)
        let count = try await GIFExporter.export(source: video, destination: gif, options: options) { _ in }
        XCTAssertEqual(count, 10)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
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
        XCTAssertEqual(delays, 1.0, accuracy: 0.011)
        XCTAssertEqual(try Data(contentsOf: video), original)
        // 未限制或限制大于源宽都不放大；尺寸必须由实际媒体元数据决定。
        for maximum in [nil, 1000] as [Int?] {
            let output = directory.appendingPathComponent("original-\(maximum ?? 0).gif")
            _ = try await GIFExporter.export(source: video, destination: output,
                options: .init(framesPerSecond: 10, maximumWidth: maximum)) { _ in }
            let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 48)
        }
    }

    /// 无参数；预先取消不留下输出；无效元数据/设置与1801帧拒绝，1800帧边界允许。
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
                options: .init(framesPerSecond: 30, maximumWidth: 32)) { _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消任务不能成功") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: video), original)
        for options in [GIFExporter.Options(framesPerSecond: 0), .init(framesPerSecond: 31),
                        .init(maximumWidth: 0), .init(maximumWidth: -1)] {
            XCTAssertThrowsError(try options.validate(duration: 1, sourceWidth: 64))
        }
        for duration in [0.0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try GIFExporter.Options().validate(duration: duration, sourceWidth: 64))
        }
        XCTAssertEqual(try GIFExporter.Options(framesPerSecond: 30).validate(duration: 60, sourceWidth: 64), 1800)
        // 0.6秒在10fps下恰好六帧，浮点尾差不能生成超过结束时间的帧。
        XCTAssertEqual(try GIFExporter.Options().validate(duration: 0.6, sourceWidth: 64), 6)
        XCTAssertThrowsError(try GIFExporter.Options(framesPerSecond: 30).validate(duration: 60.01, sourceWidth: 64))
    }
    /// 无参数；唯一中文正文以8.5像素平滑滚动，整数和四分像素起点均应输出完整宽度与34像素增量。
    func testSmoothTextScrollingPreservesOverlapAndPixels() throws {
        let document = try textDocument()
        for initial in [0.0, 0.25] {
            let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
            for step in 0...4 { try stitcher.append(textViewport(document, offset: initial + Double(step) * 8.5)) }
            let result = try stitcher.finish()
            XCTAssertEqual(result.width, document.width)
            XCTAssertEqual(result.height, 834)
            XCTAssertEqual(result.frames, 5)
            // 整数条带保留原像素；仅接缝相位最多半像素差，平均RGB误差限3/255，高误差像素限5%。
            let expected = try pixels(textViewport(document, offset: initial, height: result.height))
            let actual = try pixels(decode(result.png))
            var total = 0.0
            var affected = 0
            for index in stride(from: 0, to: actual.count, by: 4) {
                let differences = (0..<3).map { abs(Int(actual[index + $0]) - Int(expected[index + $0])) }
                total += Double(differences.reduce(0, +))
                if differences.max()! > 16 { affected += 1 }
            }
            XCTAssertLessThanOrEqual(total / Double(result.width * result.height * 3), 3)
            XCTAssertLessThanOrEqual(Double(affected) / Double(result.width * result.height), 0.05)
        }
        // 视觉完全重复的段落存在多个同样可靠的接缝，不能通过亚像素容错猜测位移。
        let repeated = try textDocument(repeated: true)
        let ambiguous = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        try ambiguous.append(textViewport(repeated, offset: 0))
        let confirmed = try ambiguous.finish().png
        XCTAssertThrowsError(try ambiguous.append(textViewport(repeated, offset: 8)))
        XCTAssertEqual(try ambiguous.finish().png, confirmed)
    }

    /// repeated决定唯一编号或完全重复的中文行；返回900×1600的真实CoreText栅格图，不依赖桌面内容。
    private func textDocument(repeated: Bool = false) throws -> CGImage {
        let width = 900
        let height = 1600
        var text = ""
        for index in 0..<90 {
            let row = repeated ? 1 : index + 1
            let marker = repeated ? 1 : index * 37
            text += String(format: "项目%04d：列表项目需要清晰的信息结构、稳定的文字间距和一致的阅读节奏。核验序号%04d记录。\n", row, marker)
            if index % 4 == 3 { text += "\n\n" }
        }
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 15, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 28, y: 20, width: width - 56, height: height - 40), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        return try XCTUnwrap(context.makeImage())
    }

    /// document为CoreText原图，offset为分数像素滚动，height为视口高度；返回线性栅格化的同宽新帧。
    private func textViewport(_ document: CGImage, offset: Double, height: Int = 800) throws -> CGImage {
        let source = try pixels(document)
        let width = document.width
        let base = Int(offset.rounded(.down))
        let fraction = offset - Double(base)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width * 4) {
                let first = (base + y) * width * 4 + x
                bytes[y * width * 4 + x] = UInt8((Double(source[first]) * (1 - fraction)
                    + Double(source[first + width * 4]) * fraction).rounded())
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// 无参数；600像素/秒滚动时4fps跨150像素越过123像素上限，10fps的60像素步进须生成连续原图。
    func testDenserScrollFramesPreserveFastMovingContentWithoutWeakeningOverlap() throws {
        let sparse = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        // frame生成顶部12、底部16固定像素，正文164像素至少保留41像素重叠。
        try sparse.append(frame(offset: 0))
        let confirmed = try sparse.finish().png
        XCTAssertThrowsError(try sparse.append(frame(offset: 150)))
        XCTAssertEqual(try sparse.finish().png, confirmed)

        let dense = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        for offset in stride(from: 0, through: 180, by: 60) {
            try dense.append(frame(offset: offset))
        }
        // 同一移动正文增加180像素；decode/pixels检查接缝内容，不只检查最终尺寸。
        let result = try dense.finish()
        XCTAssertEqual(result.height, 372)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(frame(height: 372, offset: 0)))
    }

    /// 无参数；6×6徽标RGB变化10但正文唯一匹配40像素位移，输出首顶末底的完整272像素长图。
    func testAutomaticStitchAcceptsChangingFixedPixelsWhenBodyMatches() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        try stitcher.append(animatedFrame(offset: 0))
        try stitcher.append(animatedFrame(offset: 40))
        let accepted: Bool
        do {
            accepted = try stitcher.append(animatedFrame(offset: 80, headerVariant: true, footerVariant: true))
        } catch {
            XCTFail("Body-matchable frame was rejected: \(error.localizedDescription)")
            return
        }
        XCTAssertTrue(accepted)

        let result = try stitcher.finish()
        let expected = try animatedFrame(width: 96, height: 272, offset: 0, footerVariant: true)
        XCTAssertEqual(result.width, 96)
        XCTAssertEqual(result.height, 272)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(expected))
    }

    /// 无参数；正文重排导致不可匹配时停止，输出保持为上一张已确认PNG。
    func testUnreliableBodyMatchStillStopsAfterConfirmedFrames() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        try stitcher.append(animatedFrame(offset: 0))
        try stitcher.append(animatedFrame(offset: 40))
        let confirmed = try stitcher.finish().png

        XCTAssertThrowsError(try stitcher.append(animatedFrame(offset: 80, bodyRevision: 0x5a5a5a5a)))
        XCTAssertEqual(try stitcher.finish().png, confirmed)
    }

    /// 无参数；手动12/16像素边界遵守首顶末底，固定栏动态像素不能进入正文条带。
    func testFinishUsesFirstTopAndLastBottomWithChangingBars() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 12, bottom: 16, automatic: false))
        try stitcher.append(animatedFrame(offset: 0))
        try stitcher.append(animatedFrame(offset: 40))
        try stitcher.append(animatedFrame(offset: 80, headerVariant: true, footerVariant: true))

        let result = try stitcher.finish()
        let expected = try animatedFrame(width: 96, height: 272, offset: 0, footerVariant: true)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(expected))
    }

    /// width/height为像素尺寸，offset为正文位移，variant改变6×6固定徽标，bodyRevision重排正文；返回RGBA图。
    private func animatedFrame(
        width: Int = 96,
        height: Int = 192,
        offset: Int,
        headerVariant: Bool = false,
        footerVariant: Bool = false,
        bodyRevision: UInt32 = 0
    ) throws -> CGImage {
        let top = 12
        let bottom = 16
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let color: [UInt8]
                if y < top {
                    let badge = headerVariant && (3..<9).contains(y) && (44..<50).contains(x)
                    color = badge ? [210, 220, 230] : [220, 230, 240]
                } else if y >= height - bottom {
                    let badge = footerVariant && (height - 12..<height - 6).contains(y) && (44..<50).contains(x)
                    color = badge ? [70, 80, 90] : [80, 90, 100]
                } else {
                    let contentRow = y - top + offset
                    let seed = UInt32(contentRow) &* 73856093 ^ UInt32(x) &* 19349663 ^ bodyRevision
                    color = [
                        UInt8(truncatingIfNeeded: seed),
                        UInt8(truncatingIfNeeded: seed >> 8),
                        UInt8(truncatingIfNeeded: seed >> 16),
                    ]
                }
                let index = (y * width + x) * 4
                rgba[index] = color[0]
                rgba[index + 1] = color[1]
                rgba[index + 2] = color[2]
            }
        }

        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }


}

/// 模拟平台视图命中层上的暂停按钮状态；由实际AppKit鼠标序列驱动，不覆盖首鼠标接受策略。
private final class CaptureButtonEventFixture: NSView {
    private var pressed = false
    private(set) var isPaused = false

    /// event为面板送达的按下事件；开始一次按钮手势，无返回值。
    override func mouseDown(with event: NSEvent) { pressed = true }

    /// event为同一按钮的松开事件；完整按下/松开才切换暂停状态，无返回值。
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        isPaused.toggle()
    }
}
