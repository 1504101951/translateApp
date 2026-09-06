import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// 系统负责区域采集和文件/剪贴板，独立 Flutter 窗口负责截图预览及操作界面。
final class ScreenshotWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var process: Process?
    private var captureURL: URL?
    private var png: Data?
    private var captureId: String?
    private var capturedAt: Int64 = 0
    private var pixels = NSSize.zero
    private var message: String?
    var onCapturingChanged: ((Bool) -> Void)?

    /// 无参数；启动系统框选，取消保留旧截图，成功只保留内存 PNG，无返回值。
    func capture() {
        guard process == nil, window?.attachedSheet == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            message = "截图需要屏幕录制权限。授权后重新点击截图；系统提示重启时请退出并重开 App。"
            show()
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("translateapp-\(UUID().uuidString).png")
        let task = Process()
        let errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // 系统框选负责多屏坐标、Escape 取消和选区边框，不维护第二套屏幕选择器。
        task.arguments = ["-i", "-s", "-x", "-t", "png", url.path]
        task.standardError = errors
        task.terminationHandler = { [weak self] task in
            let diagnostic = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { try? FileManager.default.removeItem(at: url); return }
                defer {
                    try? FileManager.default.removeItem(at: url)
                    self.captureURL = nil
                }
                self.process = nil
                self.onCapturingChanged?(false)
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        let data = try Data(contentsOf: url)
                        guard let image = NSBitmapImageRep(data: data) else {
                            throw NSError(domain: "TranslateApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取截图，请重新框选。"])
                        }
                        self.png = data
                        self.captureId = UUID().uuidString
                        self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
                        self.pixels = NSSize(width: image.pixelsWide, height: image.pixelsHigh)
                        self.message = nil
                        self.show()
                    } else if !diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.message = "截图未完成，请检查屏幕录制权限后重试。"
                        self.show()
                    } else if self.png != nil {
                        // 重新截图时取消，恢复仍在内存中的上一张，不改剪贴板或导出文件。
                        self.show()
                    }
                } catch {
                    self.message = error.localizedDescription
                    self.show()
                }
            }
        }
        window?.orderOut(nil)
        onCapturingChanged?(true)
        process = task
        captureURL = url
        do { try task.run() } catch {
            process = nil
            onCapturingChanged?(false)
            message = "无法启动系统截图：\(error.localizedDescription)"
            show()
        }
    }

    /// 无参数；App 退出时终止系统框选并清理临时文件，无返回值。
    func shutdown() {
        if let process, process.isRunning { process.terminate() }
        if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
    }

    /// 无参数；返回当前截图和保存目录，PNG 使用二进制通道，不将图片路径交给网页或翻译服务。
    private func snapshot() -> [String: Any] {
        var value: [String: Any] = [
            "directory": UserDefaults.standard.string(forKey: "screenshotSaveDirectory") ?? "",
            "screenAccess": CGPreflightScreenCaptureAccess(),
            "capturedAt": capturedAt,
            "width": pixels.width, "height": pixels.height,
        ]
        if let png, let captureId {
            value["bytes"] = FlutterStandardTypedData(bytes: png)
            value["id"] = captureId
        }
        if let message { value["error"] = message }
        return value
    }

    /// call 为截图操作，result 返回数据/路径或错误；所有读写仅使用当前内存截图。
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "getScreenshot": result(snapshot())
        case "captureRegion": capture(); result(nil)
        case "closeScreenshot": window?.close(); result(nil)
        case "requestScreenAccess":
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            result(snapshot())
        case "chooseDirectory":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "使用此目录"
            panel.beginSheetModal(for: window!) { response in
                guard response == .OK, let url = panel.url else { result(nil); return }
                UserDefaults.standard.set(url.path, forKey: "screenshotSaveDirectory")
                result(url.path)
            }
        case "clearDirectory":
            UserDefaults.standard.removeObject(forKey: "screenshotSaveDirectory")
            result(nil)
        case "copyScreenshot", "saveScreenshot":
            guard let png, let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: "stale_capture", message: "截图已关闭或被替换，请重新截图。", details: nil)); return
            }
            if call.method == "copyScreenshot" {
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([item]) else {
                    result(FlutterError(code: "copy_failed", message: "无法复制截图，请重试。", details: nil)); return
                }
                result(nil)
                return
            }
            guard let name = args["name"] as? String else {
                result(FlutterError(code: "bad_args", message: "缺少截图文件名。", details: nil)); return
            }
            if let directory = UserDefaults.standard.string(forKey: "screenshotSaveDirectory"), args["saveAs"] as? Bool != true {
                do {
                    let url = try ScreenshotStorage.save(png, directory: URL(fileURLWithPath: directory), name: name)
                    result(url.path)
                } catch { result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil)) }
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window!) { response in
                guard response == .OK, let url = panel.url else { result(nil); return }
                do {
                    // 系统保存面板已处理用户改名及覆盖确认，原子写入避免留下半张图片。
                    try png.write(to: url, options: .atomic)
                    result(url.path)
                } catch { result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil)) }
            }
        case "revealFile":
            guard let path = args["path"] as? String else { result(nil); return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    /// 无参数；按需创建普通预览窗口并同步截图，不占用翻译浮层，无返回值。
    private func show() {
        if window == nil {
            let engine = FlutterEngine(name: "screenshot", project: nil, allowHeadlessExecution: false)
            self.engine = engine
            let channel = FlutterMethodChannel(name: "translateapp/screenshot", binaryMessenger: engine.binaryMessenger)
            self.channel = channel
            channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "TranslateApp 截图"
            window.minSize = NSSize(width: 700, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = flutter
            window.center()
            self.window = window
        }
        // Dart 首帧主动拉取快照，已就绪的窗口通过通知更新；不会丢失第一张截图。
        channel?.invokeMethod("screenshotChanged", arguments: snapshot())
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// notification 为预览关闭通知；释放原始图像并通知 Dart 清空，不撤销已导出的文件。
    func windowWillClose(_ notification: Notification) {
        png = nil
        captureId = nil
        message = nil
        channel?.invokeMethod("screenshotChanged", arguments: snapshot())
    }
}
