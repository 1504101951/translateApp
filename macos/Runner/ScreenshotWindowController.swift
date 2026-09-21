import Cocoa
import CoreGraphics
import FlutterMacOS
import UniformTypeIdentifiers

/// 系统截图模块承接权限与冻结帧；Dart 编辑层负责框选变暗、标注与导出。
final class ScreenshotWindowController: NSObject, NSWindowDelegate {
    /// 图片导出的真实剪贴板；测试使用独立命名板，避免覆盖用户剪贴板。
    private let pasteboard: NSPasteboard

    /// pasteboard 为截图导出的系统目标；创建独立的截图生命周期控制器。
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init()
    }
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var textInputActive = false
    /// 标记本编辑会话曾设置原生光标，关闭时清除，避免污染其他窗口。
    private var hasNativeResizeCursor = false
    private var capturing = false
    private var png: Data?
    private var captureId: String?
    private var capturedAt: Int64 = 0
    private var pixels = NSSize.zero
    private var displayFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    /// 前台窗口在冻结帧上的像素裁剪；没有前台窗口则为 nil。
    private var windowCrop: NSRect?
    private var message: String?
    /// 冻结帧垫在 Flutter 下面，避免首帧透明闪一下。
    private let freezeView = NSImageView()
    /// 本地路由处理 AppKit 事件；会话事件拦截负责非激活窗口并消费已处理的按键。
    private var localKeys: Any?
    private var globalKeyTap: CFMachPort?
    private var globalKeySource: CFRunLoopSource?
    /// 贴图与编辑窗分离；关闭编辑不销毁已贴出的图。
    let pins = PinOverlayController()
    var onCapturingChanged: ((Bool) -> Void)?

    /// 无参数；本进程申请权限并捕获指针所在屏冻结帧，无权限不进入编辑。
    func capture() {
        guard !capturing, window?.attachedSheet == nil else { return }
        capturing = true
        onCapturingChanged?(true)
        if window?.isVisible == true {
            window?.orderOut(nil)
        }
        Task { @MainActor in
            defer {
                self.capturing = false
                self.onCapturingChanged?(false)
            }
            let granted = await ScreenCaptureService.requestAccess()
            guard granted else {
                self.png = nil
                self.captureId = nil
                self.windowCrop = nil
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
                self.windowCrop = frame.windowCrop
                self.message = nil
                self.show(compact: false)
            } catch {
                self.png = nil
                self.captureId = nil
                self.windowCrop = nil
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
        if hasNativeResizeCursor { NSCursor.arrow.set(); hasNativeResizeCursor = false }
        removeScreenshotKeys()
        window?.delegate = nil
        window?.close()
        window = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        textInputActive = false
        png = nil
        captureId = nil
        pins.closeAll()
    }

    /// id 为翻译启动时的捕获身份；返回截图是否仍存在且未被替换。
    func isCurrentCapture(_ id: String) -> Bool {
        captureId == id
    }

    /// 无参数；返回当前截图和保存目录，PNG 以 typed data 下发。
    private func snapshot() -> [String: Any] {
        var value: [String: Any] = [
            "directory": UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey) ?? "",
            "screenAccess": ScreenCaptureService.isAuthorized(),
            "capturedAt": capturedAt,
            "width": pixels.width,
            "height": pixels.height,
            "displayX": displayFrame.origin.x,
            "displayY": displayFrame.origin.y,
            "displayWidth": displayFrame.width,
            "displayHeight": displayFrame.height,
        ]
        if let png, let captureId {
            value["id"] = captureId
            value["bytes"] = FlutterStandardTypedData(bytes: png)
        }
        if let windowCrop {
            value["cropX"] = windowCrop.origin.x
            value["cropY"] = windowCrop.origin.y
            value["cropWidth"] = windowCrop.width
            value["cropHeight"] = windowCrop.height
        }
        if let message { value["error"] = message }
        // 新会话携带当前工具偏好；已打开会话使用独立配置通知，不能重置草稿。
        value.merge(toolbarPreferences()) { _, current in current }
        return value
    }

    /// 无参数；返回已保存的工具栏配置子集，缺省值由Dart领域对象提供。
    private func toolbarPreferences() -> [String: Any] {
        let preferences = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) ?? [:]
        return preferences.filter { [AppConstants.screenshotToolbarOrderKey, AppConstants.screenshotToolbarShortcutsKey, AppConstants.screenshotToolbarHiddenKey].contains($0.key) }
    }

    /// 无参数；只广播工具偏好，保留图像与标注，关闭窗口时无订阅者。
    func toolbarPreferencesChanged() {
        channel?.invokeMethod(AppConstants.screenshotToolbarChangedMethod, arguments: toolbarPreferences())
    }

    /// png/id/尺寸为合成捕获；showEditor 为真时启动真实 Flutter 编辑窗，供系统链路测试。
    func seedCaptureForTesting(png: Data, id: String, width: CGFloat = 1, height: CGFloat = 1, showEditor: Bool = false) {
        self.png = png
        self.captureId = id
        self.pixels = NSSize(width: width, height: height)
        self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
        self.message = nil
        if showEditor { show(compact: false) }
    }

    /// call 为截图操作，result 返回数据/路径或错误；导出优先使用 Dart 合成后的 bytes。
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case AppConstants.setResizeCursorMethod:
            // 使用公开AppKit对角光标；Flutter当前macOS引擎会把这两个方向映射为箭头。
            let position: NSCursor.FrameResizePosition
            switch args["direction"] as? String {
            case AppConstants.resizeNorthWestSouthEast: position = .topLeft
            case AppConstants.resizeNorthEastSouthWest: position = .topRight
            default:
                result(FlutterError(code: AppConstants.badArgsError, message: "无效的拉伸光标方向。", details: nil))
                return
            }
            // 窗口关闭后的迟到请求不能重新设置桌面光标。
            guard window?.isVisible == true else { result(nil); return }
            NSCursor.frameResize(position: position, directions: .all).set()
            hasNativeResizeCursor = true
            result(nil)
        case AppConstants.getScreenshotMethod:
            result(snapshot())
        case AppConstants.recognizeBlocksMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload: Data
            if let typed = args["bytes"] as? FlutterStandardTypedData {
                payload = typed.data
            } else if let png {
                payload = png
            } else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            do {
                result(try ScreenCaptureService.recognizeBlocks(png: payload))
            } catch {
                result(FlutterError(code: AppConstants.ocrFailedError, message: error.localizedDescription, details: nil))
            }
        case AppConstants.recognizeTextMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload: Data
            if let typed = args["bytes"] as? FlutterStandardTypedData {
                payload = typed.data
            } else if let png {
                payload = png
            } else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            do {
                result(try ScreenCaptureService.recognizeText(png: payload))
            } catch {
                result(FlutterError(code: AppConstants.ocrFailedError, message: error.localizedDescription, details: nil))
            }
        case AppConstants.copyTextMethod:
            guard let text = args["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: AppConstants.ocrEmptyError, message: "没有可复制的文字。", details: nil))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            result(nil)
        case AppConstants.translatePlainTextMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换。", details: nil)); return
            }
            guard let text = args["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: AppConstants.ocrEmptyError, message: "没有可翻译的文字。", details: nil))
                return
            }
            MacPlatformBridge.Shared.instance?.requestSettings(
                AppConstants.translatePlainTextMethod,
                // 保留捕获身份，主 Dart 引擎在翻译完成后再次核对再写历史。
                arguments: ["text": text, "id": id],
                result: result
            )
        case AppConstants.captureRegionMethod:
            capture(); result(nil)
        case AppConstants.closeScreenshotMethod:
            window?.close(); result(nil)
        case AppConstants.requestScreenAccessMethod:
            Task { @MainActor in
                let granted = await ScreenCaptureService.requestAccess()
                if !granted {
                    ScreenCaptureService.openScreenRecordingSettings()
                }
                result(self.snapshot())
            }
        case AppConstants.copyScreenshotMethod, AppConstants.saveScreenshotMethod, AppConstants.pinScreenshotMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            guard let typed = args["bytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload = typed.data
            switch call.method {
            case AppConstants.copyScreenshotMethod:
                let item = NSPasteboardItem()
                item.setData(payload, forType: .png)
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else {
                    result(FlutterError(code: AppConstants.copyFailedError, message: "无法复制截图，请重试。", details: nil))
                    return
                }
                result(nil)
            case AppConstants.saveScreenshotMethod:
                let name = args["name"] as? String ?? "screenshot.png"
                if let directory = UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey),
                   args["saveAs"] as? Bool != true {
                    do {
                        let url = try ScreenshotStorage.save(
                            payload,
                            directory: URL(fileURLWithPath: directory),
                            name: name
                        )
                        result(url.path)
                    } catch {
                        result(FlutterError(code: AppConstants.saveFailedError, message: error.localizedDescription, details: nil))
                    }
                    return
                }
                guard let window else {
                    result(FlutterError(code: AppConstants.saveFailedError, message: "截图窗口已关闭。", details: nil))
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
                        result(FlutterError(code: AppConstants.saveFailedError, message: error.localizedDescription, details: nil))
                    }
                }
            case AppConstants.pinScreenshotMethod:
                guard let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber else {
                    result(FlutterError(code: AppConstants.badArgsError, message: "贴图缺少选区坐标。", details: nil))
                    return
                }
                window?.orderOut(nil)
                let pinId = pins.pin(
                    png: payload,
                    origin: NSPoint(x: x.doubleValue, y: y.doubleValue)
                )
                result(pinId)
            default:
                result(FlutterMethodNotImplemented)
            }
        case AppConstants.screenshotTextInputMethod:
            guard let active = args["active"] as? Bool else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少文字编辑状态。", details: nil))
                return
            }
            // 引擎异步通知必须属于当前捕获，上一张截图不能锁住新截图快捷键。
            if let id = args["id"] as? String, id == captureId {
                textInputActive = active
            }
            result(nil)
        case AppConstants.revealFileMethod:
            guard let path = args["path"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少文件路径。", details: nil))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            result(nil)
        case AppConstants.closePinMethod:
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
                name: AppConstants.screenshotChannel,
                binaryMessenger: engine.binaryMessenger
            )
            self.channel = channel
            channel.setMethodCallHandler { [weak self] call, result in
                self?.handle(call, result: result)
            }
            let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
            guard engine.run(withEntrypoint: AppConstants.screenshotEntrypoint) else {
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
        // 平台视图工厂按引擎注册，避免独立窗口缺少原生玻璃材料。
        NativeGlassFactory.register(with: flutter)
            // 无边框置顶编辑层覆盖冻结屏；编辑期可成为 key 以接收 Esc/文字。
            let window = ScreenshotPanel(
                contentRect: displayFrame,
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.onEscape = { [weak self] in
                // Dart 判断文字输入中只取消草稿；否则关闭编辑层。
                self?.channel?.invokeMethod(AppConstants.escapePressedMethod, arguments: nil)
            }
            window.onUndo = { [weak self] in
                self?.channel?.invokeMethod(AppConstants.undoPressedMethod, arguments: nil)
            }
            window.onRedo = { [weak self] in
                self?.channel?.invokeMethod(AppConstants.redoPressedMethod, arguments: nil)
            }
            window.isFloatingPanel = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.animationBehavior = .none
            window.hidesOnDeactivate = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = flutter
            flutter.view.wantsLayer = true
            flutter.view.layer?.isOpaque = false
            flutter.view.layer?.backgroundColor = CGColor.clear
            freezeView.imageScaling = .scaleAxesIndependently
            freezeView.wantsLayer = true
            self.window = window
        }
        let frame = compact
            ? NSRect(x: displayFrame.midX - 220, y: displayFrame.midY - 90, width: 440, height: 180)
            : displayFrame
        window?.setFrame(frame, display: true)
        installFreezeImage(compact: compact)
        window?.displayIfNeeded()
        channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
        // 不 activate：激活会把设置窗/菜单栏抢到前台，看起来像闪一下。
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        window?.orderFrontRegardless()
        window?.makeKey()
        installScreenshotKeys()
    }

    /// compact 为失败小窗；成功时把冻结 PNG 垫在 Flutter 下面，避免透明首帧。
    private func installFreezeImage(compact: Bool) {
        guard let host = window?.contentView else { return }
        freezeView.frame = host.bounds
        freezeView.autoresizingMask = [.width, .height]
        if freezeView.superview !== host {
            host.addSubview(freezeView, positioned: .below, relativeTo: nil)
        }
        if compact || png == nil {
            freezeView.image = nil
            freezeView.isHidden = true
            return
        }
        freezeView.isHidden = false
        let image = NSImage(data: png!)
        if let image, let rep = image.representations.first {
            image.size = NSSize(width: displayFrame.width, height: displayFrame.height)
            _ = rep
        }
        freezeView.image = image
    }

    /// event 为按键；返回是否由当前截图处理，调用方据此消费事件。
    func routeScreenshotKey(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, window?.attachedSheet == nil else { return false }
        // 文字输入期间普通键和编辑命令交给Flutter/NSTextInputClient，不能先消费再丢弃。
        // Escape仍由Dart决定仅取消当前文字草稿，其他状态不受影响。
        if textInputActive && event.keyCode != AppConstants.escapeKeyCode { return false }
        if [AppConstants.returnKeyCode, AppConstants.keypadEnterKeyCode].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let id = captureId {
            // 输入法候选确认属于 NSTextInputClient，不能提前提交整段截图标注。
            if let input = window?.firstResponder as? NSTextInputClient, input.hasMarkedText() {
                return false
            }
            // 非激活截图面板不保证 Flutter 收到原始 Enter；本地和全局入口统一转发。
            if !event.isARepeat {
                channel?.invokeMethod(AppConstants.confirmScreenshotMethod, arguments: ["id": id])
            }
            return true
        }
        if event.keyCode == AppConstants.escapeKeyCode {
            (window as? ScreenshotPanel)?.onEscape?()
            return true
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                (window as? ScreenshotPanel)?.onRedo?()
            } else {
                (window as? ScreenshotPanel)?.onUndo?()
            }
            return true
        }
        // 非激活面板不保证收到Flutter键盘事件；直接派发语义动作，禁止重放字符。
        guard let id = captureId,
              let character = event.characters(byApplyingModifiers: [])?.lowercased(),
              character.unicodeScalars.count == 1,
              let key = character.unicodeScalars.first,
              let shortcuts = toolbarPreferences()[AppConstants.screenshotToolbarShortcutsKey] as? [String: [String: Int]] else {
            return false
        }
        let flags = event.modifierFlags
        let modifiers = (flags.contains(.control) ? 1 : 0)
            | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.shift) ? 4 : 0)
            | (flags.contains(.command) ? 8 : 0)
        guard let action = shortcuts.first(where: {
            $0.value["keyId"] == Int(key.value) && $0.value["modifiers"] == modifiers
        })?.key else { return false }
        if !event.isARepeat {
            channel?.invokeMethod(AppConstants.screenshotToolbarActionMethod, arguments: ["id": id, "action": action])
        }
        return true
    }

    /// event 为跨应用按键；返回待继续派发的事件，截图已处理时返回 nil 消费该键。
    func filterScreenshotEvent(_ event: CGEvent) -> CGEvent? {
        guard let key = NSEvent(cgEvent: event) else { return event }
        // 系统事件必须在交给来源应用前消费，不能用只能旁听的 global monitor 确认截图。
        return routeScreenshotKey(key) ? nil : event
    }

    /// 无参数；安装本地路由及可消费的会话级事件拦截，不让截图快捷键传给来源应用。
    private func installScreenshotKeys() {
        removeScreenshotKeys()
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.routeScreenshotKey(event) == true { return nil }
            return event
        }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<ScreenshotWindowController>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout {
                    if let tap = controller.globalKeyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                guard let forwarded = controller.filterScreenshotEvent(event) else { return nil }
                return Unmanaged.passUnretained(forwarded)
            }, userInfo: pointer
        ) else {
            message = "无法启用截图跨应用按键，请检查辅助功能权限后重新截图。"
            channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
            return
        }
        globalKeyTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        globalKeySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 无参数；关掉截图层时卸掉按键监听。
    private func removeScreenshotKeys() {
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        if let globalKeyTap {
            CGEvent.tapEnable(tap: globalKeyTap, enable: false)
            CFMachPortInvalidate(globalKeyTap)
        }
        if let globalKeySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), globalKeySource, .commonModes) }
        localKeys = nil
        globalKeyTap = nil
        globalKeySource = nil
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
        if event.keyCode == AppConstants.escapeKeyCode {
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
        if hasNativeResizeCursor { NSCursor.arrow.set(); hasNativeResizeCursor = false }
        removeScreenshotKeys()
        textInputActive = false
        png = nil
        captureId = nil
        message = nil
        windowCrop = nil
        freezeView.image = nil
        channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
    }
}
