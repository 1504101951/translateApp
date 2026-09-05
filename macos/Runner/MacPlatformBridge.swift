import Cocoa
import NaturalLanguage
import ServiceManagement
import UniformTypeIdentifiers
import FlutterMacOS

/// Dart ↔ Swift 平台通道。不保存翻译状态，不实现 Provider。
final class MacPlatformBridge: NSObject, FlutterStreamHandler {
    static let methodChannelName = "translateapp/macos"
    static let eventChannelName = "translateapp/macos/events"

    private var eventSink: FlutterEventSink?
    private let overlay: OverlayPanelController
    private let selectionMonitor: SelectionMonitor
    private var methods: FlutterMethodChannel?
    var onReady: (() -> Void)?
    var shortcutRecorder: ((UInt32, UInt32) -> Void)?
    private var currentSessionId: String?
    private var sourceProcessIdentifier: pid_t?
    var hasSelection: Bool { currentSessionId != nil }

    /// overlay 为浮层，selectionMonitor 为系统输入监听；创建不含翻译业务状态的平台桥。
    init(overlay: OverlayPanelController, selectionMonitor: SelectionMonitor) {
        self.overlay = overlay
        self.selectionMonitor = selectionMonitor
        super.init()
    }

    /// messenger 为主引擎通道，overlay 为浮层，selectionMonitor 为输入监听；返回已注册的平台桥。
    @discardableResult
    static func register(with messenger: FlutterBinaryMessenger, overlay: OverlayPanelController, selectionMonitor: SelectionMonitor) -> MacPlatformBridge {
        let instance = MacPlatformBridge(overlay: overlay, selectionMonitor: selectionMonitor)
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        instance.methods = methods
        methods.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
        events.setStreamHandler(instance)
        Shared.instance = instance
        return instance
    }

    enum Shared {
        static var instance: MacPlatformBridge?
    }

