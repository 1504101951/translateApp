import Cocoa
import FlutterMacOS

/// 独立可激活 Flutter 窗口（权限向导 / 翻译历史）；不与浮层共享引擎。
final class AuxiliaryWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private let engineName: String
    private let entrypoint: String
    private let title: String
    private let size: NSSize

    /// engineName/entrypoint 标识第二引擎；title/size 为窗口外观。
    init(engineName: String, entrypoint: String, title: String, size: NSSize) {
        self.engineName = engineName
        self.entrypoint = entrypoint
        self.title = title
        self.size = size
    }

    /// 无参数；显示窗口，已存在则前置。
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let engine = FlutterEngine(name: engineName, project: nil, allowHeadlessExecution: false)
        self.engine = engine
        let channel = FlutterMethodChannel(name: "translateapp/settings", binaryMessenger: engine.binaryMessenger)
        self.channel = channel
        channel.setMethodCallHandler { call, result in
            let bridge = MacPlatformBridge.Shared.instance!
            switch call.method {
            case "getSettings", "saveSettings", "testService",
                 "historyPage", "historyRecording", "setHistoryRecording", "translatePlainText":
                bridge.requestSettings(call.method, arguments: call.arguments, result: result)
            default:
                bridge.handle(call, result: result)
            }
        }
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        guard engine.run(withEntrypoint: entrypoint) else {
            channel.setMethodCallHandler(nil)
            engine.shutDownEngine()
            self.engine = nil
            self.channel = nil
            return
        }
        RegisterGeneratedPlugins(registry: flutter)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = flutter
        window.setContentSize(size)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 无参数；通知 Dart 重新读取系统授权，用于从系统设置返回后刷新步骤。
    func notifyPermissionStatusChanged() {
        channel?.invokeMethod("permissionStatusChanged", arguments: nil)
    }

    /// notification 为窗口成为 key；用户点回向导时补一次授权读取。
    func windowDidBecomeKey(_ notification: Notification) {
        notifyPermissionStatusChanged()
    }

    /// 无参数；关闭窗口但不销毁引擎标记，下次 show 可重建。
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }
}
