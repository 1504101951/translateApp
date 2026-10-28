import Cocoa
import CoreImage
import FlutterMacOS
import ServiceManagement
import Translation
import XCTest

@testable import translate_app

class RunnerTests: XCTestCase {
    /// 尺寸和颜色为测试输入；返回实际像素明确的 PNG，避免动态颜色在离屏上下文中失效。
    @MainActor
    private func screenshotFixture(width: Int, height: Int, color: NSColor) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<width { for y in 0..<height { image.setColor(color, atX: x, y: y) } }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    /// 无参数；等待正式截图引擎入口确认并显示编辑器，返回可见窗口；六秒覆盖五秒启动预算。
    @MainActor
    private func waitForScreenshotEditor() async throws -> NSWindow {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSApp.windows.contains { $0 is ScreenshotPanel && $0.isVisible }
        }, object: nil)
        await fulfillment(of: [visible], timeout: 6)
        return try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
    }

    /// 无参数；真实标题材料和内容安全区随外观、透明度及窗口尺寸同步，测试后恢复偏好。
    @MainActor
    func testGlassTitlebarAppearanceAndContentLayout() throws {
        let previous = UserDefaults.standard.object(forKey: AppConstants.preferencesKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppConstants.preferencesKey) }
            else { UserDefaults.standard.removeObject(forKey: AppConstants.preferencesKey) }
        }
        let engine = FlutterEngine(name: "glass-window-test", project: nil, allowHeadlessExecution: false)
        defer { engine.shutDownEngine() }
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        NativeGlassFactory.installContent(flutter, in: window)
        let content = try XCTUnwrap(window.contentViewController as? NativeGlassWindowContent)
        // 三种模式覆盖手动外观和恢复系统继承；端点0.2/1覆盖材料而非前景的透明度。
        for (mode, opacity) in [("dark", 0.2), ("light", 1.0), ("system", 0.8)] {
            UserDefaults.standard.set([AppConstants.glassAppearanceKey: mode, AppConstants.glassOpacityKey: opacity], forKey: AppConstants.preferencesKey)
            NativeGlassFactory.applyAppearance(to: window)
            XCTAssertEqual(window.appearance?.name, mode == "system" ? nil : (mode == "dark" ? NSAppearance.Name.darkAqua : NSAppearance.Name.aqua))
            XCTAssertEqual(content.windowCanvas.alphaValue, 1)
            let expectedWhite = mode == "dark" ? 23.0 / 255.0 : 247.0 / 255.0
            if mode != "system" {
                let canvasColor = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(content.windowCanvas.layer?.backgroundColor)))
                XCTAssertEqual(canvasColor.usingColorSpace(.sRGB)!.redComponent, expectedWhite, accuracy: 0.01)
            }
            XCTAssertEqual(flutter.view.alphaValue, 1)
            window.setContentSize(NSSize(width: 620, height: 540))
            content.view.layoutSubtreeIfNeeded()
            // 窗口缩放后背景仍铺满整窗，Flutter内容紧贴标题安全边界且无第二层圆角。
            XCTAssertEqual(content.windowCanvas.frame, content.view.bounds)
            XCTAssertEqual(flutter.view.frame.maxY, window.contentLayoutRect.maxY, accuracy: 0.5)
            XCTAssertNil(content.windowCanvas.hitTest(.zero))
            XCTAssertEqual(flutter.view.frame.width, content.windowCanvas.frame.width, accuracy: 0.5)
        }
    }

    /// 无参数；确认前取消或转入采集均清空旧草稿，随后只展示最新截图；无返回值。
    /// 同一主队列内取消覆盖 run 尚未执行的边界，六秒窗口等待覆盖正常重新启动。
    @MainActor
    func testScreenshotPendingStartupCancellationKeepsOnlyLatestDraft() async throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown() }
        let png = try screenshotFixture(width: 80, height: 60, color: .blue)
        for id in ["cancel-pending", "capture-pending"] {
            controller.seedCaptureForTesting(png: png, id: id, width: 80, height: 60, showEditor: true)
            if id == "cancel-pending" { controller.cancelCapture() }
            else { controller.closeForCapture() }
            XCTAssertFalse(controller.isCurrentCapture(id))
        }
        controller.seedCaptureForTesting(png: png, id: "latest", width: 80, height: 60, showEditor: true)
        // waitForScreenshotEditor 只等待正式入口确认后的真实窗口。
        _ = try await waitForScreenshotEditor()
        var state: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) {
            state = $0 as? [String: Any]
        }
        XCTAssertEqual(state?["id"] as? String, "latest")
        XCTAssertEqual((state?["bytes"] as? FlutterStandardTypedData)?.data, png)
        XCTAssertEqual(NSApp.windows.filter { $0 is ScreenshotPanel && $0.isVisible }.count, 1)
    }

    /// 无参数；采集界面预热尚未确认时退出，不能迟到创建面板，媒体保持空闲；无返回值。
    @MainActor
    func testCaptureShutdownCancelsPendingWarmup() async {
        let screenshot = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        let capture = CaptureWindowController(screenshot: screenshot)
        let before = Set(NSApp.windows.filter { $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) }.map(\.windowNumber))
        capture.prepareControls()
        capture.prepareControls()
        // shutdown 在等待真实媒体清理前同步取消窗口启动。
        await capture.shutdown()
        await Task.yield()
        let after = Set(NSApp.windows.filter { $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) }.map(\.windowNumber))
        XCTAssertEqual(after, before)
        XCTAssertEqual(capture.service.phase, .idle)
        screenshot.shutdown()
    }

    /// 无参数；从真实截图方法入口验证两类对角原生光标，拒绝未知值并恢复关闭后的箭头。
    @MainActor
    func testScreenshotDiagonalCursorUsesNativeFrameResize() async throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown(); NSCursor.arrow.set() }
        let png = try screenshotFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(png: png, id: "diagonal", width: 80, height: 60, showEditor: true)
        // waitForScreenshotEditor 等待入口确认，后续事件针对真实可见窗口。
        _ = try await waitForScreenshotEditor()
        // 两个双向轴覆盖四角：左上/右下与右上/左下。检查真实NSCursor状态而非下游调用次数。
        for (direction, position) in [(AppConstants.resizeNorthWestSouthEast, NSCursor.FrameResizePosition.topLeft), (AppConstants.resizeNorthEastSouthWest, .topRight)] {
            NSCursor.arrow.set()
            var response: Any?
            controller.handle(FlutterMethodCall(methodName: AppConstants.setResizeCursorMethod, arguments: ["direction": direction])) { response = $0 }
            XCTAssertNil(response)
            let expected = NSCursor.frameResize(position: position, directions: .all)
            XCTAssertEqual(NSCursor.current.image.tiffRepresentation, expected.image.tiffRepresentation)
            XCTAssertEqual(NSCursor.current.hotSpot, expected.hotSpot)
            XCTAssertNotEqual(NSCursor.current.image.tiffRepresentation, NSCursor.arrow.image.tiffRepresentation)
        }
        var invalid: Any?
        controller.handle(FlutterMethodCall(methodName: AppConstants.setResizeCursorMethod, arguments: ["direction": "unknown"])) { invalid = $0 }
        XCTAssertTrue(invalid is FlutterError)
        controller.handle(FlutterMethodCall(methodName: AppConstants.closeScreenshotMethod, arguments: nil)) { _ in }
        XCTAssertEqual(NSCursor.current.image.tiffRepresentation, NSCursor.arrow.image.tiffRepresentation)
        // 已关闭编辑器的迟到请求不能重新设置桌面光标。
        controller.handle(FlutterMethodCall(methodName: AppConstants.setResizeCursorMethod, arguments: ["direction": AppConstants.resizeNorthWestSouthEast])) { _ in }
        XCTAssertEqual(NSCursor.current.image.tiffRepresentation, NSCursor.arrow.image.tiffRepresentation)
    }

    /// 无参数；非激活截图的数字/Command组合在原生入口被消费，文本输入与关闭后原样放行。
    @MainActor
    func testScreenshotConfiguredShortcutConsumesOnlyItsScope() async throws {
        let previous = UserDefaults.standard.object(forKey: AppConstants.preferencesKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppConstants.preferencesKey) }
            else { UserDefaults.standard.removeObject(forKey: AppConstants.preferencesKey) }
        }
        UserDefaults.standard.set([AppConstants.screenshotToolbarShortcutsKey: [
            "screenshot-tool-text": ["keyId": 49, "modifiers": 0],
            "screenshot-tool-crop": ["keyId": 50, "modifiers": 8],
        ]], forKey: AppConstants.preferencesKey)
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown() }
        let png = try screenshotFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(png: png, id: "shortcut", width: 80, height: 60, showEditor: true)
        // waitForScreenshotEditor 等待入口确认，后续事件针对真实可见窗口。
        _ = try await waitForScreenshotEditor()
        // 实际UserDefaults到截图快照必须携带工具参数，否则重新截图后用户选择会丢失。
        var preferences = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey)!
        let drawing: [String: Any] = ["shape": "filledCircle", "brushMode": "mosaic", "tools": ["arrow": ["color": 0xFF007AFF, "width": 5]]]
        preferences[AppConstants.screenshotDrawingKey] = drawing
        UserDefaults.standard.set(preferences, forKey: AppConstants.preferencesKey)
        var snapshot: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) { snapshot = $0 as? [String: Any] }
        XCTAssertEqual(snapshot?[AppConstants.screenshotDrawingKey] as? NSDictionary, drawing as NSDictionary)

        // 49/50是逻辑字符1/2，18/19是ANSI物理键；真实event tap路径不直接给Flutter注入键。
        let one = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true))
        let two = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 19, keyDown: true))
        two.flags = .maskCommand
        XCTAssertNil(controller.filterScreenshotEvent(one))
        XCTAssertNil(controller.filterScreenshotEvent(two))
        let unbound = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 20, keyDown: true))
        XCTAssertTrue(controller.filterScreenshotEvent(unbound) === unbound)
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "shortcut", "active": true])) { _ in }
        XCTAssertTrue(controller.filterScreenshotEvent(one) === one)
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "shortcut", "active": false])) { _ in }
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "stale", "active": true])) { _ in }
        XCTAssertNil(controller.filterScreenshotEvent(two))
        controller.shutdown()
        XCTAssertTrue(controller.filterScreenshotEvent(one) === one)
    }

    /// 无参数；普通键和文本编辑命令原样放行，合法长按不去重；关闭后也无残留消费。
    @MainActor
    func testScreenshotKeysPreserveTypingAndTextEditing() async throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown() }
        let png = try screenshotFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(png: png, id: "typing", width: 80, height: 60, showEditor: true)
        // waitForScreenshotEditor 等待入口确认，后续事件针对真实可见窗口。
        _ = try await waitForScreenshotEditor()
        for repeated in [false, true] {
            let typed = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
            typed.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            XCTAssertTrue(controller.filterScreenshotEvent(typed) === typed)
        }
        controller.handle(FlutterMethodCall(methodName: AppConstants.screenshotTextInputMethod, arguments: ["id": "typing", "active": true])) { _ in }
        let undo = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
        undo.flags = .maskCommand
        XCTAssertTrue(controller.filterScreenshotEvent(undo) === undo)
        let enter = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        XCTAssertTrue(controller.filterScreenshotEvent(enter) === enter)
        controller.shutdown()
        XCTAssertTrue(controller.filterScreenshotEvent(enter) === enter)
    }

    /// 无参数；长图留在采集结果窗，首次及复用引擎都可见、可复制、可保存，红按钮关闭后文件仍在。
    @MainActor
    func testLongScreenshotResultWindowShowsAndSavesAfterCapture() async throws {
        let screenshot = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        let controller = CaptureWindowController(screenshot: screenshot)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongResult-\(UUID().uuidString)")
        let defaults = UserDefaults.standard
        let oldDirectory = defaults.object(forKey: AppConstants.screenshotSaveDirectoryKey)
        let oldPolicy = NSApp.activationPolicy()
        defaults.set(root.path, forKey: AppConstants.screenshotSaveDirectoryKey)
        addTeardownBlock { @MainActor in
            await controller.shutdown()
            screenshot.shutdown()
            defaults.set(oldDirectory, forKey: AppConstants.screenshotSaveDirectoryKey)
            if NSApp.activationPolicy() != oldPolicy { _ = NSApp.setActivationPolicy(oldPolicy) }
            try? FileManager.default.removeItem(at: root)
        }
        // 测试宿主可能已经是 accessory，重复设置会返回 false；只要求展示前确实是菜单栏策略。
        _ = NSApp.setActivationPolicy(.accessory)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        let png = try screenshotFixture(width: 200, height: 2000, color: .white)
        for _ in 0...1 {
            let token = controller.service.id
            let editorsBefore = NSApp.windows.filter { $0 is ScreenshotPanel && $0.isVisible }.count
            // 拼接失败后的交付入口就是这个结果，不能再打开截图编辑器。
            controller.service.publishFinishedScroll(png: png, width: 200, height: 2000, frames: 3,
                failure: "相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。", token: token)
            // 结果发布可以发生在引擎确认前，等待当前状态真正呈现。
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                NSApp.windows.contains { $0.title == "长截图结果" && $0.isVisible }
            }, object: nil)
            await fulfillment(of: [visible], timeout: 6)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "长截图结果" && $0.isVisible })
            XCTAssertEqual(panel.level, .normal)
            XCTAssertTrue(panel.styleMask.contains(.titled))
            XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertEqual(NSApp.activationPolicy(), .regular)
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertTrue(try XCTUnwrap(panel.screen).visibleFrame.contains(panel.frame))
            XCTAssertEqual(NSApp.windows.filter { $0 is ScreenshotPanel && $0.isVisible }.count, editorsBefore)
            XCTAssertEqual(controller.service.phase, .imageReady)
            XCTAssertEqual((controller.service.snapshot()["imageBytes"] as? FlutterStandardTypedData)?.data, png)
            let copied = expectation(description: "复制长图")
            controller.handle(FlutterMethodCall(methodName: AppConstants.copyScreenshotMethod, arguments: ["id": token])) { value in
                XCTAssertFalse(value is FlutterError)
                copied.fulfill()
            }
            await fulfillment(of: [copied], timeout: 3)
            XCTAssertEqual(NSPasteboard.general.data(forType: .png), png)
            let saved = expectation(description: "保存长图")
            var path: String?
            controller.handle(FlutterMethodCall(methodName: AppConstants.saveScreenshotMethod,
                arguments: ["id": token, "name": "长截图.png"])) {
                path = ($0 as? [String: Any])?["savedPath"] as? String
                saved.fulfill()
            }
            await fulfillment(of: [saved], timeout: 3)
            let file = try XCTUnwrap(path)
            XCTAssertTrue(file.hasPrefix(root.appendingPathComponent("截图").path + "/"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), png)
            let ended = expectation(description: "红按钮关闭")
            controller.onActiveChanged = { active in
                if !active && controller.service.id != token { ended.fulfill() }
            }
            try XCTUnwrap(panel.standardWindowButton(.closeButton)).performClick(nil)
            await fulfillment(of: [ended], timeout: 3)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(controller.service.phase, .idle)
            XCTAssertEqual(NSApp.activationPolicy(), .accessory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file))
            controller.onActiveChanged = nil
        }
    }

    /// 无参数；冷启动立即 Esc、首帧后失焦 Esc、引擎复用 Esc 都须关闭且保留剪贴板。
    @MainActor
    func testScreenshotEscapeClosesColdWarmAndReusedEditor() async throws {
        let board = NSPasteboard.withUniqueName()
        let controller = ScreenshotWindowController(pasteboard: board)
        defer { controller.shutdown(); board.releaseGlobally() }
        let png = try screenshotFixture(width: 80, height: 60, color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        for phase in ["cold", "warm", "reused"] {
            board.clearContents()
            board.setString("unchanged", forType: .string)
            controller.seedCaptureForTesting(png: png, id: phase, width: 80, height: 60, showEditor: true)
            // waitForScreenshotEditor 等待入口确认，后续事件针对真实可见窗口。
            _ = try await waitForScreenshotEditor()
            // cold 在入口确认后立即发 Esc；warm 另等待首帧，reused 覆盖同一引擎重开。
            if phase == "warm" { try await Task.sleep(nanoseconds: 500_000_000) }
            let panel = try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
            panel.makeFirstResponder(nil)
            panel.resignKey()
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
            ))
            XCTAssertNil(controller.filterScreenshotEvent(try XCTUnwrap(event.cgEvent)))
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !controller.isCurrentCapture(phase) && !panel.isVisible
            }, object: nil)
            await fulfillment(of: [closed], timeout: 2)
            XCTAssertEqual(board.string(forType: .string), "unchanged")
            XCTAssertNil(board.data(forType: .png))
        }
    }

    /// 无参数；以真实 Flutter 截图引擎复现原生键路由丢失 Return，断言图片像素与生命周期。
    @MainActor
    func testScreenshotReturnCopiesImageAndClosesFromNativeRoute() async throws {
        let board = NSPasteboard.withUniqueName()
        let controller = ScreenshotWindowController(pasteboard: board)
        defer { controller.shutdown(); board.releaseGlobally() }
        let png = try screenshotFixture(width: 80, height: 60, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        // 两个硬件键码分别覆盖主 Return 与小键盘 Enter；每次捕获均经过生产 show 初始化。
        for keyCode: UInt16 in [36, 76] {
            let id = "return-\(keyCode)"
            board.clearContents()
            controller.seedCaptureForTesting(png: png, id: id, width: 80, height: 60, showEditor: true)
            // waitForScreenshotEditor 等待入口确认，后续事件针对真实可见窗口。
            _ = try await waitForScreenshotEditor()
            // 等待真实 Flutter 引擎首帧；这里不以纯 Dart widget 键事件替代原生入口。
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let panel = try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
            // 检查实际引擎装配出的材料，不用 mock 背景声称通过原生玻璃验证。
            var descendants = [try XCTUnwrap(panel.contentView)]
            var glassViews: [NativeGlassView] = []
            while let view = descendants.popLast() {
                if let glass = view as? NativeGlassView { glassViews.append(glass) }
                descendants.append(contentsOf: view.subviews)
            }
            XCTAssertFalse(glassViews.isEmpty)
            XCTAssertTrue(glassViews.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })
            // 明确丢开原生键盘焦点，验证非激活截图仍能通过消费式事件路由确认。
            panel.makeFirstResponder(nil)
            panel.resignKey()
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode
            ))
            // nil 是系统不再向来源应用派发该键的实际过滤结果，防止顺带提交聊天或表单。
            XCTAssertNil(controller.filterScreenshotEvent(try XCTUnwrap(event.cgEvent)))
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                board.data(forType: .png) != nil && !controller.isCurrentCapture(id) && !panel.isVisible
            }, object: nil)
            await fulfillment(of: [completed], timeout: 2)
            let copied = try XCTUnwrap(board.data(forType: .png))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: copied))
            XCTAssertEqual(decoded.pixelsWide, 80)
            XCTAssertEqual(decoded.pixelsHigh, 60)
            let color = try XCTUnwrap(decoded.colorAt(x: 40, y: 30)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.redComponent, 0.95)
            XCTAssertLessThan(color.blueComponent, 0.05)
        }
    }

    /// 验证配置快捷键经真实 Flutter 引擎贴图后保留像素、结束截图且不复制或保存；无参数、无返回值。
    @MainActor
    func testScreenshotPinShortcutPreservesImageAndClosesWithoutCopyOrSave() async throws {
        let defaults = UserDefaults.standard
        let previousPreferences = defaults.object(forKey: AppConstants.preferencesKey)
        let previousDirectory = defaults.object(forKey: AppConstants.screenshotSaveDirectoryKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenshotPin-01a17aec-c9a5-72f3-b897-aa5e2c2e720d-\(UUID().uuidString)", isDirectory: true
        )
        let board = NSPasteboard.withUniqueName()
        let controller = ScreenshotWindowController(pasteboard: board)
        defer {
            // 释放真实截图引擎与独立贴图，恢复偏好并清理本用例的隔离资源。
            controller.shutdown()
            board.releaseGlobally()
            if let previousPreferences { defaults.set(previousPreferences, forKey: AppConstants.preferencesKey) }
            else { defaults.removeObject(forKey: AppConstants.preferencesKey) }
            if let previousDirectory { defaults.set(previousDirectory, forKey: AppConstants.screenshotSaveDirectoryKey) }
            else { defaults.removeObject(forKey: AppConstants.screenshotSaveDirectoryKey) }
            try? FileManager.default.removeItem(at: root)
        }
        var preferences = previousPreferences as? [String: Any] ?? [:]
        // 112/8 对应逻辑字符 p 与 Command；35 是 ANSI P，覆盖用户配置到原生事件的映射。
        preferences[AppConstants.screenshotToolbarShortcutsKey] = ["screenshot-pin": ["keyId": 112, "modifiers": 8]]
        defaults.set(preferences, forKey: AppConstants.preferencesKey)
        defaults.set(root.path, forKey: AppConstants.screenshotSaveDirectoryKey)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("existing.bin")
        let savedContents = Data([0, 1, 2, 255])
        try savedContents.write(to: sentinel)
        let existingFiles = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let clipboardImage = try screenshotFixture(width: 2, height: 3, color: .blue)
        XCTAssertTrue(board.setData(clipboardImage, forType: .png))
        XCTAssertTrue(board.setString("clipboard stays unchanged", forType: .string))
        let clipboardChangeCount = board.changeCount
        let png = try screenshotFixture(width: 80, height: 60, color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        let id = "pin-shortcut"
        // seedCaptureForTesting 启动生产截图编辑窗与真实 Dart 引擎，不直接调用贴图或关闭方法。
        controller.seedCaptureForTesting(png: png, id: id, width: 80, height: 60, showEditor: true)
        // waitForScreenshotEditor 等待入口确认，后续事件针对真实可见窗口。
        _ = try await waitForScreenshotEditor()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is ScreenshotPanel && $0.isVisible })
        // isCurrentCapture 确认快捷键前会话有效，贴图必须由本次操作创建。
        XCTAssertTrue(controller.isCurrentCapture(id))
        XCTAssertEqual(controller.pins.count, 0)
        panel.makeFirstResponder(nil)
        panel.resignKey()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "p",
            charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35
        ))
        // filterScreenshotEvent 消费原生配置键，再由 Dart 完成合成、贴图及关闭会话。
        XCTAssertNil(controller.filterScreenshotEvent(try XCTUnwrap(event.cgEvent)))
        // isCurrentCapture 检查身份已失效；仅隐藏编辑窗或仅创建贴图都不足以完成此操作。
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.pins.count == 1 && !controller.isCurrentCapture(id) && !panel.isVisible
        }, object: nil)
        await fulfillment(of: [completed], timeout: 2)
        let pin = try XCTUnwrap(controller.pins.firstPanel)
        XCTAssertTrue(pin.isVisible)
        let decoded = try XCTUnwrap(pin.imageViewForTesting.image?.representations.first as? NSBitmapImageRep)
        // 非正方形尺寸检测裁切与宽高交换；四角及中心检测边界丢失、空白或颜色变化。
        XCTAssertEqual(decoded.pixelsWide, 80)
        XCTAssertEqual(decoded.pixelsHigh, 60)
        let original = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(try XCTUnwrap(decoded.colorSpace.iccProfileData),
                       try XCTUnwrap(original.colorSpace.iccProfileData))
        // PNG 色彩配置保持一致后逐点读取原始通道，避免 NSColor 转换改变采样数值。
        // 原生解码按实际采样位深表示满量程；纯红和全不透明必须精确到该位深的最大值。
        let fullChannel = (1 << decoded.bitsPerSample) - 1
        for (x, y) in [(0, 0), (79, 0), (0, 59), (79, 59), (40, 30)] {
            var samples = [Int](repeating: 0, count: decoded.samplesPerPixel)
            decoded.getPixel(&samples, atX: x, y: y)
            XCTAssertEqual(samples, [fullChannel, 0, 0, fullChannel])
        }
        XCTAssertFalse(panel.isVisible)
        // isCurrentCapture 核对最终身份，不能用测试主动关闭编辑窗来制造通过条件。
        XCTAssertFalse(controller.isCurrentCapture(id))
        XCTAssertEqual(board.changeCount, clipboardChangeCount)
        XCTAssertEqual(board.data(forType: .png), clipboardImage)
        XCTAssertEqual(board.string(forType: .string), "clipboard stays unchanged")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), existingFiles)
        XCTAssertEqual(try Data(contentsOf: sentinel), savedContents)
    }


    /// 无参数；成功读取保留段落并恢复原内容；取消先于新写入、读取期间用户写入时保留用户的新内容；
    /// 复制结果不属于选区时剪贴板仍是本次复制的结果，还原为复制前的内容（#117）。
    @MainActor
    func testCopyReadPreservesClipboardAfterCancellation() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let selection = "First paragraph.\n\nSecond paragraph."
        board.setString("original clipboard", forType: .string)
        let copied = await AccessibilitySelection.readByCopyingSelection(pasteboard: board, copy: {
            board.clearContents()
            board.setString(selection, forType: .string)
        }, accepts: { $0 == selection })
        XCTAssertEqual(copied, selection)
        XCTAssertEqual(board.string(forType: .string), "original clipboard")

        let requested = expectation(description: "copy requested")
        let pending = Task {
            await AccessibilitySelection.readByCopyingSelection(
                pasteboard: board, copy: { requested.fulfill() }, accepts: { $0 == selection }
            )
        }
        await fulfillment(of: [requested], timeout: 1)
        // 取消先于新剪贴板写入，确保旧任务的恢复操作不能覆盖新的用户结果。
        pending.cancel()
        board.clearContents()
        board.setString("new user clipboard", forType: .string)
        let cancelled = await pending.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(board.string(forType: .string), "new user clipboard")

        // 复制结果不属于选区：不采用，剪贴板还原为复制前的内容（#117）。
        let unrelated = await AccessibilitySelection.readByCopyingSelection(pasteboard: board, copy: {
            board.clearContents()
            board.setString("not the selection", forType: .string)
        }, accepts: { $0 == selection })
        XCTAssertNil(unrelated)
        XCTAssertEqual(board.string(forType: .string), "new user clipboard")

        // 边界：读取期间（确认文本时）用户又复制了新内容，changeCount 再变，不还原也不采用。
        let overtaken = await AccessibilitySelection.readByCopyingSelection(pasteboard: board, copy: {
            board.clearContents()
            board.setString(selection, forType: .string)
        }, accepts: { _ in
            board.clearContents()
            board.setString("copied while reading", forType: .string)
            return true
        })
        XCTAssertNil(overtaken)
        XCTAssertEqual(board.string(forType: .string), "copied while reading")
    }

    /// 无参数；来源的浮动窗口重新置前时，触发态与结果态都不能被覆盖，且不取得焦点。
    @MainActor
    func testOverlayStaysAboveReorderedFloatingSource() throws {
        let source = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        source.level = .floating
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let overlay = OverlayPanelController()
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is TranslationPanel && !existing.contains(ObjectIdentifier($0)) })
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        defer { overlay.hide(sessionId: "stacking"); source.orderOut(nil) }
        for size in [NSSize(width: 84, height: 36), NSSize(width: 380, height: 360)] {
            overlay.show(at: NSPoint(x: 250, y: 450), size: size, sessionId: "stacking")
            // 模拟来源 App 在点击、重绘后重新置前；检查窗口服务器真实前后顺序。
            source.orderFrontRegardless()
            let windows = try XCTUnwrap(NSWindow.windowNumbers(options: .allApplications))
            let overlayIndex = try XCTUnwrap(windows.firstIndex(of: NSNumber(value: panel.windowNumber)))
            let sourceIndex = try XCTUnwrap(windows.firstIndex(of: NSNumber(value: source.windowNumber)))
            XCTAssertLessThan(overlayIndex, sourceIndex, "翻译浮层被来源浮动窗口覆盖")
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, sourcePID)
        }
    }

    /// 无参数；附属窗口请求先交本地处理，本地未实现的方法转到主引擎并返回主引擎的结果（#120）。
    /// 边界：vocabularyList 只在主引擎处理，得到假主引擎的回复；systemStatus 由本地返回权限状态，不得到主引擎回复。
    @MainActor
    func testWindowRequestsRouteLocalFirstThenToApplication() throws {
        /// 假主引擎：对每次方法调用回复字符串 "from-main"。
        final class Messenger: NSObject, FlutterBinaryMessenger {
            func send(onChannel channel: String, message: Data?) {}
            func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
                callback?(FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope("from-main"))
            }
            func setMessageHandlerOnChannel(_ channel: String,
                                            binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 0 }
            func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
        }
        let previous = MacPlatformBridge.Shared.instance
        defer { MacPlatformBridge.Shared.instance = previous }
        let bridge = MacPlatformBridge.register(with: Messenger(), overlay: OverlayPanelController(),
                                                selectionMonitor: SelectionMonitor())
        var forwarded: Any?
        bridge.routeWindowRequest(FlutterMethodCall(methodName: AppConstants.vocabularyListMethod, arguments: nil)) {
            forwarded = $0
        }
        XCTAssertEqual(forwarded as? String, "from-main")
        var local: Any?
        bridge.routeWindowRequest(FlutterMethodCall(methodName: AppConstants.systemStatusMethod, arguments: nil)) {
            local = $0
        }
        XCTAssertNotNil((local as? [String: Any])?["accessibility"])
    }


    /// 无参数；真实 Keychain 往返与失败回滚，UUID 隔离用户凭据，空字典与不存在是两个边界。
    @MainActor
    func testCredentialsRoundTripAndSettingsRollback() throws {
        let id = "test-\(UUID().uuidString)"
        defer { try? MacPlatformBridge.storeCredentials(id: id, value: nil) }
        XCTAssertNil(try MacPlatformBridge.readCredentials(id: id))
        try MacPlatformBridge.storeCredentials(id: id, value: ["apiKey": "first"])
        XCTAssertEqual(try MacPlatformBridge.readCredentials(id: id), ["apiKey": "first"])
        try MacPlatformBridge.storeCredentials(id: id, value: ["apiKey": "second", "appId": "dummy"])
        XCTAssertEqual(try MacPlatformBridge.readCredentials(id: id), ["apiKey": "second", "appId": "dummy"])

        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        let preferences = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey)
        let settings: [String: Any] = [
            AppConstants.automaticKey: false, AppConstants.shortcutKeyCodeKey: 128, AppConstants.shortcutModifiersKey: 6144,
            AppConstants.inputShortcutKeyCodeKey: 15, AppConstants.inputShortcutModifiersKey: 6144,
            AppConstants.screenshotShortcutKeyCodeKey: 1, AppConstants.screenshotShortcutModifiersKey: 6144,
            AppConstants.excludedAppsKey: [String: String](),
            AppConstants.launchAtLoginKey: [.enabled, .requiresApproval].contains(SMAppService.mainApp.status),
        ]
        // 无效 keyCode 在系统配置步骤失败，验证已写凭据会恢复，而非只检查方法调用。
        for prior in [["apiKey": "original"], [:]] {
            try MacPlatformBridge.storeCredentials(id: id, value: prior)
            var response: Any?
            bridge.handle(FlutterMethodCall(methodName: AppConstants.applySettingsMethod, arguments: [
                "settings": settings, "credentials": [id: ["apiKey": "replacement"]],
            ])) { response = $0 }
            XCTAssertNotNil(response as? FlutterError)
            XCTAssertEqual(try MacPlatformBridge.readCredentials(id: id), prior)
        }
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) as NSDictionary?, preferences as NSDictionary?)
        try MacPlatformBridge.storeCredentials(id: id, value: nil)
        XCTAssertNil(try MacPlatformBridge.readCredentials(id: id))
        bridge.handle(FlutterMethodCall(methodName: AppConstants.applySettingsMethod, arguments: [
            "settings": settings, "credentials": [id: ["apiKey": "temporary"]],
        ])) { XCTAssertNotNil($0 as? FlutterError) }
        XCTAssertNil(try MacPlatformBridge.readCredentials(id: id))
    }


    /// 无参数；另一进程独占 Carbon 组合时，保存必须失败且保留旧设置；普通注册不在系统可检测范围。
    @MainActor
    func testHotKeyConflictAcrossProcesses() throws {
        let child = Process()
        let output = Pipe()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        child.arguments = ["-e", """
        import AppKit
        import Carbon
        let app = NSApplication.shared
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(9, 6912, EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        print(status)
        fflush(stdout)
        _ = readLine()
        if let reference { UnregisterEventHotKey(reference) }
        """]
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
            if child.isRunning { child.terminate() }
        }
        let bytes = output.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0")
        let monitor = SelectionMonitor()
        try monitor.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(16, 11, 3))
        XCTAssertThrowsError(try monitor.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(9, 11, 3)))
        XCTAssertTrue(monitor.automatic)
    }

    /// 无参数；真实 Carbon 注册冲突必须保留旧热键及自动按钮状态，无返回值。
    @MainActor
    func testHotKeyConflictPreservesPreviousConfiguration() throws {
        let first = SelectionMonitor()
        let second = SelectionMonitor()
        let probe = SelectionMonitor()
        // 四个修饰键用于避免占用用户常用组合；同一组合是系统冲突边界。
        try first.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(7, 6, 3))
        try first.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(7, 6, 3))
        XCTAssertTrue(first.automatic)
        // 三种用途轮换不是系统冲突，已有注册应被复用且返回成功。
        try first.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(3, 7, 6))
        try second.configure(automatic: true, excludedApps: [], shortcuts: hotKeys(16, 13, 4))
        XCTAssertThrowsError(try second.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(7, 13, 4)))
        XCTAssertTrue(second.automatic)
        XCTAssertThrowsError(try probe.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(16, 14, 5)))
        // 同一配置内两种用途相同在注册前即被拒绝，原配置保持不变。
        XCTAssertThrowsError(try second.configure(automatic: false, excludedApps: [], shortcuts: hotKeys(17, 17, 4)))
        XCTAssertTrue(second.automatic)
        withExtendedLifetime((first, second, probe)) {}
    }

    /// translate/input/screenshot 为三种用途的键码，修饰键统一为四个修饰键以避开用户常用组合（键码 12 即 ⌃⌥⇧⌘Q 为系统快捷键，不可用）；返回 configure 所需的组合表。
    private func hotKeys(_ translate: UInt32, _ input: UInt32, _ screenshot: UInt32) -> [GlobalHotKey: SelectionMonitor.HotKeyBinding] {
        [
            .translate: SelectionMonitor.HotKeyBinding(keyCode: translate, modifiers: 6912),
            .input: SelectionMonitor.HotKeyBinding(keyCode: input, modifiers: 6912),
            .screenshot: SelectionMonitor.HotKeyBinding(keyCode: screenshot, modifiers: 6912),
        ]
    }

    /// 无参数；输入翻译粘贴后还原原剪贴板，用户在等待期间新复制的内容不被覆盖，无返回值。
    @MainActor
    func testPasteReplacingSelectionRestoresClipboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("translateapp-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("原剪贴板", forType: .string)
        // 边界一：来源应用读取到的是译文，等待结束后剪贴板回到原内容。
        var pasted: String?
        let sent = await AccessibilitySelection.pasteReplacingSelection("译文", pasteboard: pasteboard) {
            pasted = pasteboard.string(forType: .string)
        }
        XCTAssertTrue(sent)
        XCTAssertEqual(pasted, "译文")
        XCTAssertEqual(pasteboard.string(forType: .string), "原剪贴板")
        // 边界二：等待期间剪贴板被用户改写，不能用旧快照覆盖用户的新内容。
        _ = await AccessibilitySelection.pasteReplacingSelection("译文", pasteboard: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString("用户新复制", forType: .string)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "用户新复制")
    }

    /// 无参数；词典查询与保存文本文件缺少参数时直接返回参数错误，不打开保存面板，无返回值。
    @MainActor
    func testDictionaryAndSaveFileRejectMissingArguments() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var codes: [String?] = []
        // 边界：查词缺 text；保存缺 suggestedName。
        bridge.handle(FlutterMethodCall(methodName: AppConstants.lookupDefinitionMethod, arguments: [:])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.saveTextFileMethod, arguments: ["text": "a"])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        XCTAssertEqual(codes, [AppConstants.badArgsError, AppConstants.badArgsError])
    }

    /// 无参数；截图历史的文件操作缺路径时返回参数错误，图片不可读时返回复制失败且不改剪贴板，无返回值（#29）。
    @MainActor
    func testScreenshotHistoryFileActionsRejectMissingOrUnreadableFiles() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var codes: [String?] = []
        // 边界：三种文件操作都缺 path；复制指向已不存在的文件（图片被用户移走后的状态）。
        for method in [AppConstants.openFileMethod, AppConstants.revealFileMethod, AppConstants.copyImageFileMethod] {
            bridge.handle(FlutterMethodCall(methodName: method, arguments: [:])) {
                codes.append(($0 as? FlutterError)?.code)
            }
        }
        let changeCount = NSPasteboard.general.changeCount
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png").path
        bridge.handle(FlutterMethodCall(methodName: AppConstants.copyImageFileMethod, arguments: ["path": missing])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        XCTAssertEqual(codes, Array(repeating: AppConstants.badArgsError, count: 3) + [AppConstants.copyFailedError])
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    /// 无参数；两种冻结目标给出的初始选区：指针屏为前台窗口建议且不选中，指定显示器为整屏并选中，无返回值（#105）。
    func testScreenshotTargetInitialSelection() {
        let frame = ScreenCaptureService.FreezeFrame(
            displayID: 7, scale: 2, png: Data(), pixelWidth: 200, pixelHeight: 100,
            displayFrame: NSRect(x: 0, y: 0, width: 100, height: 50),
            windowCrop: NSRect(x: 20, y: 10, width: 40, height: 30)
        )
        let pointer = ScreenshotTarget.pointerDisplay.selection(in: frame)
        XCTAssertEqual(pointer.crop, NSRect(x: 20, y: 10, width: 40, height: 30))
        XCTAssertFalse(pointer.selected)
        let display = ScreenshotTarget.display(7).selection(in: frame)
        XCTAssertEqual(display.crop, NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertTrue(display.selected)
        XCTAssertEqual(ScreenshotTarget.display(7).displayID, 7)
        XCTAssertNil(ScreenshotTarget.pointerDisplay.displayID)
    }

    /// 无参数；朗读声音按语言的默认地区补全，系统没有该地区声音时退回语言本身，无返回值。
    func testSpeechVoiceUsesDefaultRegion() {
        // 边界：只给语言码（en）应补全为美式发音；带地区的繁体中文保持地区；阿拉伯语默认地区无声音时仍能取到声音。
        XCTAssertEqual(SpeechService.voice(for: "en")?.language, "en-US")
        XCTAssertEqual(SpeechService.voice(for: "zh-TW")?.language, "zh-TW")
        XCTAssertEqual(SpeechService.voice(for: "ar")?.language.hasPrefix("ar"), true)
    }

    /// 无参数；朗读请求缺少文字或语言时直接返回参数错误，不开始朗读，无返回值。
    @MainActor
    func testToggleSpeechRejectsMissingArguments() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var response: Any?
        bridge.handle(FlutterMethodCall(methodName: AppConstants.toggleSpeechMethod, arguments: ["text": "Hello"])) { response = $0 }
        XCTAssertEqual((response as? FlutterError)?.code, AppConstants.badArgsError)
    }

    /// 无参数；没有对应会话时替换请求返回 false，不向任何应用粘贴，无返回值。
    @MainActor
    func testReplaceSelectionRejectsStaleSession() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var response: Any?
        // 边界：会话已结束（从未创建）是替换前必须拒绝的状态。
        bridge.handle(FlutterMethodCall(methodName: AppConstants.replaceSelectionMethod, arguments: [
            "sessionId": "stale", "text": "译文",
        ])) { response = $0 }
        XCTAssertEqual(response as? Bool, false)
    }

    /// 无参数；从实际应用PID生成并编解码原生事件，验证来源不是Dart测试手工补入的值。
    @MainActor
    func testSelectionSourceSurvivesNativeEventEncoding() throws {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var payload: [String: Any]?
        _ = bridge.onListen(withArguments: nil) { payload = $0 as? [String: Any] }
        defer { _ = bridge.onCancel(withArguments: nil) }
        let apps = [NSRunningApplication.current, try XCTUnwrap(NSWorkspace.shared.frontmostApplication)]
        for app in apps {
            let expected = try XCTUnwrap(app.localizedName)
            XCTAssertFalse(expected.isEmpty)
            bridge.emitSelectionCaptured(text: "fixture", gesture: SelectionGesture.hotkey.rawValue,
                                         x: 0, y: 0, sourcePID: app.processIdentifier, sourceAppName: expected)
            let event = try XCTUnwrap(payload)
            let codec = FlutterStandardMessageCodec.sharedInstance()
            let encoded = try XCTUnwrap(codec.encode(event))
            let decoded = try XCTUnwrap(codec.decode(encoded) as? [String: Any])
            XCTAssertEqual(decoded["sourceAppName"] as? String, expected)
            // 捕获后来源进程消失，仍保留采集时的真实应用名，不从已失效PID重查。
            bridge.emitSelectionCaptured(text: "fixture", gesture: SelectionGesture.hotkey.rawValue,
                                         x: 0, y: 0, sourcePID: -1, sourceAppName: expected)
            XCTAssertEqual(payload?["sourceAppName"] as? String, expected)

        }
    }

    /// 无参数；使用真实设备语言识别，确保法语不会被当成英语，无返回值。
    @MainActor
    func testDeviceLanguageDetection() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        bridge.handle(FlutterMethodCall(methodName: AppConstants.detectLanguageMethod, arguments: [
            "text": "Bonjour, cette application permet de traduire le texte sélectionné dans une autre langue sans interrompre votre travail.",
        ])) { value in
            XCTAssertEqual(value as? String, "fr")
        }
    }

    /// 无参数；验证系统翻译错误映射：未安装与语言对不支持各有专用错误码，其余错误为一般翻译失败。
    func testSystemTranslationErrorCodes() {
        // 边界：三种「不支持」都归为同一错误码；框架内部错误与本服务的不完整响应都可重试。
        XCTAssertEqual(SystemTranslationService.errorCode(for: TranslationError.notInstalled),
                       AppConstants.translationNotInstalledError)
        for unsupported in [TranslationError.unsupportedSourceLanguage,
                            TranslationError.unsupportedTargetLanguage,
                            TranslationError.unsupportedLanguagePairing] {
            XCTAssertEqual(SystemTranslationService.errorCode(for: unsupported),
                           AppConstants.translationUnsupportedError)
        }
        XCTAssertEqual(SystemTranslationService.errorCode(for: TranslationError.internalError),
                       AppConstants.translateFailedError)
        XCTAssertEqual(SystemTranslationService.errorCode(for: SystemTranslationService.IncompleteResponse()),
                       AppConstants.translateFailedError)
    }

    /// 无参数；参数缺失或语言对格式错误时平台桥直接返回参数错误，不进入系统翻译。
    @MainActor
    func testSystemTranslationRejectsMalformedArguments() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        var codes: [String?] = []
        // 边界：翻译缺 texts、状态查询的语言对只有一个元素、取消缺 requestId。
        bridge.handle(FlutterMethodCall(methodName: AppConstants.systemTranslateMethod, arguments: [
            "requestId": "r1", "source": "en", "target": "zh-CN", "strategy": AppConstants.systemTranslationHighFidelity,
        ])) { codes.append(($0 as? FlutterError)?.code) }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.systemTranslationStatusMethod, arguments: [
            "pairs": [["en"]],
        ])) { codes.append(($0 as? FlutterError)?.code) }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.cancelSystemTranslationMethod, arguments: [:])) {
            codes.append(($0 as? FlutterError)?.code)
        }
        XCTAssertEqual(codes, Array(repeating: AppConstants.badArgsError, count: 3))
    }
    /// 无参数；验证非激活面板不能成为 key/main，避免点击浮层抢走键盘焦点。
    @MainActor
    func testOverlayPanelDoesNotBecomeKeyOrMain() {
        let panel = TranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 84, height: 36),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    /// 无参数；以实际触发/结果尺寸检查空白顶栏、展开位置和过期窗口指令。
    @MainActor
    func testOverlayContentSizePositionAndStaleCommands() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY + 100)
        let overlay = OverlayPanelController()
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        overlay.show(at: anchor, size: NSSize(width: 84, height: 36), sessionId: "s1")
        XCTAssertEqual(overlay.frame.size, NSSize(width: 84, height: 36))
        XCTAssertTrue(overlay.isPanelVisible)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, sourcePID)

        // 框选期间迟到的显示请求也必须保持隐藏，结束后恢复仍有效的会话。
        overlay.setCaptureHidden(true)
        overlay.show(at: anchor, size: NSSize(width: 84, height: 36), sessionId: "s1")
        XCTAssertFalse(overlay.isPanelVisible)
        overlay.setCaptureHidden(false)
        XCTAssertTrue(overlay.isPanelVisible)
        let top = overlay.frame.maxY
        overlay.resize(sessionId: "s1", size: NSSize(width: 320, height: 220))
        XCTAssertEqual(overlay.frame.maxY, top)
        let resultFrame = overlay.frame
        overlay.resize(sessionId: "old", size: NSSize(width: 900, height: 900))
        overlay.hide(sessionId: "old")
        XCTAssertEqual(overlay.frame, resultFrame)
        XCTAssertTrue(overlay.isPanelVisible)
        overlay.hide(sessionId: "s1")
        XCTAssertFalse(overlay.isPanelVisible)
    }

    /// 无参数；被动失效仅关闭按钮，展开结果保持会话/位置，Escape 后迟到命令不能复活。
    @MainActor
    func testPassiveInvalidationOnlyClosesTriggerAndEscapeClosesResult() {
        for retained in [false, true] {
            let overlay = OverlayPanelController()
            let bridge = MacPlatformBridge(overlay: overlay, selectionMonitor: SelectionMonitor())
            var events: [[String: Any]] = []
            _ = bridge.onListen(withArguments: nil) { events.append($0 as! [String: Any]) }
            bridge.emitSelectionCaptured(text: "Hello", gesture: SelectionGesture.drag.rawValue, x: 300, y: 500, sourcePID: 100, sourceAppName: "Fixture")
            let sessionId = events.last!["sessionId"] as! String
            let show = FlutterMethodCall(methodName: AppConstants.showOverlayMethod, arguments: [
                "sessionId": sessionId, "x": 300.0, "y": 500.0, "width": 720.0, "height": 420.0,
            ])
            bridge.handle(show) { _ in }
            if retained {
                bridge.handle(FlutterMethodCall(methodName: AppConstants.retainOverlayMethod, arguments: ["sessionId": sessionId])) { _ in }
            }
            let frame = overlay.frame
            bridge.sourceApplicationChanged(to: 200)
            bridge.invalidateSelection()
            if retained {
                bridge.emitSelectionCaptured(text: "Ignored", gesture: SelectionGesture.selectAll.rawValue, x: 500, y: 600, sourcePID: 200, sourceAppName: "Other Fixture")
                XCTAssertTrue(overlay.isPanelVisible)
                XCTAssertEqual(overlay.frame, frame)
                XCTAssertTrue(bridge.hasSelection)
                XCTAssertTrue(bridge.retainsResult)
                bridge.invalidateSelection(eventType: AppConstants.escapePressedMethod)
            }
            XCTAssertFalse(overlay.isPanelVisible)
            XCTAssertFalse(bridge.hasSelection)
            XCTAssertFalse(bridge.retainsResult)
            XCTAssertEqual(events.last?["sessionId"] as? String, sessionId)
            bridge.handle(show) { _ in }
            XCTAssertFalse(overlay.isPanelVisible)
        }
    }

    /// 无参数；验证旧会话关闭消息不能关闭新会话，Escape 只结束当前会话。
    @MainActor
    func testReplacementAndEscapeKeepSessionIdentity() {
        let overlay = OverlayPanelController()
        let bridge = MacPlatformBridge(overlay: overlay, selectionMonitor: SelectionMonitor())
        var events: [[String: Any]] = []
        _ = bridge.onListen(withArguments: nil) { events.append($0 as! [String: Any]) }
        bridge.emitSelectionCaptured(text: "first", gesture: SelectionGesture.drag.rawValue, x: 300, y: 500, sourcePID: 100, sourceAppName: "Fixture")
        let oldId = events.last!["sessionId"] as! String
        bridge.handle(FlutterMethodCall(methodName: AppConstants.retainOverlayMethod, arguments: ["sessionId": oldId])) { _ in }
        bridge.emitSelectionCaptured(text: "second", gesture: SelectionGesture.hotkey.rawValue, x: 300, y: 500, sourcePID: 100, sourceAppName: "Fixture")
        let newId = events.last!["sessionId"] as! String
        bridge.handle(FlutterMethodCall(methodName: AppConstants.showOverlayMethod, arguments: [
            "sessionId": newId, "x": 300.0, "y": 500.0, "width": 84.0, "height": 36.0,
        ])) { _ in }
        bridge.handle(FlutterMethodCall(methodName: AppConstants.hideOverlayMethod, arguments: ["sessionId": oldId])) { _ in }
        XCTAssertTrue(overlay.isPanelVisible)
        bridge.invalidateSelection(eventType: AppConstants.escapePressedMethod)
        XCTAssertFalse(overlay.isPanelVisible)
        XCTAssertEqual(events.last?["type"] as? String, AppConstants.escapePressedMethod)
        XCTAssertEqual(events.last?["sessionId"] as? String, newId)
    }

    /// 无参数；键码边界为 A=0、左箭头=123、Home=115，普通输入和复制不能创建选区。
    func testKeyboardSelectionGestures() {
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 0, modifiers: .command), .selectAll)
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 123, modifiers: .shift), .keyboard)
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 123, modifiers: [.shift, .option]), .keyboard)
        XCTAssertEqual(SelectionGesture.keyboardGesture(keyCode: 115, modifiers: [.shift, .command]), .keyboard)
        XCTAssertNil(SelectionGesture.keyboardGesture(keyCode: 0, modifiers: .shift))
        XCTAssertNil(SelectionGesture.keyboardGesture(keyCode: 8, modifiers: .command))
        XCTAssertNil(SelectionGesture.keyboardGesture(keyCode: 123, modifiers: []))
    }

    /// 无参数；文件树叶子不能绕过父级排除，文本域、网页和聊天列表属于有效文本上下文。
    func testTextSelectionContexts() {
        // 自动手势即使没有 AX 文字也不得复制；否则源应用的多选可能被消费。
        for roles in [["AXStaticText", "AXList"], ["AXWebArea"], ["AXTextArea"], []] {
            for hasAXText in [false, true] {
                XCTAssertFalse(TextSelectionContext.shouldCopySelection(
                    ancestorRoles: roles, hasAXText: hasAXText, allowCopy: false
                ))
            }
        }
        for roles in [["AXStaticText", "AXRow", "AXOutline"], ["AXCell", "AXTable"], ["AXBrowser"]] {
            XCTAssertFalse(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles))
            XCTAssertFalse(TextSelectionContext.shouldCopySelection(ancestorRoles: roles, hasAXText: false, allowCopy: true))
            XCTAssertFalse(TextSelectionContext.shouldCopySelection(ancestorRoles: roles, hasAXText: true, allowCopy: true))
        }
        for roles in [["AXTextArea"], ["AXStaticText", "AXWebArea"], ["AXStaticText", "AXList"]] {
            XCTAssertTrue(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles))
            XCTAssertTrue(TextSelectionContext.shouldCopySelection(ancestorRoles: roles, hasAXText: false, allowCopy: true))
        }
        // 网页已有 AX 文字也需保留段落；原生文本框的完整 AX 文字不额外动剪贴板。
        XCTAssertTrue(TextSelectionContext.shouldCopySelection(ancestorRoles: ["AXStaticText", "AXWebArea"], hasAXText: true, allowCopy: true))
        XCTAssertFalse(TextSelectionContext.shouldCopySelection(ancestorRoles: ["AXTextArea"], hasAXText: true, allowCopy: true))
    }

    /// 无参数；在位图上绘制文字后 OCR Markdown 必须读出该词，空图返回空串。
    @MainActor
    func testScreenCaptureOcrReadsDrawnText() async throws {
        let image = NSImage(size: NSSize(width: 200, height: 60))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 200, height: 60))
        let text = "HelloOCR" as NSString
        text.draw(at: NSPoint(x: 8, y: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let recognized = try await ScreenCaptureService.recognizeText(png: png)
        XCTAssertTrue(recognized.contains("HelloOCR"), recognized)
        let blocks = try ScreenCaptureService.recognizeBlocks(png: png)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue((blocks[0]["text"] as? String)?.contains("HelloOCR") == true, String(describing: blocks))
        XCTAssertGreaterThan((blocks[0]["width"] as? Double) ?? 0, 0)
        XCTAssertGreaterThan((blocks[0]["height"] as? Double) ?? 0, 0)
        let blank = NSImage(size: NSSize(width: 8, height: 8))
        blank.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 8, height: 8))
        blank.unlockFocus()
        let blankTiff = try XCTUnwrap(blank.tiffRepresentation)
        let blankBitmap = try XCTUnwrap(NSBitmapImageRep(data: blankTiff))
        let blankPng = try XCTUnwrap(blankBitmap.representation(using: .png, properties: [:]))
        let empty = try await ScreenCaptureService.recognizeText(png: blankPng)
        XCTAssertTrue(empty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// name 为 CoreImage 码生成器名，message 为码内容，scale 为放大倍数；返回逐像素放大的码位图。
    private func generatedCode(_ name: String, message: String, scale: CGFloat) throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: name))
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
    }

    /// 无参数；生成的二维码与 Code128 条码读出原内容并按自上而下排序，并排的相同二维码只保留一个，空白图返回空数组（#108）。
    @MainActor
    func testDetectCodesReadsQRAndBarcodeInPositionOrder() async throws {
        let link = "https://example.com/a?b=1"
        let qr = try generatedCode("CIQRCodeGenerator", message: link, scale: 6)
        let bar = try generatedCode("CICode128BarcodeGenerator", message: "TRANSLATE-108", scale: 2)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 640, height: 520, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 520))
        context.interpolationQuality = .none
        // CG 原点在左下：两个二维码在上半部并排，条码在下方。
        for x in [40, 360] {
            context.draw(qr, in: CGRect(x: x, y: 260, width: qr.width, height: qr.height))
        }
        context.draw(bar, in: CGRect(x: 40, y: 40, width: bar.width, height: bar.height))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let codes = try await ScreenCaptureService.detectCodes(png: png)
        XCTAssertEqual(codes, [
            ["symbology": "qr", "payload": link],
            ["symbology": "code128", "payload": "TRANSLATE-108"],
        ])
        let blank = try screenshotFixture(width: 64, height: 64, color: .white)
        let none = try await ScreenCaptureService.detectCodes(png: blank)
        XCTAssertEqual(none, [])
    }

    /// 无参数；只有带主机名的 http/https 内容可交给浏览器，协议大小写不敏感，其他协议与无协议文字返回 nil（#108）。
    func testScreenshotLinkAcceptsOnlyHttpLinksWithHost() {
        XCTAssertEqual(ScreenshotLink.url(from: "https://example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertNotNil(ScreenshotLink.url(from: "HTTP://EXAMPLE.COM"))
        for raw in ["https://", "example.com", "file:///etc/hosts", "javascript:alert(1)", "tel:10086", ""] {
            XCTAssertNil(ScreenshotLink.url(from: raw), raw)
        }
    }

    /// directory 为临时目录，name 为文件名，width/height/color 为纯色 PNG 参数；写入文件并返回路径（#109）。
    @MainActor
    private func composerFixture(_ directory: URL, _ name: String, width: Int, height: Int, color: NSColor) throws -> String {
        let url = directory.appendingPathComponent(name)
        try screenshotFixture(width: width, height: height, color: color).write(to: url)
        return url.path
    }

    /// png 为图片字节，x/y 为左上原点的像素坐标；返回文件中存储的原始 RGBA 样本（不做色彩空间转换）。
    private func composedPixel(_ png: Data, _ x: Int, _ y: Int) throws -> [Int] {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        var samples = [Int](repeating: 0, count: rep.samplesPerPixel)
        rep.getPixel(&samples, atX: x, y: y)
        return samples
    }

    /// 无参数；拼接保持原始像素、短边居中且空白透明，拆分余数并入最后一段、高度之和不变，比较计入尺寸差（#109）。
    @MainActor
    func testScreenshotComposerStitchSplitAndCompare() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        let wide = try composerFixture(directory, "wide.png", width: 40, height: 20, color: red)
        let small = try composerFixture(directory, "small.png", width: 20, height: 10, color: blue)

        // 边界：纵向 40×30，蓝图在 x 10–29、y 20–29；两侧空白透明。
        let vertical = try ScreenshotComposer.stitch(paths: [wide, small], vertical: true)
        let verticalRep = try XCTUnwrap(NSBitmapImageRep(data: vertical))
        XCTAssertEqual([verticalRep.pixelsWide, verticalRep.pixelsHigh], [40, 30])
        XCTAssertEqual(try composedPixel(vertical, 39, 19), [255, 0, 0, 255])
        XCTAssertEqual(try composedPixel(vertical, 10, 20), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(vertical, 29, 29), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(vertical, 9, 25)[3], 0)
        XCTAssertEqual(try composedPixel(vertical, 30, 25)[3], 0)
        // 边界：横向 60×20，蓝图在 x 40–59、y 5–14。
        let horizontal = try ScreenshotComposer.stitch(paths: [wide, small], vertical: false)
        let horizontalRep = try XCTUnwrap(NSBitmapImageRep(data: horizontal))
        XCTAssertEqual([horizontalRep.pixelsWide, horizontalRep.pixelsHigh], [60, 20])
        XCTAssertEqual(try composedPixel(horizontal, 40, 5), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(horizontal, 59, 14), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(horizontal, 45, 4)[3], 0)
        XCTAssertEqual(try composedPixel(horizontal, 45, 15)[3], 0)

        // 边界：20×50（上 20 行红、下 30 行蓝）分 3 段为 16、16、18；第二段第 4 行起变蓝。
        let tall = try composerFixture(directory, "tall-top.png", width: 20, height: 20, color: red)
        let tallBottom = try composerFixture(directory, "tall-bottom.png", width: 20, height: 30, color: blue)
        let column = directory.appendingPathComponent("column.png")
        try ScreenshotComposer.stitch(paths: [tall, tallBottom], vertical: true).write(to: column)
        let pieces = try ScreenshotComposer.split(path: column.path, parts: 3)
        XCTAssertEqual(try pieces.map { try XCTUnwrap(NSBitmapImageRep(data: $0)).pixelsHigh }, [16, 16, 18])
        XCTAssertEqual(try composedPixel(pieces[1], 0, 3), [255, 0, 0, 255])
        XCTAssertEqual(try composedPixel(pieces[1], 0, 4), [0, 0, 255, 255])
        XCTAssertEqual(try composedPixel(pieces[2], 19, 17), [0, 0, 255, 255])
        let line = try composerFixture(directory, "line.png", width: 4, height: 1, color: red)
        XCTAssertThrowsError(try ScreenshotComposer.split(path: line, parts: 2))
        XCTAssertThrowsError(try ScreenshotComposer.split(path: column.path, parts: 11))
        XCTAssertThrowsError(try ScreenshotComposer.stitch(paths: [wide, directory.appendingPathComponent("missing.png").path], vertical: true))

        // 边界：同图差异 0；40×20 红与 40×30 红只差多出的 10 行；红与蓝全部不同；蒙版在差异处为 60% 红色。
        let same = try ScreenshotComposer.compare(first: wide, second: wide)
        XCTAssertEqual([same.different, same.total], [0, 800])
        let taller = try composerFixture(directory, "taller.png", width: 40, height: 30, color: red)
        let grown = try ScreenshotComposer.compare(first: wide, second: taller)
        XCTAssertEqual([grown.different, grown.total], [400, 1200])
        XCTAssertEqual(try composedPixel(grown.mask, 0, 0)[3], 0)
        XCTAssertEqual(try composedPixel(grown.mask, 0, 25)[3], 153)
        let recolored = try composerFixture(directory, "blue.png", width: 40, height: 20, color: blue)
        XCTAssertEqual(try ScreenshotComposer.compare(first: wide, second: recolored).different, 800)
    }

    /// 无参数；本进程已有录屏授权时 requestAccess 必须立刻 true，不再走申请框。
    @MainActor
    func testRequestAccessReusesExistingGrant() async throws {
        guard ScreenCaptureService.isAuthorized() else {
            throw XCTSkip("测试进程没有屏幕录制授权，无法断言复用路径。")
        }
        let granted = await ScreenCaptureService.requestAccess()
        XCTAssertTrue(granted)
    }

    /// 无参数；快照暴露 screenAccess；无捕获时 requestScreenAccess 仍返回该键，不进入编辑图像。
    @MainActor
    func testScreenshotSnapshotReportsScreenAccessWithoutCaptureBytes() throws {
        let controller = ScreenshotWindowController()
        defer { controller.shutdown() }
        let snapshotExpectation = expectation(description: AppConstants.getScreenshotMethod)
        var snapshot: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) { value in
            snapshot = value as? [String: Any]
            snapshotExpectation.fulfill()
        }
        wait(for: [snapshotExpectation], timeout: 1)
        let body = try XCTUnwrap(snapshot)
        XCTAssertNotNil(body["screenAccess"] as? Bool)
        XCTAssertNil(body["bytes"])
        XCTAssertNil(body["id"])
    }

    /// 无参数；贴图置顶、不可成为 key/main，关闭不影响其他贴图，且与选区浮层互不销毁。
    @MainActor
    func testPinOverlayStaysIndependentOfSelectionSession() throws {
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let overlay = OverlayPanelController()
        let pins = PinOverlayController()
        defer {
            pins.closeAll()
            overlay.hide(sessionId: "pin-lifecycle")
        }

        // 2×2 的 PNG
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = rep.representation(using: .png, properties: [:])!
        let pinId = pins.pin(png: png, origin: NSPoint(x: 120, y: 180))
        let panel = try XCTUnwrap(pins.firstPanel)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(pins.isVisible(pinId: pinId))

        overlay.show(at: NSPoint(x: 250, y: 450), size: NSSize(width: 84, height: 36), sessionId: "pin-lifecycle")
        // 选区浮层隐藏不应关闭贴图。
        overlay.hide(sessionId: "pin-lifecycle")
        XCTAssertTrue(pins.isVisible(pinId: pinId))
        XCTAssertEqual(pins.count, 1)

        let second = pins.pin(png: png, origin: NSPoint(x: 200, y: 220))
        XCTAssertEqual(pins.count, 2)
        // 关闭贴图窗口本身即用户关闭路径，只移除这一张贴图。
        panel.close()
        XCTAssertFalse(pins.isVisible(pinId: pinId))
        XCTAssertTrue(pins.isVisible(pinId: second))
        XCTAssertEqual(pins.count, 1)

        // 新贴图窗应出现在 NSApp.windows 中。
        let created = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0 is PinPanel }
        XCTAssertFalse(created.isEmpty)

        // 图片层接收首次拖动；右上角没有覆盖控件，Escape只关闭当前贴图。
        let remaining = try XCTUnwrap(pins.firstPanel)
        let image = remaining.imageViewForTesting
        let beforeDrag = image.dragBeginCountForTesting
        let dragEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: image.bounds.midX, y: image.bounds.midY),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: remaining.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        image.mouseDown(with: dragEvent)
        XCTAssertEqual(image.dragBeginCountForTesting, beforeDrag + 1)

        let beforeCloseDrag = image.dragBeginCountForTesting
        XCTAssertEqual(remaining.contentView?.subviews.count, 1)
        remaining.cancelOperation(nil)
        XCTAssertEqual(image.dragBeginCountForTesting, beforeCloseDrag)
        XCTAssertEqual(pins.count, 0)
        XCTAssertFalse(pins.isVisible(pinId: second))
    }

    /// 无参数；走真实 handle(pinScreenshot)：合成 bytes 建贴图，过期 id 拒绝，用户关闭生效。
    @MainActor
    func testScreenshotPinExportUsesPayloadBytesAndRejectsStaleId() throws {
        let controller = ScreenshotWindowController()
        defer { controller.shutdown() }

        func png(width: Int, height: Int, color: NSColor) throws -> Data {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            for x in 0..<width {
                for y in 0..<height {
                    rep.setColor(color, atX: x, y: y)
                }
            }
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }

        // 原图 8×8；合成图 64×16。断言贴图 NSImage 像素尺寸，不依赖窗口 clamp 后的 frame。
        let originalPng = try png(width: 8, height: 8, color: .red)
        controller.seedCaptureForTesting(png: originalPng, id: "capture-1", width: 8, height: 8)
        let editedPng = try png(width: 64, height: 16, color: .blue)

        var pinResult: Any?
        let pinExpectation = expectation(description: AppConstants.pinScreenshotMethod)
        controller.handle(
            FlutterMethodCall(
                methodName: AppConstants.pinScreenshotMethod,
                arguments: [
                    "id": "capture-1",
                    "bytes": FlutterStandardTypedData(bytes: editedPng),
                    "x": 40.0,
                    "y": 80.0,
                ]
            )
        ) { value in
            pinResult = value
            pinExpectation.fulfill()
        }
        wait(for: [pinExpectation], timeout: 1)
        let pinId = try XCTUnwrap(pinResult as? String)
        XCTAssertEqual(controller.pins.count, 1)
        let panel = try XCTUnwrap(controller.pins.firstPanel)
        let pixels = panel.pinnedImagePixelSizeForTesting
        XCTAssertEqual(Int(pixels.width), 64)
        XCTAssertEqual(Int(pixels.height), 16)

        var staleResult: Any?
        let staleExpectation = expectation(description: "stale pin")
        controller.handle(
            FlutterMethodCall(
                methodName: AppConstants.pinScreenshotMethod,
                arguments: [
                    "id": "not-current",
                    "bytes": FlutterStandardTypedData(bytes: editedPng),
                ]
            )
        ) { value in
            staleResult = value
            staleExpectation.fulfill()
        }
        wait(for: [staleExpectation], timeout: 1)
        let staleError = try XCTUnwrap(staleResult as? FlutterError)
        XCTAssertEqual(staleError.code, AppConstants.staleCaptureError)
        XCTAssertEqual(controller.pins.count, 1)

        // 用户关闭入口销毁贴图，不经由 shutdown。
        panel.closeFromUserAction()
        XCTAssertEqual(controller.pins.count, 0)
        XCTAssertFalse(controller.pins.isVisible(pinId: pinId))
    }

    /// 无参数；选中贴图后 Esc（keyCode 53）只关这一张，另一张仍在。
    @MainActor
    func testSelectedPinClosesOnEscape() throws {
        let pins = PinOverlayController()
        defer { pins.closeAll() }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let firstId = pins.pin(png: png, origin: NSPoint(x: 80, y: 80))
        let firstPanel = try XCTUnwrap(pins.firstPanel)
        let secondId = pins.pin(png: png, origin: NSPoint(x: 160, y: 160))
        XCTAssertEqual(pins.count, 2)
        XCTAssertTrue(firstPanel.canBecomeKey)
        // 尚未激活的贴图也必须接收第一次点击，不能先丢弃鼠标以激活应用。
        XCTAssertTrue(firstPanel.imageViewForTesting.acceptsFirstMouse(for: nil))

        let esc = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: firstPanel.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        firstPanel.keyDown(with: esc)
        XCTAssertFalse(pins.isVisible(pinId: firstId))
        XCTAssertTrue(pins.isVisible(pinId: secondId))
        XCTAssertEqual(pins.count, 1)
    }

    /// 无参数；窗口矩形映射到冻结帧像素，不相交时返回 nil。
    func testFrontmostWindowPixelCropMapsAppKitRectIntoImagePixels() {
        let display = NSRect(x: 0, y: 0, width: 100, height: 80)
        let window = NSRect(x: 10, y: 10, width: 40, height: 40)
        let crop = CaptureGeometry.pixelCrop(
            window: window,
            displayFrame: display,
            pixelWidth: 200,
            pixelHeight: 160
        )
        XCTAssertEqual(crop?.origin.x ?? -1, 20, accuracy: 0.01)
        XCTAssertEqual(crop?.origin.y ?? -1, 60, accuracy: 0.01)
        XCTAssertEqual(crop?.width ?? -1, 80, accuracy: 0.01)
        XCTAssertEqual(crop?.height ?? -1, 80, accuracy: 0.01)
        XCTAssertNil(
            CaptureGeometry.pixelCrop(
                window: NSRect(x: 400, y: 400, width: 10, height: 10),
                displayFrame: display,
                pixelWidth: 200,
                pixelHeight: 100
            )
        )
    }

}

