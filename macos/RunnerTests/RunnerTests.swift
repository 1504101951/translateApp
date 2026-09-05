import Cocoa
import FlutterMacOS
import ServiceManagement
import XCTest

@testable import translate_app

class RunnerTests: XCTestCase {

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
        let preferences = UserDefaults.standard.dictionary(forKey: "preferences")
        let settings: [String: Any] = [
            "automatic": false, "shortcutKeyCode": 128, "shortcutModifiers": 6144,
            "excludedApps": [String: String](),
            "launchAtLogin": [.enabled, .requiresApproval].contains(SMAppService.mainApp.status),
        ]
        // 无效 keyCode 在系统配置步骤失败，验证已写凭据会恢复，而非只检查方法调用。
        for prior in [["apiKey": "original"], [:]] {
            try MacPlatformBridge.storeCredentials(id: id, value: prior)
            var response: Any?
            bridge.handle(FlutterMethodCall(methodName: "applySettings", arguments: [
                "settings": settings, "credentials": [id: ["apiKey": "replacement"]],
            ])) { response = $0 }
            XCTAssertNotNil(response as? FlutterError)
            XCTAssertEqual(try MacPlatformBridge.readCredentials(id: id), prior)
        }
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: "preferences") as NSDictionary?, preferences as NSDictionary?)
        try MacPlatformBridge.storeCredentials(id: id, value: nil)
        XCTAssertNil(try MacPlatformBridge.readCredentials(id: id))
        bridge.handle(FlutterMethodCall(methodName: "applySettings", arguments: [
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
        try monitor.configure(automatic: true, excludedApps: [], keyCode: 16, modifiers: 6912)
        XCTAssertThrowsError(try monitor.configure(automatic: false, excludedApps: [], keyCode: 9, modifiers: 6912))
        XCTAssertTrue(monitor.automatic)
    }

    /// 无参数；真实 Carbon 注册冲突必须保留旧热键及自动按钮状态，无返回值。
    @MainActor
    func testHotKeyConflictPreservesPreviousConfiguration() throws {
        let first = SelectionMonitor()
        let second = SelectionMonitor()
        let probe = SelectionMonitor()
        // 四个修饰键用于避免占用用户常用组合；同一组合是系统冲突边界。
        try first.configure(automatic: false, excludedApps: [], keyCode: 7, modifiers: 6912)
        try first.configure(automatic: true, excludedApps: [], keyCode: 7, modifiers: 6912)
        XCTAssertTrue(first.automatic)
        try second.configure(automatic: true, excludedApps: [], keyCode: 16, modifiers: 6912)
        XCTAssertThrowsError(try second.configure(automatic: false, excludedApps: [], keyCode: 7, modifiers: 6912))
        XCTAssertTrue(second.automatic)
        XCTAssertThrowsError(try probe.configure(automatic: false, excludedApps: [], keyCode: 16, modifiers: 6912))
        withExtendedLifetime((first, second, probe)) {}
    }

    /// 无参数；使用真实设备语言识别，确保法语不会被当成英语，无返回值。
    @MainActor
    func testDeviceLanguageDetection() {
        let bridge = MacPlatformBridge(overlay: OverlayPanelController(), selectionMonitor: SelectionMonitor())
        bridge.handle(FlutterMethodCall(methodName: "detectLanguage", arguments: [
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

    /// 无参数；分别验证触发/结果态切源应用关闭，同 PID 保留，迟到 show 不复活。
    @MainActor
    func testSourceSwitchInvalidatesTriggerAndResultAndDropsLateShow() {
        for size in [NSSize(width: 84, height: 36), NSSize(width: 320, height: 220)] {
            let overlay = OverlayPanelController()
            let bridge = MacPlatformBridge(overlay: overlay, selectionMonitor: SelectionMonitor())
            var events: [[String: Any]] = []
            _ = bridge.onListen(withArguments: nil) { events.append($0 as! [String: Any]) }
            bridge.emitSelectionCaptured(text: "Hello", gesture: "drag", x: 300, y: 500, sourcePID: 100)
            let sessionId = events.last!["sessionId"] as! String
            let show = FlutterMethodCall(methodName: "showOverlay", arguments: [
                "sessionId": sessionId, "x": 300.0, "y": 500.0, "width": Double(size.width), "height": Double(size.height),
            ])
            bridge.handle(show) { _ in }
            bridge.sourceApplicationChanged(to: 100)
            XCTAssertTrue(overlay.isPanelVisible)
            bridge.sourceApplicationChanged(to: 200)
            XCTAssertFalse(overlay.isPanelVisible)
            XCTAssertEqual(events.last?["type"] as? String, "selectionInvalidated")
            XCTAssertEqual(events.last?["sessionId"] as? String, sessionId)
            bridge.handle(show) { _ in }
            XCTAssertFalse(overlay.isPanelVisible)
            XCTAssertFalse(bridge.hasSelection)
        }
    }

    /// 无参数；验证旧会话关闭消息不能关闭新会话，Escape 只结束当前会话。
    @MainActor
    func testReplacementAndEscapeKeepSessionIdentity() {
        let overlay = OverlayPanelController()
        let bridge = MacPlatformBridge(overlay: overlay, selectionMonitor: SelectionMonitor())
        var events: [[String: Any]] = []
        _ = bridge.onListen(withArguments: nil) { events.append($0 as! [String: Any]) }
        bridge.emitSelectionCaptured(text: "first", gesture: "drag", x: 300, y: 500, sourcePID: 100)
        let oldId = events.last!["sessionId"] as! String
        bridge.emitSelectionCaptured(text: "second", gesture: "keyboard", x: 300, y: 500, sourcePID: 100)
        let newId = events.last!["sessionId"] as! String
        bridge.handle(FlutterMethodCall(methodName: "showOverlay", arguments: [
            "sessionId": newId, "x": 300.0, "y": 500.0, "width": 84.0, "height": 36.0,
        ])) { _ in }
        bridge.handle(FlutterMethodCall(methodName: "hideOverlay", arguments: ["sessionId": oldId])) { _ in }
        XCTAssertTrue(overlay.isPanelVisible)
        bridge.invalidateSelection(eventType: "escapePressed")
        XCTAssertFalse(overlay.isPanelVisible)
        XCTAssertEqual(events.last?["type"] as? String, "escapePressed")
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
        for roles in [["AXStaticText", "AXRow", "AXOutline"], ["AXCell", "AXTable"], ["AXBrowser"]] {
            XCTAssertFalse(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles))
            XCTAssertFalse(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles))
        }
        for roles in [["AXTextArea"], ["AXStaticText", "AXWebArea"], ["AXStaticText", "AXList"]] {
            XCTAssertTrue(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles))
            XCTAssertTrue(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles))
        }
    }
}
