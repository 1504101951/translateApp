import AppKit
import FlutterMacOS

/// 附属窗口共用的 Flutter 引擎装配（#120）：设置、权限向导、历史、截图与采集窗口都经这里创建引擎。
enum WindowEngine {
    /// 已运行的附属窗口引擎、视图控制器与方法通道。
    typealias Started = (engine: FlutterEngine, flutter: FlutterViewController, channel: FlutterMethodChannel)

    /// 单次启动拥有的资源与终态；Dart 确认后将资源所有权交给窗口，取消和失败负责清理。
    final class Startup {
        /// waiting 是唯一可接受确认的状态；终态阻止迟到确认重新交付窗口。
        private enum State { case waiting, succeeded, failed, cancelled }
        private var state = State.waiting
        private var resources: Started?
        private var acknowledgement: FlutterMethodChannel?
        private var deadline: DispatchWorkItem?
        private var completion: ((Started?) -> Void)?

        /// name/entrypoint/channel/handler 为引擎与业务协议；completion 接收就绪资源或失败 nil。
        /// 返回尚未运行的启动对象，下一轮主队列才运行入口，让调用方先保存取消句柄。
        fileprivate init(name: String, entrypoint: String, channel: String,
                         handler: @escaping FlutterMethodCallHandler,
                         completion: @escaping (Started?) -> Void) {
            precondition(Thread.isMainThread)
            self.completion = completion
            let engine = FlutterEngine(name: name, project: nil, allowHeadlessExecution: false)
            let methods = FlutterMethodChannel(name: channel, binaryMessenger: engine.binaryMessenger)
            methods.setMethodCallHandler(handler)
            let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
            resources = (engine, flutter, methods)
            let acknowledgement = FlutterMethodChannel(
                name: AppConstants.windowStartupChannel, binaryMessenger: engine.binaryMessenger)
            self.acknowledgement = acknowledgement
            // 确认处理器先于 run 注册；每个引擎的 messenger 隔离本次启动身份。
            acknowledgement.setMethodCallHandler { [weak self] call, reply in
                guard call.method == AppConstants.windowReadyMethod else {
                    reply(FlutterMethodNotImplemented)
                    return
                }
                reply(nil)
                // 等当前 run 和插件注册完成再交付；不等待附着窗口后才可能出现的首帧。
                DispatchQueue.main.async { [weak self] in self?.finish(succeeded: true) }
            }
            DispatchQueue.main.async { [weak self] in self?.run(entrypoint: entrypoint) }
        }

        /// entrypoint 为 Dart 编译入口名；运行入口并注册插件，失败或五秒未确认时完成失败，无返回值。
        private func run(entrypoint: String) {
            guard state == .waiting, let resources else { return }
            let deadline = DispatchWorkItem { [weak self] in self?.finish(succeeded: false) }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.windowStartupTimeout, execute: deadline)
            guard resources.engine.run(withEntrypoint: entrypoint) else {
                finish(succeeded: false)
                return
            }
            RegisterGeneratedPlugins(registry: resources.flutter)
            // 平台视图工厂按引擎注册，避免独立窗口缺少原生玻璃材料。
            NativeGlassFactory.register(with: resources.flutter)
        }

        /// succeeded 表示收到 Dart 确认；仅 waiting 可交付或失败，终态清除确认通道与计时器，无返回值。
        private func finish(succeeded: Bool) {
            precondition(Thread.isMainThread)
            guard state == .waiting else { return }
            state = succeeded ? .succeeded : .failed
            deadline?.cancel()
            deadline = nil
            acknowledgement?.setMethodCallHandler(nil)
            acknowledgement = nil
            let delivered = succeeded ? resources : nil
            if !succeeded { releaseResources() }
            resources = nil
            let callback = completion
            completion = nil
            callback?(delivered)
        }

        /// 无参数；撤销尚未交付的启动并释放资源，不触发失败提示回调，无返回值。
        func cancel() {
            precondition(Thread.isMainThread)
            guard state == .waiting else { return }
            state = .cancelled
            deadline?.cancel()
            deadline = nil
            acknowledgement?.setMethodCallHandler(nil)
            acknowledgement = nil
            completion = nil
            // releaseResources 解除业务处理器并停止本次引擎。
            releaseResources()
        }

        /// 无参数；释放本对象仍拥有的业务通道、控制器与引擎，无返回值。
        private func releaseResources() {
            resources?.channel.setMethodCallHandler(nil)
            resources?.engine.shutDownEngine()
            resources = nil
        }

        deinit { cancel() }
    }

    /// name/entrypoint/channel/handler 指定引擎与业务协议；completion 在 Dart 确认后接收资源，失败接收 nil。
    /// 返回可取消的启动句柄；调用方须保留到完成，取消不触发 completion。
    static func start(name: String, entrypoint: String, channel: String,
                      handler: @escaping FlutterMethodCallHandler,
                      completion: @escaping (Started?) -> Void) -> Startup {
        Startup(name: name, entrypoint: entrypoint, channel: channel, handler: handler, completion: completion)
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
