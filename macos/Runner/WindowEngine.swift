import AppKit
import FlutterMacOS

/// 附属窗口共用的 Flutter 引擎装配（#120）：设置、权限向导、历史、截图与采集窗口都经这里创建引擎。
enum WindowEngine {
    /// 已运行的附属窗口引擎、视图控制器与方法通道。
    typealias Started = (engine: FlutterEngine, flutter: FlutterViewController, channel: FlutterMethodChannel)

    /// name 为引擎名，entrypoint 为 Dart 入口，channel 为方法通道名，handler 为该通道的方法处理函数；
    /// 依次建引擎与通道并绑定处理函数、绑定视图控制器（非 headless 引擎必须先绑定控制器才能启动）、运行入口、
    /// 注册插件与原生玻璃平台视图。返回 [Started]；入口运行失败时解除处理函数、关闭引擎并返回 nil，提示方式由各窗口决定。
    static func start(name: String, entrypoint: String, channel: String,
                      handler: @escaping FlutterMethodCallHandler) -> Started? {
        let engine = FlutterEngine(name: name, project: nil, allowHeadlessExecution: false)
        let methods = FlutterMethodChannel(name: channel, binaryMessenger: engine.binaryMessenger)
        methods.setMethodCallHandler(handler)
        let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        guard engine.run(withEntrypoint: entrypoint) else {
            methods.setMethodCallHandler(nil)
            engine.shutDownEngine()
            return nil
        }
        RegisterGeneratedPlugins(registry: flutter)
        // 平台视图工厂按引擎注册，避免独立窗口缺少原生玻璃材料。
        NativeGlassFactory.register(with: flutter)
        return (engine, flutter, methods)
    }

    /// flutter 为已运行引擎的视图控制器，title/size 为窗口标题与内容尺寸，minSize 为最小尺寸（为空不限制），
    /// delegate 接收窗口事件；返回关闭时不释放、透明承载原生玻璃内容、已居中但尚未显示的普通窗口（#126）。
    static func makeWindow(flutter: FlutterViewController, title: String, size: NSSize, minSize: NSSize?,
                           delegate: NSWindowDelegate) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.delegate = delegate
        window.title = title
        if let minSize { window.minSize = minSize }
        window.isReleasedWhenClosed = false
        // Flutter 控件绘制在原生玻璃材料上；窗口本身透明承载，保持普通层级。
        window.isOpaque = false
        window.backgroundColor = .clear
        NativeGlassFactory.installContent(flutter, in: window)
        // Flutter 控制器初始视图可为零尺寸；绑定后明确设置内容尺寸。
        window.setContentSize(size)
        window.center()
        return window
    }

    /// window 为附属窗口；激活应用并前置该窗口，无返回值。
    static func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// name 为窗口名；引擎启动失败时弹出提示，请用户重开应用，无返回值（#126）。
    static func reportStartFailure(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "\(name)启动失败"
        alert.informativeText = "请退出并重新打开 TranslateApp。"
        alert.runModal()
    }
}
