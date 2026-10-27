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
    /// 旧识别尚未结束时只保留新代次的最新帧，结束后才开始下一次。
    func testLiveOcrSlotKeepsOnePendingFrameForTheCurrentGeneration() {
        var slot = LiveOcrSlot()
        slot.adopt(1)
        XCTAssertTrue(slot.offer(generation: 1))
        XCTAssertFalse(slot.offer(generation: 1))
        XCTAssertTrue(slot.finish())
        XCTAssertFalse(slot.finish())
        XCTAssertTrue(slot.offer(generation: 1))
        slot.adopt(2)
        XCTAssertFalse(slot.offer(generation: 1))
        XCTAssertFalse(slot.offer(generation: 2))
        XCTAssertTrue(slot.finish())
        slot.adopt(3)
        XCTAssertFalse(slot.finish())
        XCTAssertTrue(slot.offer(generation: 3))
    }

    /// 无参数；截图存储按类型与本地日期分类，重名只新增序号文件，已有文件、已取消的发布与越界路径都不改写任何内容（#124）。
    /// 边界：同一日期五种输出进入不同分类，APNG 扩展名为 png 但不进截图分类；根路径被文件占用、名称越出目录与目录已删除都必须报错。
    func testScreenshotStorageClassifiesByDateAndKeepsExistingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 日期用公历构造，不受用户的日历区域设置影响。
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        let kinds: [(ScreenshotStorage.Category, String, String)] = [
            (.screenshot, "截图", "png"), (ScreenshotStorage.Category(.mp4), "视频", "mp4"), (ScreenshotStorage.Category(.gif), "gif", "gif"),
            (ScreenshotStorage.Category(.apng), "apng", "png"), (ScreenshotStorage.Category(.webm), "webm", "webm"),
        ]
        for (kind, category, ext) in kinds {
            let folder = try ScreenshotStorage.datedDirectory(basePath: directory.path, category: kind, date: date)
            XCTAssertEqual(folder.path, directory.appendingPathComponent("\(category)/2026-10-01").path)
            let target = folder.appendingPathComponent("采集.\(ext)")
            let source = directory.appendingPathComponent("source.\(ext)")
            try Data([1, 2, 3]).write(to: source)
            try Data([9]).write(to: target)
            // 同名媒体只新增序号文件；临时源与已保存内容均保持不变，不留暂存文件。
            let output = try ScreenshotStorage.publish(source: source, target: target)
            XCTAssertEqual(output.lastPathComponent, "采集-2.\(ext)")
            XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3]))
            XCTAssertEqual(try Data(contentsOf: target), Data([9]))
            XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".partial") })
        }
        // 根路径被真实文件占用时必须失败，不能报告保存成功或污染该文件。
        let blockedRoot = directory.appendingPathComponent("blocked")
        try Data([7]).write(to: blockedRoot)
        XCTAssertThrowsError(try ScreenshotStorage.datedDirectory(basePath: blockedRoot.path, category: .screenshot, date: date))
        XCTAssertEqual(try Data(contentsOf: blockedRoot), Data([7]))
        // 同一毫秒内或重复保存同一截图是重名边界，已有文件的字节必须完全保留。
        let first = try ScreenshotStorage.save(Data([1, 2, 3]), directory: directory, name: "截图.png")
        let second = try ScreenshotStorage.save(Data([4, 5, 6]), directory: directory, name: "截图.png")
        let third = try ScreenshotStorage.save(Data([7]), directory: directory, name: "截图.png")
        XCTAssertEqual([second.lastPathComponent, third.lastPathComponent], ["截图-2.png", "截图-3.png"])
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second), Data([4, 5, 6]))
        // 取消是真实任务状态；发布不得创建目标，也不能删除仍可预览的来源或遗留暂存文件。
        let cancelledTarget = directory.appendingPathComponent("cancelled.gif")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScreenshotStorage.publish(source: first, target: cancelledTarget)
        }
        do {
            _ = try await cancelled.value
            XCTFail("已取消的导出不能发布")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledTarget.path))
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".partial") })
        // 名称越出所选目录、所选目录已删除都必须报错。
        XCTAssertThrowsError(try ScreenshotStorage.save(Data([8]), directory: directory, name: "../outside.png"))
        XCTAssertThrowsError(try ScreenshotStorage.save(Data([8]), directory: directory.appendingPathComponent("removed"), name: "截图.png"))
    }

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

    /// 无参数；长截图过程提示依次尝试选区上、下、左、右并离选区8pt，避开面板与缩略图，都放不下才居中且不超过选区宽减16pt；1000ms后移除。
    @MainActor
    func testScrollHintAvoidsSelectionThenFallsBackToCenterAndExpires() async throws {
        let shade = CaptureShadeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        shade.selection = NSRect(x: 100, y: 80, width: 400, height: 300)
        let text = "请往回滚，直到右下角红框里的内容回到选区"
        shade.showHint(text, isError: true)
        let above = try XCTUnwrap(shade.hintView).frame
        XCTAssertEqual(above.minY, shade.selection.maxY + 8)
        XCTAssertEqual(above.midX, shade.selection.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(above.width, 240)
        XCTAssertEqual(try XCTUnwrap(shade.hintView).cornerRadius, 8)
        // 上方被缩略图占用时改到下方。
        shade.showHint(text, isError: true, avoiding: [NSRect(x: 0, y: 380, width: 800, height: 220)])
        let below = try XCTUnwrap(shade.hintView).frame
        XCTAssertEqual(below.maxY, shade.selection.minY - 8)
        XCTAssertEqual(shade.subviews.count, 1)
        // 选区占满可用区时四个方向都放不下，提示居中且宽度不超过选区宽减16pt。
        shade.selection = NSRect(x: 0, y: 0, width: 120, height: 600)
        shade.showHint(text, isError: false, visible: shade.selection)
        let center = try XCTUnwrap(shade.hintView).frame
        XCTAssertLessThanOrEqual(center.width, 104)
        XCTAssertEqual(center.midX, shade.selection.midX, accuracy: 1)
        XCTAssertEqual(center.midY, shade.selection.midY, accuracy: 1)
        XCTAssertTrue(shade.selection.contains(center))
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertNil(shade.hintView)
        XCTAssertTrue(shade.subviews.isEmpty)
    }

    /// 无参数；缩略图取已确认长图底部并等比缩小、不放大，回退目标框标出参照帧正文底部41像素重叠段；面板上方8pt右对齐。
    @MainActor
    func testScrollPreviewShowsLongImageTailAndTarget() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        for offset in [0, 40, 80] { try stitcher.append(frame(offset: offset)) }
        // 272像素长图按0.5缩小，最大高60只显示底部120像素。
        let preview = try XCTUnwrap(stitcher.preview(width: 48, maxHeight: 60, markTarget: true))
        XCTAssertEqual(preview.image.width, 48)
        XCTAssertEqual(preview.image.height, 60)
        let target = try XCTUnwrap(preview.target)
        // 底栏16、重叠41：目标距底(16+41)×0.5=28.5，高20.5。
        XCTAssertEqual(target.minY, 31.5, accuracy: 0.01)
        XCTAssertEqual(target.height, 20.5, accuracy: 0.01)
        XCTAssertNil(try XCTUnwrap(stitcher.preview(width: 48, maxHeight: 60, markTarget: false)).target)
        // 缩略图比原图宽时不放大，按原宽显示整张较矮长图。
        let full = try XCTUnwrap(stitcher.preview(width: 200, maxHeight: 400, markTarget: false))
        XCTAssertEqual(full.image.width, 96)
        XCTAssertEqual(full.image.height, 272)
        XCTAssertEqual(try pixels(full.image), try pixels(decode(stitcher.finish().png)))

        let view = ScrollPreviewView()
        let size = view.update(preview, scale: 2)
        XCTAssertEqual(size, NSSize(width: 32, height: 38))
        XCTAssertFalse(view.targetView.isHidden)
        XCTAssertEqual(view.targetView.frame.minY, 4 + 30 - 52 / 2, accuracy: 0.01)
        let control = NSRect(x: 1112, y: 8, width: 320, height: 84)
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(CaptureWindowController.scrollPreviewFrame(size: NSSize(width: 160, height: 248), control: control,
                                                                  visible: visible),
                       NSRect(x: 1272, y: 100, width: 160, height: 248))
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
            // 内容至少容纳六个操作的268pt工具栏与上下8pt外边距，再加系统标题栏（#110）。
            XCTAssertGreaterThan(frame.height, 284)
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

    /// 无参数/返回值；真实编码器的快速结束、红蓝变化及150ms队列延迟均能导出可解码GIF/APNG。
    /// 边界：首帧PTS为零、轨道600刻度且严格递增；1/10/30fps覆盖最低、默认与最高采样率，32px验证缩小。
    func testApplicationEncoderExportsReadableAnimationsAcrossTimingBoundaries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationMedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let canvas = try ApplicationCaptureCanvas(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1),
        ])
        for scenario in ["immediate", "changing", "delayed"] {
            let video = folder.appendingPathComponent("\(scenario).mp4")
            let encoder = try ApplicationVideoEncoder(canvas: canvas, url: video) { XCTFail($0.localizedDescription) }
            encoder.queue.async {
                // receive使用与系统采集相同的真实图像入口，不申请屏幕权限。
                encoder.receive(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), display: 1)
            }
            try await encoder.waitUntilReady()
            if scenario != "immediate" {
                if scenario == "delayed" {
                    // 150ms跨过四个30fps定时边界；输出时长必须保留排队经过时间。
                    encoder.queue.asyncAfter(deadline: .now() + 0.1) { Thread.sleep(forTimeInterval: 0.15) }
                }
                try await Task.sleep(nanoseconds: 350_000_000)
                encoder.queue.async {
                    encoder.receive(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), display: 1)
                }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            try await encoder.finish(discard: false)
            let info = try await GIFExporter.metadata(video)
            XCTAssertEqual([info.width, info.height], [64, 64])
            if scenario != "immediate" { XCTAssertGreaterThanOrEqual(info.duration, 0.70) }
            let original = try Data(contentsOf: video)
            let asset = AVURLAsset(url: video)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let scale = try await track.load(.naturalTimeScale)
            XCTAssertEqual(scale, 600)
            // 读取解码后的帧序列，验证实际容器时间而非私有字段或append调用次数。
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var previous = CMTime.invalid
            while let sample = output.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                XCTAssertTrue(time.isValid)
                if previous.isValid { XCTAssertGreaterThan(CMTimeCompare(time, previous), 0) }
                else { XCTAssertEqual(CMTimeCompare(time, .zero), 0) }
                previous = time
            }
            XCTAssertTrue(previous.isValid)
            XCTAssertEqual(reader.status, .completed)
            for fps in [1, 10, 30] {
                for format in [GIFExporter.Format.gif, .apng] {
                    let animation = folder.appendingPathComponent("\(scenario)-\(fps).\(format.kind.fileExtension)")
                    let count = try await GIFExporter.export(source: video, destination: animation,
                        options: .init(framesPerSecond: fps, maximumWidth: 32), format: format) { _ in }
                    XCTAssertEqual(count, max(1, Int(ceil(info.duration * Double(fps) - 1e-9))))
                    let source = try XCTUnwrap(CGImageSourceCreateWithURL(animation as CFURL, nil))
                    XCTAssertEqual(CGImageSourceGetCount(source), count)
                    var colors: [Int] = []
                    var delay = 0.0
                    for index in 0..<count {
                        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                        XCTAssertEqual([image.width, image.height], [32, 32])
                        // pixels统一解码通道；主色需超过200且另一主色低于40，容纳H264与动图量化误差。
                        let rgb = Array(try pixels(image).prefix(3))
                        let color = try XCTUnwrap(rgb.indices.max(by: { rgb[$0] < rgb[$1] }))
                        XCTAssertTrue(color == 0 || color == 2)
                        XCTAssertGreaterThan(rgb[color], 200)
                        XCTAssertLessThan(rgb[color == 0 ? 2 : 0], 40)
                        colors.append(color)
                        // 单帧PNG无需动画延时；累计取整最多误差0.005秒，末帧最少0.01秒可再延长不足0.01秒。
                        if count > 1 {
                            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
                            let key = format == .gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
                            let delayKey = format == .gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
                            let frame = try XCTUnwrap(properties[key] as? [CFString: Any])
                            delay += try XCTUnwrap(frame[delayKey] as? Double)
                        }
                    }
                    XCTAssertEqual(colors.first, 0)
                    XCTAssertEqual(colors, colors.sorted())
                    if scenario != "immediate" && fps >= 10 { XCTAssertEqual(colors.last, 2) }
                    if count > 1 { XCTAssertEqual(delay, info.duration, accuracy: 0.015000001) }
                }
            }
            if scenario != "immediate" {
                for format in [GIFExporter.Format.gif, .apng] {
                    let animation = folder.appendingPathComponent("\(scenario)-crop.\(format.kind.fileExtension)")
                    // 0.5–0.7秒完全落在0.35秒后的蓝段，10fps恰好两帧，裁剪不得回到红色首帧。
                    let count = try await GIFExporter.export(source: video, destination: animation,
                        options: .init(framesPerSecond: 10), format: format,
                        range: CMTimeRange(start: CMTime(value: 5, timescale: 10), duration: CMTime(value: 2, timescale: 10))) { _ in }
                    XCTAssertEqual(count, 2)
                    let source = try XCTUnwrap(CGImageSourceCreateWithURL(animation as CFURL, nil))
                    XCTAssertEqual(CGImageSourceGetCount(source), 2)
                    for index in 0..<count {
                        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                        let rgb = Array(try pixels(image).prefix(3))
                        XCTAssertEqual([image.width, image.height], [64, 64])
                        XCTAssertGreaterThan(rgb[2], 200)
                        XCTAssertLessThan(rgb[0], 40)
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: video), original)
        }
    }

    /// 无参数/返回值；零屏及仅收到一屏均没有完整合成帧，保留结束必须明确失败，不能交付空MP4。
    /// 边界：画布要求两屏；0/2与1/2都不能建立有效帧时间，2/2成功路径由真实合成视频用例覆盖。
    func testApplicationEncoderRejectsFinishWithoutCompleteFrames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationEmpty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let canvas = try ApplicationCaptureCanvas(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1),
            .init(id: 2, frame: CGRect(x: 64, y: 0, width: 64, height: 64), scale: 1),
        ])
        for partial in [false, true] {
            let video = folder.appendingPathComponent("empty-\(partial).mp4")
            let encoder = try ApplicationVideoEncoder(canvas: canvas, url: video) { XCTFail($0.localizedDescription) }
            if partial {
                encoder.queue.async {
                    encoder.receive(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), display: 1)
                }
            }
            do {
                try await encoder.finish(discard: false)
                XCTFail("没有完整合成帧不能成功结束录制。")
            } catch {
                XCTAssertEqual(error.localizedDescription, "没有可保留的应用录制画面。")
            }
            do {
                _ = try await GIFExporter.metadata(video)
                XCTFail("无帧录制不能成为可交付媒体。")
            } catch { }
        }
    }

    /// 无参数/返回值；首帧前后放弃均取消后续准备，不留下启动等待或可交付MP4。
    /// 边界：无帧放弃不得提交无效结束时间；已有一帧放弃仍必须取消整个编码结果。
    func testDiscardBeforeFirstFrameCancelsReadiness() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let canvas = try ApplicationCaptureCanvas(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1),
        ])
        for hasFrame in [false, true] {
            let video = folder.appendingPathComponent("cancel-\(hasFrame).mp4")
            let encoder = try ApplicationVideoEncoder(canvas: canvas, url: video) { XCTFail($0.localizedDescription) }
            if hasFrame {
                encoder.queue.async {
                    encoder.receive(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), display: 1)
                }
                try await encoder.waitUntilReady()
            }
            // finish模拟真实放弃先完成的状态；waitUntilReady必须观察已结束的编码器身份。
            try await encoder.finish(discard: true)
            do {
                try await encoder.waitUntilReady()
                XCTFail("已放弃的录制不能继续等待或进入可录制状态。")
            } catch is CancellationError {
                // 取消为预期业务结果，不要求调用方等待首帧超时。
            }
            do {
                _ = try await GIFExporter.metadata(video)
                XCTFail("放弃的录制不能成为可交付媒体。")
            } catch { }
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

    /// 无参数；录制延时期间处于准备阶段且快照携带剩余秒数，放弃后回到空闲且到时不再开始录制，无返回值（#129）。
    @MainActor
    func testRecordingCountdownCancelReturnsIdle() async throws {
        let service = MediaCaptureService()
        // 边界：倒计时在建立捕获流之前进行，不申请屏幕录制权限即可观察；3 秒为最短的非零延时。
        let start = Task { @MainActor in
            try await service.startRecording(["kind": CaptureTarget.display.rawValue], delay: 3)
        }
        while !service.isCountingDown { await Task.yield() }
        XCTAssertEqual(service.phase, .preparing)
        XCTAssertEqual(service.snapshot()["countdown"] as? Int, 3)
        await service.cancel()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertFalse(service.isCountingDown)
        XCTAssertNil(service.snapshot()["countdown"])
        // 边界：被放弃的倒计时在下一秒醒来后以取消结束，会话仍为空闲。
        do {
            try await start.value
            XCTFail("倒计时被放弃后不应开始录制")
        } catch is CancellationError {}
        XCTAssertEqual(service.phase, .idle)
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

    /// url为本用例私有路径，indices为写入的帧号（第 n 帧呈现于 n/30 秒，缺省为 0–29 连续帧），
    /// colorProperties为可选的 AVVideoColorPropertiesKey 色彩标注；写入1秒64×48无声H264，三段颜色用于核验时间顺序。
    private func writeMovie(_ url: URL, indices: [Int] = Array(0..<30), colorProperties: [String: String]? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48]
        settings[AVVideoColorPropertiesKey] = colorProperties
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(10)
        for index in indices {
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

    /// 无参数；APNG 按裁剪区间导出：0.5–1.0 秒在 10fps 下恰好 5 帧，首帧来自区间起点（绿段）而非视频开头（红段），
    /// 延时合计等于区间时长，文件无限循环且源视频不变（#110）。
    func testAPNGExportUsesTrimRangeAndLoopsForever() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureAPNGTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        try await writeMovie(video)
        let original = try Data(contentsOf: video)
        let apng = directory.appendingPathComponent("result.png")
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 2))
        let count = try await GIFExporter.export(source: video, destination: apng,
            options: .init(framesPerSecond: 10, maximumWidth: 32), format: .apng, range: range) { _ in }
        XCTAssertEqual(count, 5)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(apng as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 5)
        let file = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let png = try XCTUnwrap(file[kCGImagePropertyPNGDictionary] as? [CFString: Any])
        XCTAssertEqual(png[kCGImagePropertyAPNGLoopCount] as? Int, 0)
        var delays = 0.0
        var colors: [Int] = []
        for index in 0..<count {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, 32)
            let rgb = Array(try pixels(image).prefix(3))
            colors.append(try XCTUnwrap(rgb.indices.max(by: { rgb[$0] < rgb[$1] })))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let frame = try XCTUnwrap(properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
            delays += try XCTUnwrap(frame[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
        }
        // 0.5、0.6 秒落在绿段（第 10–19 帧），0.7–0.9 秒落在蓝段（第 20–29 帧）。
        XCTAssertEqual(colors, [1, 1, 2, 2, 2])
        XCTAssertEqual(delays, 0.5, accuracy: 0.011)
        XCTAssertEqual(try Data(contentsOf: video), original)
    }

    /// 无参数；裁剪 0.4–0.9 秒重新编码后时长为 0.5 秒（容差一帧），开头取自绿段、结尾取自蓝段，源视频不变（#110）。
    func testTrimmedVideoMatchesSelectedRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureTrimTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        try await writeMovie(video)
        let original = try Data(contentsOf: video)
        let output = directory.appendingPathComponent("trimmed.mp4")
        let range = CMTimeRange(start: CMTime(value: 2, timescale: 5), end: CMTime(value: 9, timescale: 10))
        try await MediaCaptureService.trimVideo(source: video, range: range, destination: output) { _ in }
        let info = try await GIFExporter.metadata(output)
        XCTAssertEqual(info.duration, 0.5, accuracy: 1.0 / 30)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var colors: [Int] = []
        // 输出 0.05 秒对应源 0.45 秒（第 13 帧，绿），0.45 秒对应源 0.85 秒（第 25 帧，蓝）。
        for seconds in [0.05, 0.45] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let rgb = Array(try pixels(image).prefix(3))
            colors.append(try XCTUnwrap(rgb.indices.max(by: { rgb[$0] < rgb[$1] })))
        }
        XCTAssertEqual(colors, [1, 2])
        XCTAssertEqual(try Data(contentsOf: video), original)
    }

    /// 无参数；源为 0–9、15–29 帧的变帧率视频，裁剪 0.35–0.9 秒导出 WebM（#110）。
    /// 边界：0.35 秒落在 10–14 帧的空档内，跨过起点的第 9 帧从 0 计时；其后第 15–26 帧按源时间减起点取整到毫秒，
    /// 第 27 帧恰在 0.9 秒终点上不进入；总时长 550ms，最后一帧时长补到终点；矩阵转为 BT.601 写成代码 6，BT.709 色域与传递特性写成代码 1。
    func testWebMExportKeepsSourceFrameTimesWithinTrimRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureWebMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        try await writeMovie(video, indices: Array(0..<10) + Array(15..<30), colorProperties: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ])
        let original = try Data(contentsOf: video)
        let output = directory.appendingPathComponent("result.webm")
        let range = CMTimeRange(start: CMTime(value: 7, timescale: 20), end: CMTime(value: 9, timescale: 10))
        let count = try await WebMExporter.export(source: video, destination: output, range: range) { _ in }
        let webm = try parseWebM(Data(contentsOf: output))
        XCTAssertEqual(count, 13)
        XCTAssertEqual(webm.docType, "webm")
        XCTAssertEqual(webm.timecodeScale, 1_000_000)
        XCTAssertEqual(webm.duration, 550)
        XCTAssertEqual(webm.codec, "V_VP8")
        XCTAssertEqual([webm.width, webm.height], [64, 48])
        XCTAssertEqual(webm.colour, [6, 1, 1, 1])
        XCTAssertEqual(webm.frames.map { $0.time }, [0] + (15...26).map { Int64((Double($0) / 30 - 0.35) * 1000 + 0.5) })
        XCTAssertTrue(webm.frames[0].key)
        XCTAssertEqual(webm.frames.last?.duration, 550 - 517)
        // VP8 帧标签首位 0 为关键帧，关键帧在第 3–5 字节带起始码 9D 01 2A。
        XCTAssertTrue(webm.frames.allSatisfy { ($0.data[0] & 1 == 0) == $0.key })
        XCTAssertTrue(webm.frames.filter { $0.key }.allSatisfy { $0.data[3..<6] == Data([0x9D, 0x01, 0x2A]) })
        XCTAssertEqual(webm.cues.map { $0.time }, webm.clusters.filter { $0.key }.map { $0.time })
        XCTAssertEqual(try Data(contentsOf: video), original)
    }

    /// 无参数；首个进度回报后取消导出：抛出 CancellationError，已创建的 WebM 被删除，源视频不变（#110）。
    func testWebMCancellationDuringExportRemovesOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureWebMCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        try await writeMovie(video)
        let original = try Data(contentsOf: video)
        let output = directory.appendingPathComponent("cancelled.webm")
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await WebMExporter.export(source: video, destination: output, range: nil) { _ in started.continuation.yield() }
        }
        // 第一帧已写入编码会话、输出文件已创建后才取消。
        for await _ in started.stream { break }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("取消任务不能成功") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: video), original)
    }

    /// 无参数；写出器按关键帧与 Int16 相对时间码切分 Cluster，并回填 Segment 大小与索引位置（#110）。
    /// 边界：66667µs 进位为 67ms，2000499µs 舍为 2000ms、2000500µs 进为 2001ms；相对 Cluster 起点 32767ms
    /// 的帧留在原 Cluster，32768ms 的帧开新 Cluster 但不建索引；最后一帧为非关键帧时用 -1ms 的 ReferenceBlock 指向上一帧。
    func testWebMWriterSplitsClustersAndPatchesIndex() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WebMWriter-\(UUID().uuidString).webm")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WebMWriter(url: url, width: 1280, height: 720, duration: 35_000_000,
                                    colour: .init(matrix: 6, transfer: 13, primaries: 5))
        let inputs: [(Int64, Bool)] = [(0, true), (33_333, false), (66_667, false), (2_000_000, true),
                                       (2_000_499, false), (2_000_500, false), (34_767_000, false), (34_768_000, false)]
        for (index, (timestamp, key)) in inputs.enumerated() {
            try writer.append(.init(timestamp: timestamp, key: key, data: Data([0x80, UInt8(index)])))
        }
        try writer.finish(expectedFrames: inputs.count)
        let webm = try parseWebM(Data(contentsOf: url))
        XCTAssertEqual(webm.duration, 35_000)
        XCTAssertEqual([webm.width, webm.height], [1280, 720])
        XCTAssertEqual(webm.colour, [6, 1, 13, 5])
        XCTAssertEqual(webm.frames.map { $0.time }, [0, 33, 67, 2000, 2000, 2001, 34_767, 34_768])
        XCTAssertEqual(webm.frames.map { $0.key }, [true, false, false, true, false, false, false, false])
        XCTAssertEqual(webm.frames.map { $0.data }, (0..<8).map { Data([0x80, UInt8($0)]) })
        XCTAssertEqual(webm.clusters.map { $0.time }, [0, 2000, 34_768])
        XCTAssertEqual(webm.cues.map { $0.time }, [0, 2000])
        XCTAssertEqual(webm.frames.last?.duration, 232)
        XCTAssertEqual(webm.frames.last?.reference, -1)
        XCTAssertNil(webm.frames[6].duration)
    }

    /// 无参数；收到的编码帧少于读入帧数（编码器丢帧）时 finish 报错（#110）。
    /// 边界：读入 3 帧只收到 2 帧即差 1 帧，必须失败；收到帧数与读入帧数相等的成功路径由 Cluster 切分用例覆盖。
    func testWebMWriterRejectsDroppedFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WebMWriterDrop-\(UUID().uuidString).webm")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WebMWriter(url: url, width: 64, height: 48, duration: 100_000,
                                    colour: .init(matrix: 6, transfer: 1, primaries: 1))
        try writer.append(.init(timestamp: 0, key: true, data: Data([0x80])))
        try writer.append(.init(timestamp: 33_333, key: false, data: Data([0x81])))
        XCTAssertThrowsError(try writer.finish(expectedFrames: 3)) { error in
            XCTAssertEqual(error.localizedDescription, "WebM 编码器丢弃了 1 帧，帧时间无法与源一致，未保存结果。")
        }
    }

    /// 无参数；自动滚动步进：画面移动后连续 2 帧静止才滚下一步，按实测位移校准增量且最多放大 4 倍（#112）。
    /// 边界：选区高 1000px 目标 500px；首步 0.01 移动 100px，只静止 1 帧时仍等待，第 2 帧静止才按 0.01×500/100=0.05
    /// 截到 4 倍即 0.04；第二步移动 400px 后按 0.04×500/400=0.05 滚动（未超 4 倍上限 0.16）。
    func testAutoScrollPlanCalibratesStepAfterSettling() {
        let start = ContinuousClock.now
        let at = { (ms: Int) in start.advanced(by: .milliseconds(ms)) }
        var plan = AutoScrollPlan(height: 1000)
        XCTAssertEqual(plan.start(now: at(0)), .scroll(by: 0.01))
        XCTAssertEqual(plan.frame(shift: 100, now: at(100)), .wait)
        XCTAssertEqual(plan.frame(shift: 0, now: at(200)), .wait)
        XCTAssertEqual(plan.frame(shift: 0, now: at(300)), .scroll(by: 0.04))
        XCTAssertEqual(plan.frame(shift: 400, now: at(400)), .wait)
        XCTAssertEqual(plan.frame(shift: 0, now: at(500)), .wait)
        guard case .scroll(let step) = plan.frame(shift: 0, now: at(600)) else { return XCTFail("停稳后应滚动下一步") }
        XCTAssertEqual(step, 0.05, accuracy: 1e-9)
    }

    /// 无参数；画面持续移动时单步最多等 1000ms 再滚下一步（#112）。
    /// 边界：每 100ms 移动 10px，第 900ms 仍等待，第 1000ms 开始下一步；累计 100px 按 0.05 截到 4 倍 0.04。
    func testAutoScrollPlanStepsAfterMaximumWaitWhileMoving() {
        let start = ContinuousClock.now
        let at = { (ms: Int) in start.advanced(by: .milliseconds(ms)) }
        var plan = AutoScrollPlan(height: 1000)
        _ = plan.start(now: at(0))
        for ms in stride(from: 100, through: 900, by: 100) { XCTAssertEqual(plan.frame(shift: 10, now: at(ms)), .wait) }
        XCTAssertEqual(plan.frame(shift: 10, now: at(1000)), .scroll(by: 0.04))
    }

    /// 无参数；滚动后 1500ms 无移动：从未移动过为不支持，移动过为到底；到底后不再出动作，重新开始即恢复滚动（#112）。
    /// 边界：第 1400ms 仍等待、第 1500ms 判定；到底判定后的帧返回等待。
    func testAutoScrollPlanSeparatesUnsupportedFromBottom() {
        let start = ContinuousClock.now
        let at = { (ms: Int) in start.advanced(by: .milliseconds(ms)) }
        var unsupported = AutoScrollPlan(height: 1000)
        _ = unsupported.start(now: at(0))
        for ms in stride(from: 100, through: 1400, by: 100) { XCTAssertEqual(unsupported.frame(shift: 0, now: at(ms)), .wait) }
        XCTAssertEqual(unsupported.frame(shift: 0, now: at(1500)), .unsupported)

        var bottom = AutoScrollPlan(height: 1000)
        _ = bottom.start(now: at(0))
        _ = bottom.frame(shift: 200, now: at(100))
        _ = bottom.frame(shift: 0, now: at(200))
        guard case .scroll = bottom.frame(shift: 0, now: at(300)) else { return XCTFail("停稳后应滚动下一步") }
        XCTAssertEqual(bottom.frame(shift: 0, now: at(1700)), .wait)
        XCTAssertEqual(bottom.frame(shift: 0, now: at(1800)), .bottom)
        XCTAssertEqual(bottom.frame(shift: 0, now: at(1900)), .wait)
        guard case .scroll = bottom.start(now: at(5000)) else { return XCTFail("继续后应重新开始滚动") }
    }

    /// 无参数；接缝失败时退回并把步长减半，退回后的画面连续 2 帧静止才按新步长重试（#112）。
    /// 边界：首步 0.01 失配后为 0.005；退回后第 1 帧静止仍等待，第 2 帧重试。
    func testAutoScrollPlanRewindsAndRetriesWithHalfStep() {
        let start = ContinuousClock.now
        let at = { (ms: Int) in start.advanced(by: .milliseconds(ms)) }
        var plan = AutoScrollPlan(height: 1000)
        _ = plan.start(now: at(0))
        XCTAssertEqual(plan.mismatch(now: at(100)), .rewind)
        XCTAssertEqual(plan.frame(shift: 0, now: at(200)), .wait)
        XCTAssertEqual(plan.frame(shift: 0, now: at(300)), .scroll(by: 0.005))
    }

    /// 解析后的 WebM：头部类型、Info、视频轨与 Colour（矩阵、范围、传递特性、色域），Cluster 与其中按时间顺序的帧，以及 Cues。
    private struct ParsedWebM {
        var docType = ""
        var timecodeScale: UInt64 = 0
        var duration = 0.0
        var codec = ""
        var width: UInt64 = 0
        var height: UInt64 = 0
        var colour: [UInt64] = []
        var clusters: [(time: Int64, key: Bool)] = []
        var frames: [(time: Int64, key: Bool, data: Data, duration: UInt64?, reference: Int64?)] = []
        var cues: [(time: Int64, position: Int)] = []
    }

    /// data为EBML字节，range为父元素数据范围；返回直接子元素的ID、元素起点与数据范围。
    private func ebmlChildren(_ data: Data, _ range: Range<Int>) -> [(id: UInt32, start: Int, payload: Range<Int>)] {
        var items: [(id: UInt32, start: Int, payload: Range<Int>)] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            let start = offset
            // ID 与尺寸的长度都由首字节前导零个数决定；ID 保留长度标记位，尺寸去掉标记位。
            let idLength = data[offset].leadingZeroBitCount + 1
            let id = data[offset..<offset + idLength].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            offset += idLength
            let sizeLength = data[offset].leadingZeroBitCount + 1
            let size = data[offset + 1..<offset + sizeLength].reduce(UInt64(data[offset] & (0xFF >> sizeLength))) { $0 << 8 | UInt64($1) }
            offset += sizeLength
            items.append((id, start, offset..<offset + Int(size)))
            offset += Int(size)
        }
        return items
    }

    /// data为WebM文件；返回 [ParsedWebM]。同时断言 Segment 大小等于文件剩余长度、SeekHead 指向 Cues、每个 CuePoint 指向 Cluster。
    private func parseWebM(_ data: Data) throws -> ParsedWebM {
        let uint = { (range: Range<Int>) in data[range].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        var result = ParsedWebM()
        let top = ebmlChildren(data, 0..<data.count)
        XCTAssertEqual(top.map { $0.id }, [0x1A45_DFA3, 0x1853_8067])
        for child in ebmlChildren(data, top[0].payload) where child.id == 0x4282 {
            result.docType = String(decoding: data[child.payload], as: UTF8.self)
        }
        let segment = top[1].payload
        XCTAssertEqual(segment.upperBound, data.count)
        var clusterStarts: Set<Int> = []
        var seekCues = -1, cuesStart = -2
        for element in ebmlChildren(data, segment) {
            switch element.id {
            case 0x114D_9B74:
                let seek = try XCTUnwrap(ebmlChildren(data, element.payload).first)
                let entries = ebmlChildren(data, seek.payload)
                XCTAssertEqual(Data(data[entries[0].payload]), Data([0x1C, 0x53, 0xBB, 0x6B]))
                seekCues = Int(uint(entries[1].payload))
            case 0x1549_A966:
                for child in ebmlChildren(data, element.payload) {
                    if child.id == 0x2A_D7B1 { result.timecodeScale = uint(child.payload) }
                    if child.id == 0x4489 { result.duration = Double(bitPattern: uint(child.payload)) }
                }
            case 0x1654_AE6B:
                let entry = try XCTUnwrap(ebmlChildren(data, element.payload).first)
                for child in ebmlChildren(data, entry.payload) {
                    if child.id == 0x86 { result.codec = String(decoding: data[child.payload], as: UTF8.self) }
                    guard child.id == 0xE0 else { continue }
                    for field in ebmlChildren(data, child.payload) {
                        if field.id == 0xB0 { result.width = uint(field.payload) }
                        if field.id == 0xBA { result.height = uint(field.payload) }
                        if field.id == 0x55B0 { result.colour = ebmlChildren(data, field.payload).map { uint($0.payload) } }
                    }
                }
            case 0x1F43_B675:
                clusterStarts.insert(element.start - segment.lowerBound)
                var clusterTime: Int64 = 0
                var first = true
                for child in ebmlChildren(data, element.payload) {
                    if child.id == 0xE7 { clusterTime = Int64(uint(child.payload)); continue }
                    // SimpleBlock 直接是块；BlockGroup 内含 Block、BlockDuration 与可选 ReferenceBlock。
                    let parts = child.id == 0xA0 ? ebmlChildren(data, child.payload) : [child]
                    let block = try XCTUnwrap(parts.first { $0.id == 0xA1 || $0.id == 0xA3 }).payload
                    let relative = Int16(bitPattern: UInt16(data[block.lowerBound + 1]) << 8 | UInt16(data[block.lowerBound + 2]))
                    let reference = parts.first { $0.id == 0xFB }.map { field in
                        data[field.payload].dropFirst().reduce(Int64(Int8(bitPattern: data[field.payload.lowerBound]))) { $0 << 8 | Int64($1) }
                    }
                    let key = child.id == 0xA3 ? data[block.lowerBound + 3] & 0x80 != 0 : reference == nil
                    result.frames.append((clusterTime + Int64(relative), key, Data(data[block.lowerBound + 4..<block.upperBound]),
                                          parts.first { $0.id == 0x9B }.map { uint($0.payload) }, reference))
                    if first { result.clusters.append((clusterTime, key)); first = false }
                }
            case 0x1C53_BB6B:
                cuesStart = element.start - segment.lowerBound
                for point in ebmlChildren(data, element.payload) {
                    let fields = ebmlChildren(data, point.payload)
                    let position = try XCTUnwrap(ebmlChildren(data, fields[1].payload).first { $0.id == 0xF1 })
                    result.cues.append((Int64(uint(fields[0].payload)), Int(uint(position.payload))))
                }
            default:
                break
            }
        }
        XCTAssertEqual(seekCues, cuesStart)
        XCTAssertTrue(result.cues.allSatisfy { clusterStarts.contains($0.position) })
        return result
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

    /// 无参数；文字在分数像素位置按覆盖面积重绘（网页平滑滚动），正文与稀疏评论都应接受并保持累计高度，
    /// 完全重复的段落仍须拒绝。旧配准只拟合相邻行线性插值，这类帧在首次移动即误报缺少重叠。
    func testAreaRasterizedTextScrollingKeepsOverlapAndHeight() throws {
        let article = scrollingText(comments: false)
        let comments = scrollingText(comments: true)
        for (text, step) in [(article, 3.25), (article, 8.5), (article, 20.75), (comments, 8.5)] {
            let initial = 0.25
            let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
            for index in 0...3 {
                XCTAssertNoThrow(try stitcher.append(areaTextViewport(text, offset: initial + Double(index) * step)),
                                 "步进\(step)第\(index)帧")
            }
            let result = try stitcher.finish()
            XCTAssertEqual(result.frames, 4)
            // 按累计分数位移取整，不能因逐帧舍入丢失或重复正文行。
            XCTAssertLessThanOrEqual(abs(Double(result.height) - (640 + 3 * step)), 0.75)
            let expected = try pixels(areaTextViewport(text, offset: initial, height: result.height))
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
        let repeated = (0..<90).map { $0 % 4 == 3 ? "项目0001：列表项目需要清晰的信息结构、稳定的文字间距。\n\n\n"
            : "项目0001：列表项目需要清晰的信息结构、稳定的文字间距。\n" }.joined()
        let ambiguous = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        try ambiguous.append(areaTextViewport(repeated, offset: 0))
        let confirmed = try ambiguous.finish().png
        XCTAssertThrowsError(try ambiguous.append(areaTextViewport(repeated, offset: 8.5)))
        XCTAssertEqual(try ambiguous.finish().png, confirmed)
    }

    /// comments决定稀疏评论或逐行不同的正文；返回固定伪随机生成的中文文本，不依赖网络页面。
    private func scrollingText(comments: Bool) -> String {
        if comments {
            return (0..<60).map { "第\($0 + 1)条评论：" + String(repeating: "好看", count: $0 % 5 + 1)
                + String(repeating: "\n", count: 2 + $0 % 3) }.joined()
        }
        let pool = Array("的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题")
        var seed: UInt32 = 7
        var text = ""
        for index in 0..<70 {
            for _ in 0..<(18 + index * 29 % 40) {
                seed = seed &* 1103515245 &+ 12345
                text.append(pool[Int(seed >> 16) % pool.count])
            }
            text += index % 3 == 2 ? "。\n\n" : "。\n"
        }
        return text
    }

    /// text为页面正文，offset为四分之一像素滚动量，height为视口高度；4倍栅格后按面积缩回600像素宽，
    /// 模拟网页在分数像素位置重绘文字，而不是对整数帧做线性插值。
    private func areaTextViewport(_ text: String, offset: Double, height: Int = 640) throws -> CGImage {
        let width = 600
        let scale = 4
        let pageHeight = 2000 * scale
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(15 * scale), nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 28 * scale, y: 20 * scale, width: (width - 56) * scale,
                                       height: pageHeight - 40 * scale), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let largeWidth = width * scale
        let largeHeight = height * scale
        var coverage = [UInt8](repeating: 255, count: largeWidth * largeHeight)
        try coverage.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: largeWidth, height: largeHeight,
                bitsPerComponent: 8, bytesPerRow: largeWidth, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue))
            // CoreText页面原点在左下；4倍空间的整数位移把页顶offset处移到视口顶部。
            context.translateBy(x: 0, y: CGFloat(largeHeight + Int((offset * Double(scale)).rounded()) - pageHeight))
            CTFrameDraw(frame, context)
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        coverage.withUnsafeBufferPointer { source in
            for y in 0..<height {
                for x in 0..<width {
                    var total = 0
                    for dy in 0..<scale {
                        let row = (y * scale + dy) * largeWidth + x * scale
                        for dx in 0..<scale { total += Int(source[row + dx]) }
                    }
                    let value = UInt8((Double(total) / Double(scale * scale)).rounded())
                    let index = (y * width + x) * 4
                    bytes[index] = value
                    bytes[index + 1] = value
                    bytes[index + 2] = value
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
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

    /// 无参数；单帧滚过123像素上限只丢弃本帧，回滚到参照帧重叠范围后继续追加且像素连续；
    /// 位移比例供预警使用，尺寸变化仍是不可恢复错误。
    func testTooFastFrameIsRecoverableAndScrollingBackContinues() throws {
        let stitcher = ScrollStitcher(edges: .init(top: 0, bottom: 0, automatic: true))
        try stitcher.append(frame(offset: 0))
        let confirmed = try stitcher.finish().png
        XCTAssertThrowsError(try stitcher.append(frame(offset: 150))) { error in
            XCTAssertEqual((error as? ScrollStitcher.Failure)?.recoverable, true)
        }
        XCTAssertEqual(try stitcher.finish().png, confirmed)
        XCTAssertEqual(stitcher.acceptedFrames, 1)
        // 参照帧仍是offset 0；回滚到60像素后正常追加，60/123低于60%预警线。
        XCTAssertTrue(try stitcher.append(frame(offset: 60)))
        XCTAssertLessThan(stitcher.lastShiftRatio, 0.6)
        // 164像素正文允许单帧123像素；再移动80像素超过60%，仍可拼接。
        XCTAssertTrue(try stitcher.append(frame(offset: 140)))
        XCTAssertEqual(stitcher.lastShiftRatio, 80.0 / 123.0, accuracy: 0.001)
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, 332)
        XCTAssertEqual(try pixels(decode(result.png)), try pixels(frame(height: 332, offset: 0)))
        XCTAssertThrowsError(try stitcher.append(frame(height: 191, offset: 160))) { error in
            XCTAssertEqual((error as? ScrollStitcher.Failure)?.recoverable, false)
        }
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