/// 用真实 Dart 入口验证启动终态和窗口生命周期，不依赖 engine.run 的布尔值。
final class WindowStartupTests: XCTestCase {
    /// entrypoint 为编译后的窗口入口；返回回调交付的资源或启动失败 nil，句柄保留到回调完成。
    @MainActor
    private func start(_ entrypoint: String) async -> WindowEngine.Started? {
        var pending: WindowEngine.Startup?
        let resources = await withCheckedContinuation { continuation in
            pending = WindowEngine.start(name: "startup-test-\(UUID().uuidString)", entrypoint: entrypoint,
                channel: AppConstants.settingsChannel, handler: { _, reply in reply(nil) }) { started in
                    continuation.resume(returning: started)
                }
        }
        withExtendedLifetime(pending) {}
        return resources
    }

    /// 无参数；五个正式入口都必须确认就绪，绑定控制器但不创建窗口，证明确认不依赖首帧；无返回值。
    @MainActor
    func testAllWindowEntrypointsAcknowledgeWithoutAWindow() async throws {
        for entrypoint in [AppConstants.settingsEntrypoint, AppConstants.permissionWizardEntrypoint,
                           AppConstants.historyEntrypoint, AppConstants.screenshotEntrypoint,
                           AppConstants.captureEntrypoint] {
            // start 使用真实入口和二进制消息通道；计时包含创建、排队及确认，不等待首帧。
            let begin = ContinuousClock.now
            let outcome = await start(entrypoint)
            let elapsed = (ContinuousClock.now - begin).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            print("WINDOW_STARTUP_MEASURE entrypoint=\(entrypoint) milliseconds=\(milliseconds) ready=\(outcome != nil)")
            let started = try XCTUnwrap(outcome)
            XCTAssertNil(started.flutter.view.window)
            started.channel.setMethodCallHandler(nil)
            started.engine.shutDownEngine()
        }
    }

