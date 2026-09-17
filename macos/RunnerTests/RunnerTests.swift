import Cocoa
import FlutterMacOS
import ServiceManagement
import XCTest

@testable import translate_app

class RunnerTests: XCTestCase {

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
        let preferences = UserDefaults.standard.dictionary(forKey: "preferences")
        let settings: [String: Any] = [
            "automatic": false, "shortcutKeyCode": 128, "shortcutModifiers": 6144,
            "screenshotShortcutKeyCode": 1, "screenshotShortcutModifiers": 6144,
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
            bridge.emitSelectionCaptured(text: "Hello", gesture: "drag", x: 300, y: 500, sourcePID: 100)
            let sessionId = events.last!["sessionId"] as! String
            let show = FlutterMethodCall(methodName: "showOverlay", arguments: [
                "sessionId": sessionId, "x": 300.0, "y": 500.0, "width": 720.0, "height": 420.0,
            ])
            bridge.handle(show) { _ in }
            if retained {
                bridge.handle(FlutterMethodCall(methodName: "retainOverlay", arguments: ["sessionId": sessionId])) { _ in }
            }
            let frame = overlay.frame
            bridge.sourceApplicationChanged(to: 200)
            bridge.invalidateSelection()
            if retained {
                bridge.emitSelectionCaptured(text: "Ignored", gesture: "selectAll", x: 500, y: 600, sourcePID: 200)
                XCTAssertTrue(overlay.isPanelVisible)
                XCTAssertEqual(overlay.frame, frame)
                XCTAssertTrue(bridge.hasSelection)
                XCTAssertTrue(bridge.retainsResult)
                bridge.invalidateSelection(eventType: "escapePressed")
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
        bridge.emitSelectionCaptured(text: "first", gesture: "drag", x: 300, y: 500, sourcePID: 100)
        let oldId = events.last!["sessionId"] as! String
        bridge.handle(FlutterMethodCall(methodName: "retainOverlay", arguments: ["sessionId": oldId])) { _ in }
        bridge.emitSelectionCaptured(text: "second", gesture: "hotkey", x: 300, y: 500, sourcePID: 100)
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
        let snapshotExpectation = expectation(description: "getScreenshot")
        var snapshot: [String: Any]?
        controller.handle(FlutterMethodCall(methodName: "getScreenshot", arguments: nil)) { value in
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

        // 图片层必须走 mouseDown→performDrag；关闭按钮不得触发拖动计数。
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
        remaining.closeButtonForTesting.performClick(nil)
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
        let pinExpectation = expectation(description: "pinScreenshot")
        controller.handle(
            FlutterMethodCall(
                methodName: "pinScreenshot",
                arguments: [
                    "id": "capture-1",
                    "bytes": FlutterStandardTypedData(bytes: editedPng),
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
                methodName: "pinScreenshot",
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
        XCTAssertEqual(staleError.code, "stale_capture")
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

}
