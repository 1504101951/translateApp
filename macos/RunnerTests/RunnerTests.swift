import Cocoa
import FlutterMacOS
import ServiceManagement
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

    /// 无参数；从真实截图方法入口验证两类对角原生光标，拒绝未知值并恢复关闭后的箭头。
    @MainActor
    func testScreenshotDiagonalCursorUsesNativeFrameResize() throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown(); NSCursor.arrow.set() }
        let png = try screenshotFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(png: png, id: "diagonal", width: 80, height: 60, showEditor: true)
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
    func testScreenshotConfiguredShortcutConsumesOnlyItsScope() throws {
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
    func testScreenshotKeysPreserveTypingAndTextEditing() throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        defer { controller.shutdown() }
        let png = try screenshotFixture(width: 80, height: 60, color: .white)
        controller.seedCaptureForTesting(png: png, id: "typing", width: 80, height: 60, showEditor: true)
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

    /// 无参数；模拟采集收起冻结层后交付长图，首次及复用引擎都显示普通结果窗且可立即保存PNG。
    @MainActor
    func testLongScreenshotResultWindowShowsAndSavesAfterCapture() async throws {
        let controller = ScreenshotWindowController(pasteboard: NSPasteboard.withUniqueName())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongResult-\(UUID().uuidString)")
        let defaults = UserDefaults.standard
        let oldDirectory = defaults.object(forKey: AppConstants.screenshotSaveDirectoryKey)
        defaults.set(root.path, forKey: AppConstants.screenshotSaveDirectoryKey)
        defer {
            controller.shutdown()
            defaults.set(oldDirectory, forKey: AppConstants.screenshotSaveDirectoryKey)
            try? FileManager.default.removeItem(at: root)
        }
        let png = try screenshotFixture(width: 200, height: 2000, color: .white)
        for cycle in 0...1 {
            controller.seedCaptureForTesting(png: png, id: "selection-\(cycle)", width: 200, height: 2000, showEditor: true)
            controller.closeForCapture()
            // presentImage是采集结束时真正的交接入口；切换窗口不能触发清理而丢掉刚交付的PNG。
            XCTAssertTrue(controller.presentImage(png, width: 200, height: 2000, scale: 2, warning: nil))
            let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "长截图结果" && $0.isVisible })
            XCTAssertEqual(panel.level, .normal)
            XCTAssertTrue(panel.styleMask.contains(.titled))
            XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(try XCTUnwrap(panel.screen).visibleFrame.contains(panel.frame))
            var state: [String: Any] = [:]
            controller.handle(FlutterMethodCall(methodName: AppConstants.getScreenshotMethod, arguments: nil)) {
                state = $0 as? [String: Any] ?? [:]
            }
            let id = try XCTUnwrap(state["id"] as? String)
            XCTAssertEqual((state["bytes"] as? FlutterStandardTypedData)?.data, png)
            XCTAssertEqual(state["canCaptureMedia"] as? Bool, false)
            var saved: Any?
            controller.handle(FlutterMethodCall(methodName: AppConstants.saveScreenshotMethod,
                arguments: ["id": id, "name": "长截图.png", "bytes": FlutterStandardTypedData(bytes: png)])) { saved = $0 }
            let path = try XCTUnwrap(saved as? String)
            XCTAssertTrue(path.hasPrefix(root.appendingPathComponent("截图").path + "/"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
            // 普通结果失焦时不吞掉其他应用按键；红按钮单击关闭，只清理内存中的当前图片。
            panel.resignKey()
            let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
            XCTAssertTrue(controller.filterScreenshotEvent(escape) === escape)
            try XCTUnwrap(panel.standardWindowButton(.closeButton)).performClick(nil)
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(controller.isCurrentCapture(id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
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
            // cold 不让出主线程，直接覆盖窗口显示与 Dart handler 注册的启动交界。
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


    /// 无参数；成功读取保留段落并恢复原内容，取消或非选区文本均须保留用户的新内容。
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

        // 新复制先于取消信号到达时，不属于选区的文本也不能被恢复操作覆盖。
        let unrelated = await AccessibilitySelection.readByCopyingSelection(pasteboard: board, copy: {
            board.clearContents()
            board.setString("another user copy", forType: .string)
        }, accepts: { $0 == selection })
        XCTAssertNil(unrelated)
        XCTAssertEqual(board.string(forType: .string), "another user copy")
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
        try monitor.configure(automatic: true, excludedApps: [], keyCode: 16, modifiers: 6912, screenshotCode: 3, screenshotFlags: 6912)
        XCTAssertThrowsError(try monitor.configure(automatic: false, excludedApps: [], keyCode: 9, modifiers: 6912, screenshotCode: 3, screenshotFlags: 6912))
        XCTAssertTrue(monitor.automatic)
    }

    /// 无参数；真实 Carbon 注册冲突必须保留旧热键及自动按钮状态，无返回值。
    @MainActor
    func testHotKeyConflictPreservesPreviousConfiguration() throws {
        let first = SelectionMonitor()
        let second = SelectionMonitor()
        let probe = SelectionMonitor()
        // 四个修饰键用于避免占用用户常用组合；同一组合是系统冲突边界。
        try first.configure(automatic: false, excludedApps: [], keyCode: 7, modifiers: 6912, screenshotCode: 3, screenshotFlags: 6912)
        try first.configure(automatic: true, excludedApps: [], keyCode: 7, modifiers: 6912, screenshotCode: 3, screenshotFlags: 6912)
        XCTAssertTrue(first.automatic)
        // 两种用途互换不是系统冲突，已有注册应被复用且返回成功。
        try first.configure(automatic: true, excludedApps: [], keyCode: 3, modifiers: 6912, screenshotCode: 7, screenshotFlags: 6912)
        try second.configure(automatic: true, excludedApps: [], keyCode: 16, modifiers: 6912, screenshotCode: 4, screenshotFlags: 6912)
        XCTAssertThrowsError(try second.configure(automatic: false, excludedApps: [], keyCode: 7, modifiers: 6912, screenshotCode: 4, screenshotFlags: 6912))
        XCTAssertTrue(second.automatic)
        XCTAssertThrowsError(try probe.configure(automatic: false, excludedApps: [], keyCode: 16, modifiers: 6912, screenshotCode: 5, screenshotFlags: 6912))
        withExtendedLifetime((first, second, probe)) {}
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

    /// 无参数；在位图上绘制文字后 OCR 必须读出该词，空图返回空串。
    @MainActor
    func testScreenCaptureOcrReadsDrawnText() throws {
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
        let recognized = try ScreenCaptureService.recognizeText(png: png)
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
        let empty = try ScreenCaptureService.recognizeText(png: blankPng)
        XCTAssertTrue(empty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

        // 1x1 PNG
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = rep.representation(using: .png, properties: [:])!
        let pinId = pins.pin(png: png, origin: NSPoint(x: 120, y: 180))
        let panel = try XCTUnwrap(pins.firstPanel)
        XCTAssertTrue(panel is PinPanel)
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
        pins.close(pinId: pinId)
        XCTAssertFalse(pins.isVisible(pinId: pinId))
        XCTAssertTrue(pins.isVisible(pinId: second))
        XCTAssertEqual(pins.count, 1)

        // 新贴图窗应出现在 NSApp.windows 中。
        let created = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0 is PinPanel }
        XCTAssertFalse(created.isEmpty)

        // 图片层接收首次拖动；右上角没有覆盖控件，Escape只关闭当前贴图。
        let remaining = try XCTUnwrap(pins.firstPanel)
        let image = remaining.imageViewForTesting
        XCTAssertTrue(image is DraggablePinImageView)
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