    /// 无参数；不存在的入口在五秒预算后失败，同一进程随后能运行合法入口；无返回值。
    @MainActor
    func testMissingEntrypointFailsAndNextStartupSucceeds() async throws {
        let clock = ContinuousClock.now
        let failed = await start("missingWindowStartupTestEntrypoint")
        XCTAssertNil(failed)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - clock, .seconds(AppConstants.windowStartupTimeout))
        let outcome = await start(AppConstants.settingsEntrypoint)
        let retry = try XCTUnwrap(outcome)
        retry.channel.setMethodCallHandler(nil)
        retry.engine.shutDownEngine()
    }

    /// 无参数；排队前取消和运行后取消均不能交付，等待超过确认预算覆盖迟到终态；无返回值。
    @MainActor
    func testCancellationBeforeRunAndDuringStartupDoesNotDeliver() async throws {
        let cancelled = expectation(description: "取消后不得交付资源或失败")
        cancelled.isInverted = true
        let beforeRun = WindowEngine.start(name: "cancel-before-run", entrypoint: AppConstants.settingsEntrypoint,
            channel: AppConstants.settingsChannel, handler: { _, reply in reply(nil) }) { _ in cancelled.fulfill() }
        beforeRun.cancel()
        let duringRun = WindowEngine.start(name: "cancel-during-run", entrypoint: "missingWindowStartupTestEntrypoint",
            channel: AppConstants.settingsChannel, handler: { _, reply in reply(nil) }) { _ in cancelled.fulfill() }
        // 主队列先运行入口，再撤销仍在等待确认的启动。
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { duringRun.cancel(); continuation.resume() }
        }
        await fulfillment(of: [cancelled], timeout: AppConstants.windowStartupTimeout + 0.2)
        withExtendedLifetime((beforeRun, duringRun)) {}
    }

    /// title 为本次窗口标题；等待可见窗口，返回该窗口；六秒覆盖五秒启动预算，失败由 XCTest 报告。
    @MainActor
    private func visibleWindow(title: String) async throws -> NSWindow {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSApp.windows.contains { $0.title == title && $0.isVisible }
        }, object: nil)
        await fulfillment(of: [visible], timeout: 6)
        return try XCTUnwrap(NSApp.windows.first { $0.title == title && $0.isVisible })
    }

    /// 无参数；设置重复打开只显示一个窗口，关闭后复用同一引擎和窗口；无返回值。
    @MainActor
    func testSettingsMergesPendingOpenAndReusesClosedWindow() async throws {
        let settings = SettingsWindowController()
        settings.show()
        // shutdown 撤销待启动窗口，后续显式打开才创建新的启动。
        settings.shutdown()
        await Task.yield()
        XCTAssertFalse(NSApp.windows.contains { $0.title == "TranslateApp 设置" && $0.isVisible })
        settings.show()
        settings.show()
        let window = try await visibleWindow(title: "TranslateApp 设置")
        let flutter = try XCTUnwrap(window.contentViewController?.children.first as? FlutterViewController)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "TranslateApp 设置" && $0.isVisible }.count, 1)
        window.close()
        XCTAssertFalse(window.isVisible)
        settings.show()
        let reopened = try await visibleWindow(title: "TranslateApp 设置")
        XCTAssertTrue(reopened === window)
        XCTAssertTrue((reopened.contentViewController?.children.first as? FlutterViewController)?.engine === flutter.engine)
        reopened.close()
        withExtendedLifetime(settings) {}
    }

    /// 无参数；附属窗关闭待启动时不迟到显示，重开可成功，已显示窗口关闭后重建引擎；无返回值。
    @MainActor
    func testAuxiliaryCloseCancelsPendingAndReopensWithNewEngine() async throws {
        let title = "startup-lifecycle-test"
        let controller = AuxiliaryWindowController(engineName: "startup-lifecycle", entrypoint: AppConstants.historyEntrypoint,
            title: title, size: NSSize(width: 560, height: 720), refreshMethod: AppConstants.historyChangedMethod)
        defer { controller.close() }
        controller.show()
        controller.show()
        controller.close()
        // 下一轮主队列之后，已取消的启动也不能交付窗口。
        await Task.yield()
        XCTAssertFalse(NSApp.windows.contains { $0.title == title && $0.isVisible })
        controller.show()
        controller.show()
        let window = try await visibleWindow(title: title)
        let flutter = try XCTUnwrap(window.contentViewController?.children.first as? FlutterViewController)
        XCTAssertEqual(NSApp.windows.filter { $0.title == title && $0.isVisible }.count, 1)
        controller.refresh()
        controller.close()
        XCTAssertFalse(window.isVisible)
        controller.show()
        let reopened = try await visibleWindow(title: title)
        let next = try XCTUnwrap(reopened.contentViewController?.children.first as? FlutterViewController)
        XCTAssertFalse(next.engine === flutter.engine)
    }
}