    /// call 为带 sessionId 的窗口命令；通过 result 返回成功或参数错误，无直接返回值。
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "showOverlay":
            guard let sessionId = args["sessionId"] as? String,
                  let x = args["x"] as? Double,
                  let y = args["y"] as? Double
            else {
                result(FlutterError(code: "bad_args", message: "showOverlay 需要 sessionId/x/y", details: nil))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            guard let width = args["width"] as? Double, let height = args["height"] as? Double,
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
                result(FlutterError(code: "bad_args", message: "Overlay 坐标和尺寸必须有效", details: nil))
                return
            }
            // 显示前再次核对会话，失效后迟到的 Dart 指令不能重新弹窗。
            overlay.show(
                at: NSPoint(x: x, y: y),
                size: NSSize(width: width, height: height),
                sessionId: sessionId
            )
            result(nil)
        case "hideOverlay":
            guard let sessionId = args["sessionId"] as? String else {
                result(FlutterError(code: "bad_args", message: "hideOverlay 需要 sessionId", details: nil))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            currentSessionId = nil
            sourceProcessIdentifier = nil
            overlay.hide(sessionId: sessionId)
            result(nil)
        case "setOverlaySize":
            guard let sessionId = args["sessionId"] as? String,
                  let width = args["width"] as? Double,
                  let height = args["height"] as? Double
            else {
                result(FlutterError(code: "bad_args", message: "setOverlaySize 需要 sessionId/width/height", details: nil))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                result(FlutterError(code: "bad_args", message: "Overlay 尺寸必须为正数", details: nil))
                return
            }
            overlay.resize(sessionId: sessionId, size: NSSize(width: width, height: height))
            result(nil)
        case "dragOverlay":
            guard let sessionId = args["sessionId"] as? String else {
                result(FlutterError(code: "bad_args", message: "dragOverlay 需要 sessionId", details: nil))
                return
            }
            // Flutter 区分拖动与点击，AppKit 负责实际移动且不激活应用。
            overlay.drag(sessionId: sessionId)
            result(nil)
        case "loadSettings":
            var settings = UserDefaults.standard.dictionary(forKey: "preferences") ?? [:]
            settings["systemLanguage"] = Locale.preferredLanguages.first ?? "en"
            settings["launchAtLogin"] = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
            result(settings)
        case "applySettings":
            applySettings(args, result: result)
        case "detectLanguage":
            guard let text = args["text"] as? String else {
                result(FlutterError(code: "bad_args", message: "缺少待识别文本", details: nil)); return
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first
            result(hypothesis.flatMap { $0.value >= 0.5 ? $0.key.rawValue : nil })
        case "systemStatus":
            result([
                "accessibility": AccessibilitySelection.isTrusted(prompt: false),
                "loginNeedsApproval": SMAppService.mainApp.status == .requiresApproval,
            ])
        case "openAccessibility":
            _ = AccessibilitySelection.isTrusted(prompt: true)
            AccessibilitySelection.openSettings()
            result(nil)
        case "openLoginItems":
            SMAppService.openSystemSettingsLoginItems()
            result(nil)
        case "chooseExcludedApp":
            let picker = NSOpenPanel()
            picker.allowedContentTypes = [.applicationBundle]
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
            picker.allowsMultipleSelection = false
            picker.prompt = "排除此应用"
            picker.begin { response in
                guard response == .OK, let url = picker.url else { result(nil); return }
                guard let id = Bundle(url: url)?.bundleIdentifier else {
                    result(FlutterError(code: "bad_app", message: "该应用没有 Bundle ID。", details: nil)); return
                }
                result(["id": id, "name": (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension])
            }
        case "appReady":
            onReady?()
            result(nil)
        case "probeEmitSelection":
            emitProbeSelection()
            result(nil)
        case "requestAccessibility":
            result(AccessibilitySelection.isTrusted(prompt: true))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// settings 为 Dart 校验过的完整偏好；先完成系统副作用再落盘，结果通过 result 返回。
    private func applySettings(_ settings: [String: Any], result: @escaping FlutterResult) {
        guard let automatic = settings["automatic"] as? Bool,
              let keyCode = settings["shortcutKeyCode"] as? UInt32,
              let modifiers = settings["shortcutModifiers"] as? UInt32,
              let excluded = settings["excludedApps"] as? [String: String],
              let login = settings["launchAtLogin"] as? Bool else {
            result(FlutterError(code: "bad_settings", message: "系统设置参数不完整。", details: nil)); return
        }
        let previousLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        do {
            if login != previousLogin {
                if login { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            }
            do {
                try selectionMonitor.configure(automatic: automatic, excludedApps: Set(excluded.keys), keyCode: keyCode, modifiers: modifiers)
            } catch {
                // 热键冲突不应顺带保存登录项；恢复用户点击保存前的系统状态。
                if login != previousLogin {
                    if previousLogin { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                }
                throw error
            }
            UserDefaults.standard.set(settings, forKey: "preferences")
            StatusBarController.shared.updateAutomatic(automatic)
            result(nil)
        } catch {
            result(FlutterError(code: "settings_failed", message: error.localizedDescription, details: nil))
        }
    }

    /// method/arguments 为设置请求；转到主 Dart 引擎，由 result 返回唯一偏好快照。
    func requestSettings(_ method: String, arguments: Any? = nil, result: @escaping FlutterResult) {
        methods!.invokeMethod(method, arguments: arguments, result: result)
    }

    /// point 为屏幕坐标；返回它是否位于当前可见浮层内。
    func overlayContains(_ point: NSPoint) -> Bool {
        overlay.contains(point)
    }

    /// text 为选中文字，gesture 为手势，x/y 为屏幕锚点，sourcePID 为来源进程；发送新会话，无返回值。
    func emitSelectionCaptured(text: String, gesture: String, x: CGFloat, y: CGFloat, sourcePID: pid_t) {
        // 新选区先结束旧会话，避免结果卡片等待 Dart 往返期间残留。
        invalidateSelection()
        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        sourceProcessIdentifier = sourcePID
        emit([
            "type": "selectionCaptured",
            "sessionId": sessionId,
            "text": text,
            "gesture": gesture,
            "x": x,
            "y": y,
        ])
    }

    /// 无参数；发送固定文本的探测选区，无返回值。
    func emitProbeSelection() {
        let mouse = NSEvent.mouseLocation
        // 探测与真实事件使用相同的会话生命周期。
        emitSelectionCaptured(text: "probe", gesture: "drag", x: mouse.x, y: mouse.y,
                              sourcePID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? getpid())
    }

    /// processIdentifier 为新前台进程；仅在离开来源应用时结束会话，无返回值。
    func sourceApplicationChanged(to processIdentifier: pid_t?) {
        guard sourceProcessIdentifier != processIdentifier else { return }
        // 显示非激活面板不会改变前台 PID，因此不会误关自身浮层。
        invalidateSelection()
    }

    /// eventType 为失效或 Escape 事件类型；同步隐藏并通知 Dart 丢弃旧结果，无返回值。
    func invalidateSelection(eventType: String = "selectionInvalidated") {
        guard let sessionId = currentSessionId else { return }
        currentSessionId = nil
        sourceProcessIdentifier = nil
        overlay.hide(sessionId: sessionId)
        emit([
            "type": eventType,
            "sessionId": sessionId,
        ])
    }

    /// payload 为带类型和会话 ID 的事件字典；发送至 Dart，无返回值。
    func emit(_ payload: [String: Any]) {
        eventSink?(payload)
    }

    /// arguments 为未使用的订阅参数，events 为 Dart 事件接收端；保存订阅并返回 nil。
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    /// arguments 为未使用的取消参数；移除事件接收端并返回 nil。
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
