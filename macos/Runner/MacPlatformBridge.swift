import Cocoa
import FlutterMacOS

/// Dart ↔ Swift 平台通道。不保存翻译状态，不实现 Provider。
final class MacPlatformBridge: NSObject, FlutterStreamHandler {
    static let methodChannelName = "translateapp/macos"
    static let eventChannelName = "translateapp/macos/events"

    private var eventSink: FlutterEventSink?
    private var overlay: OverlayPanelController?
    private var currentSessionId: String?

    static func register(with messenger: FlutterBinaryMessenger, overlay: OverlayPanelController) {
        let instance = MacPlatformBridge()
        instance.overlay = overlay
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
            let width = (args["width"] as? Double) ?? 240
            let height = (args["height"] as? Double) ?? 140
            currentSessionId = sessionId
            overlay?.show(
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
            overlay?.hide(sessionId: sessionId)
            result(nil)
        case "setOverlaySize":
            guard let sessionId = args["sessionId"] as? String,
                  let width = args["width"] as? Double,
                  let height = args["height"] as? Double
            else {
                result(FlutterError(code: "bad_args", message: "setOverlaySize 需要 sessionId/width/height", details: nil))
                return
            }
            overlay?.resize(sessionId: sessionId, size: NSSize(width: width, height: height))
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

    func overlayContains(_ point: NSPoint) -> Bool {
        overlay?.contains(point) ?? false
    }

    func emitSelectionCaptured(text: String, gesture: String, x: CGFloat, y: CGFloat) {
        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        emit([
            "type": "selectionCaptured",
            "sessionId": sessionId,
            "text": text,
            "gesture": gesture,
            "x": x,
            "y": y,
        ])
    }

    func emitProbeSelection() {
        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        let mouse = NSEvent.mouseLocation
        emit([
            "type": "selectionCaptured",
            "sessionId": sessionId,
            "text": "probe",
            "gesture": "drag",
            "x": mouse.x,
            "y": mouse.y,
        ])
    }

    func emitEscape() {
        guard let sessionId = currentSessionId else { return }
        emit([
            "type": "escapePressed",
            "sessionId": sessionId,
        ])
    }

    func emit(_ payload: [String: Any]) {
        eventSink?(payload)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
