import Cocoa
import FlutterMacOS

/// 设置使用独立 Flutter 引擎和普通窗口；浮层保持非激活且不共享视图控制器。
final class SettingsWindowController: NSObject {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?

    /// 无参数；按需创建设置引擎，激活设置窗口，无返回值。
    func show() {
        if let window {
            refresh()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let engine = FlutterEngine(name: "settings", project: nil, allowHeadlessExecution: false)
        self.engine = engine
        let channel = FlutterMethodChannel(name: "translateapp/settings", binaryMessenger: engine.binaryMessenger)
        self.channel = channel
        channel.setMethodCallHandler { call, result in
            let bridge = MacPlatformBridge.Shared.instance!
            switch call.method {
            case "getSettings", "saveSettings":
                bridge.requestSettings(call.method, arguments: call.arguments, result: result)
            default:
                // 系统能力复用主桥，第二引擎不注册全局选区监听或覆盖单例。
                bridge.handle(call, result: result)
            }
        }
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        // 非 headless 引擎必须先绑定控制器，否则 Flutter 会拒绝启动。
        guard engine.run(withEntrypoint: "settingsMain") else {
            channel.setMethodCallHandler(nil)
            engine.shutDownEngine()
            self.engine = nil
            self.channel = nil
            let alert = NSAlert()
            alert.messageText = "设置窗口启动失败"
            alert.informativeText = "请退出并重新打开 TranslateApp。"
            alert.runModal()
            return
        }
        RegisterGeneratedPlugins(registry: flutter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "TranslateApp 设置"
        window.minSize = NSSize(width: 520, height: 500)
        window.isReleasedWhenClosed = false
        window.contentViewController = flutter
        // Flutter 控制器初始视图可为零尺寸；绑定后明确设置可读的表单窗口大小。
        window.setContentSize(NSSize(width: 560, height: 720))
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 无参数；菜单改动或再次打开窗口时刷新主引擎快照，无返回值。
    func refresh() {
        channel?.invokeMethod("refreshSettings", arguments: nil)
    }

    deinit {
        channel?.setMethodCallHandler(nil)
        // Flutter 引擎必须显式停止，关闭窗口只隐藏以便快速重新打开。
        engine?.shutDownEngine()
    }
}
