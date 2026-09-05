import Cocoa
import FlutterMacOS

/// Dart ↔ Swift 平台通道。不保存翻译状态，不实现 Provider。
final class MacPlatformBridge: NSObject, FlutterStreamHandler {
    static let methodChannelName = "translateapp/macos"
    static let eventChannelName = "translateapp/macos/events"

    private var eventSink: FlutterEventSink?
    private let overlay: OverlayPanelController
    private var currentSessionId: String?
    private var sourceProcessIdentifier: pid_t?
    var hasSelection: Bool { currentSessionId != nil }

    /// overlay 为实际承载窗口；创建平台桥，不包含翻译业务状态。
    init(overlay: OverlayPanelController) {
        self.overlay = overlay
        super.init()
    }

    /// messenger 为 Flutter 通道，overlay 为窗口；注册命令及事件桥，无返回值。
    static func register(with messenger: FlutterBinaryMessenger, overlay: OverlayPanelController) {
        let instance = MacPlatformBridge(overlay: overlay)
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        methods.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
        events.setStreamHandler(instance)
        Shared.instance = instance
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
        case "probeEmitSelection":
            emitProbeSelection()
            result(nil)
        case "requestAccessibility":
            result(AccessibilitySelection.isTrusted(prompt: true))
        default:
            result(FlutterMethodNotImplemented)
        }
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
