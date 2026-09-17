import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// 系统截图模块承接权限与冻结帧；Dart 编辑层负责框选变暗、标注与导出。
final class ScreenshotWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var capturing = false
    private var png: Data?
    private var captureId: String?
    private var capturedAt: Int64 = 0
    private var pixels = NSSize.zero
    private var displayFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    private var message: String?
    /// 贴图与编辑窗分离；关闭编辑不销毁已贴出的图。
    let pins = PinOverlayController()
    var onCapturingChanged: ((Bool) -> Void)?

    /// 无参数；本进程申请权限并捕获指针所在屏冻结帧，无权限不进入编辑。
    func capture() {
        guard !capturing, window?.attachedSheet == nil else { return }
        capturing = true
        onCapturingChanged?(true)
        // 先收起编辑窗，避免冻结帧含工具栏。
        window?.orderOut(nil)
        Task { @MainActor in
            defer {
                self.capturing = false
                self.onCapturingChanged?(false)
            }
            let granted = await ScreenCaptureService.requestAccess()
            guard granted else {
                self.png = nil
                self.captureId = nil
                self.message = "截图需要屏幕录制权限。请在设置中允许 TranslateApp。"
                ScreenCaptureService.openScreenRecordingSettings()
                self.show(compact: true)
                return
            }
            do {
                let frame = try await ScreenCaptureService.captureActiveDisplay()
                self.png = frame.png
                self.captureId = UUID().uuidString
                self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
                self.pixels = NSSize(width: frame.pixelWidth, height: frame.pixelHeight)
                self.displayFrame = frame.displayFrame
                self.message = nil
                self.show(compact: false)
            } catch {
                self.png = nil
                self.captureId = nil
                self.message = error.localizedDescription
                self.show(compact: true)
            }
        }
    }

    /// 无参数；标记取消进行中的捕获；异步任务结束时自行复位 capturing。
    func cancelCapture() {
        onCapturingChanged?(false)
    }

    /// 无参数；关闭编辑窗并关闭引擎，保留已创建的贴图。
    func shutdown() {
        cancelCapture()
        window?.delegate = nil
        window?.close()
        window = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        png = nil
        captureId = nil
        pins.closeAll()
    }

    /// 无参数；返回当前截图和保存目录，PNG 以 typed data 下发。
    private func snapshot() -> [String: Any] {
        var value: [String: Any] = [
            "directory": UserDefaults.standard.string(forKey: "screenshotSaveDirectory") ?? "",
            "screenAccess": ScreenCaptureService.isAuthorized(),
            "capturedAt": capturedAt,
            "width": pixels.width,
            "height": pixels.height,
        ]
        if let png, let captureId {
            value["id"] = captureId
            value["bytes"] = FlutterStandardTypedData(bytes: png)
        }
        if let message { value["error"] = message }
        return value
    }

    /// png/id 为测试注入的捕获态；只用于 RunnerTests 走真实 pinScreenshot 路径。
    func seedCaptureForTesting(png: Data, id: String, width: CGFloat = 1, height: CGFloat = 1) {
        self.png = png
        self.captureId = id
        self.pixels = NSSize(width: width, height: height)
        self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
        self.message = nil
    }

    /// call 为截图操作，result 返回数据/路径或错误；导出优先使用 Dart 合成后的 bytes。
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "getScreenshot":
            result(snapshot())
        case "recognizeBlocks":
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: "stale_capture", message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload: Data
            if let typed = args["bytes"] as? FlutterStandardTypedData {
                payload = typed.data
            } else if let png {
                payload = png
            } else {
                result(FlutterError(code: "stale_capture", message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            do {
                result(try ScreenCaptureService.recognizeBlocks(png: payload))
            } catch {
                result(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil))
            }
        case "recognizeText":
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: "stale_capture", message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload: Data
            if let typed = args["bytes"] as? FlutterStandardTypedData {
                payload = typed.data
            } else if let png {
                payload = png
            } else {
                result(FlutterError(code: "stale_capture", message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            do {
                result(try ScreenCaptureService.recognizeText(png: payload))
            } catch {
                result(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil))
            }
        case "copyText":
            guard let text = args["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: "ocr_empty", message: "没有可复制的文字。", details: nil))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            result(nil)
        case "translatePlainText":
            guard let text = args["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: "ocr_empty", message: "没有可翻译的文字。", details: nil))
                return
            }
            MacPlatformBridge.Shared.instance?.requestSettings(
                "translatePlainText",
                arguments: ["text": text],
                result: result
            )
        case "captureRegion":
            capture(); result(nil)
        case "closeScreenshot":
            window?.close(); result(nil)
        case "requestScreenAccess":
            Task { @MainActor in
                let granted = await ScreenCaptureService.requestAccess()
                if !granted {
                    ScreenCaptureService.openScreenRecordingSettings()
                }
                result(self.snapshot())
            }
        case "copyScreenshot", "saveScreenshot", "pinScreenshot":
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: "stale_capture", message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            // Dart 合成图优先；无 bytes 时回退原始捕获，便于旧调用与测试。
            let payload: Data
            if let typed = args["bytes"] as? FlutterStandardTypedData {
                payload = typed.data
            } else if let png {
                payload = png
            } else {
                result(FlutterError(code: "stale_capture", message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            switch call.method {
            case "copyScreenshot":
                let item = NSPasteboardItem()
                item.setData(payload, forType: .png)
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([item]) else {
                    result(FlutterError(code: "copy_failed", message: "无法复制截图，请重试。", details: nil))
                    return
                }
                result(nil)
            case "saveScreenshot":
                let name = args["name"] as? String ?? "screenshot.png"
                if let directory = UserDefaults.standard.string(forKey: "screenshotSaveDirectory"),
                   args["saveAs"] as? Bool != true {
                    do {
                        let url = try ScreenshotStorage.save(
                            payload,
                            directory: URL(fileURLWithPath: directory),
                            name: name
                        )
                        result(url.path)
                    } catch {
                        result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
                    }
                    return
                }
                guard let window else {
                    result(FlutterError(code: "save_failed", message: "截图窗口已关闭。", details: nil))
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = name
                panel.canCreateDirectories = true
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else {
                        result(nil)
                        return
                    }
                    do {
                        try payload.write(to: url)
                        result(url.path)
                    } catch {
                        result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
                    }
                }
            case "pinScreenshot":
                let origin: NSPoint?
                if let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber {
                    origin = NSPoint(x: x.doubleValue, y: y.doubleValue)
                } else {
                    origin = nil
                }
                let pinId = pins.pin(png: payload, origin: origin)
                result(pinId)
            default:
                result(FlutterMethodNotImplemented)
            }
        case "revealFile":
            guard let path = args["path"] as? String else {
                result(FlutterError(code: "bad_args", message: "缺少文件路径。", details: nil))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            result(nil)
        case "closePin":
            if let pinId = args["id"] as? String {
                pins.close(pinId: pinId)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// compact 为无权限/失败时的小窗；成功时覆盖冻结帧所在显示器。
    private func show(compact: Bool) {
        if engine == nil {
            let engine = FlutterEngine(name: "screenshot", project: nil, allowHeadlessExecution: false)
            self.engine = engine
            let channel = FlutterMethodChannel(
                name: "translateapp/screenshot",
                binaryMessenger: engine.binaryMessenger
            )
            self.channel = channel
            channel.setMethodCallHandler { [weak self] call, result in
                self?.handle(call, result: result)
            }
            let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
            guard engine.run(withEntrypoint: "screenshotMain") else {
                channel.setMethodCallHandler(nil)
                engine.shutDownEngine()
                self.engine = nil
                self.channel = nil
                let alert = NSAlert()
                alert.messageText = "截图预览启动失败"
                alert.informativeText = "请退出并重新打开 TranslateApp。"
                alert.runModal()
                return
            }
            RegisterGeneratedPlugins(registry: flutter)
            // 无边框置顶编辑层覆盖冻结屏；编辑期可成为 key 以接收 Esc/文字。
            let window = ScreenshotPanel(
                contentRect: displayFrame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.onEscape = { [weak self] in
                // Dart 判断文字输入中只取消草稿；否则关闭编辑层。
                self?.channel?.invokeMethod("escapePressed", arguments: nil)
            }
            window.onUndo = { [weak self] in
                self?.channel?.invokeMethod("undoPressed", arguments: nil)
            }
            window.onRedo = { [weak self] in
                self?.channel?.invokeMethod("redoPressed", arguments: nil)
            }
            window.isFloatingPanel = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = flutter
            self.window = window
        }
        let frame = compact
            ? NSRect(x: displayFrame.midX - 220, y: displayFrame.midY - 90, width: 440, height: 180)
            : displayFrame
        window?.setFrame(frame, display: true)
        // Dart 首帧主动拉取快照，已就绪的窗口通过通知更新；不会丢失第一张截图。
        channel?.invokeMethod("screenshotChanged", arguments: snapshot())
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

}

/// 截图编辑层需要成为 key 才能收 Esc 与文字输入；非激活译文浮层不能复用。
final class ScreenshotPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// event 为按键；Esc 结束本次截图；⌘Z / ⇧⌘Z 走标注历史。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                onRedo?()
            } else {
                onUndo?()
            }
            return
        }
        super.keyDown(with: event)
    }
}

extension ScreenshotWindowController {
    /// notification 为编辑窗关闭通知；释放原始图像并通知 Dart 清空，不撤销已导出文件或贴图。
    func windowWillClose(_ notification: Notification) {
        png = nil
        captureId = nil
        message = nil
        channel?.invokeMethod("screenshotChanged", arguments: snapshot())
    }
}
