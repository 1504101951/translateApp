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
}
