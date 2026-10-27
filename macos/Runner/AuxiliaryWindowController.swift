import Cocoa
import FlutterMacOS

/// 独立可激活 Flutter 窗口（权限向导 / 翻译历史）；不与浮层共享引擎。
final class AuxiliaryWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    /// 保留尚未确认的启动，关闭时撤销，防止迟到窗口重新出现。
    private var pendingStartup: WindowEngine.Startup?
    private let engineName: String
    private let entrypoint: String
    private let title: String
    private let size: NSSize
    private let refreshMethod: String?
    private let refreshesOnFocus: Bool

    /// engineName/entrypoint 标识第二引擎；title/size 为窗口外观；
    /// refreshMethod 为请 Dart 重新读取数据的方法名，重开已存在的窗口或调用 refresh() 时发送，为空表示不需要（#126）；
    /// refreshesOnFocus 为真时窗口每次成为 key 也发送，供权限向导在用户点回时重读授权。
    init(engineName: String, entrypoint: String, title: String, size: NSSize,
         refreshMethod: String? = nil, refreshesOnFocus: Bool = false) {
        self.engineName = engineName
        self.entrypoint = entrypoint
        self.title = title
        self.size = size
        self.refreshMethod = refreshMethod
        self.refreshesOnFocus = refreshesOnFocus
        super.init()
    }

    /// 无参数；显示窗口，已存在则刷新后前置。
    func show() {
        if let window {
            refresh()
            WindowEngine.present(window)
            return
        }
        guard pendingStartup == nil else { return }
        // WindowEngine 等待 Dart 就绪；重复打开复用本次启动。
        pendingStartup = WindowEngine.start(
            name: engineName, entrypoint: entrypoint, channel: AppConstants.settingsChannel,
            handler: { call, result in
                let bridge = MacPlatformBridge.Shared.instance!
                // routeWindowRequest负责跨引擎分发，辅助窗口不保存业务方法表。
                bridge.routeWindowRequest(call, result: result)
            }, completion: { [weak self] started in
                guard let self else { return }
                self.pendingStartup = nil
                guard let started else {
                    // reportStartFailure 统一提示未就绪；失败资源由启动对象释放。
                    WindowEngine.reportStartFailure("\(self.title)窗口")
                    return
                }
                self.engine = started.engine
                self.channel = started.channel
                // makeWindow 建出普通窗口；附属窗口关闭即停止引擎。
                let window = WindowEngine.makeWindow(
                    flutter: started.flutter, title: self.title, size: self.size, minSize: nil, delegate: self)
                self.window = window
                // present 激活并前置已经就绪的附属窗口。
                WindowEngine.present(window)
            })
    }

    /// 无参数；窗口引擎运行中且配置了 refreshMethod 时请 Dart 重新读取数据，无返回值。
    func refresh() {
        guard let refreshMethod else { return }
        channel?.invokeMethod(refreshMethod, arguments: nil)
    }

    /// notification 为窗口成为 key；只有 refreshesOnFocus 的窗口（权限向导）在用户点回时刷新，无返回值。
    func windowDidBecomeKey(_ notification: Notification) {
        guard refreshesOnFocus else { return }
        refresh()
    }

    /// 无参数；撤销待启动窗口并关闭现有窗口，下次 show 可重建，无返回值。
    func close() {
        pendingStartup?.cancel()
        pendingStartup = nil
        window?.close()
    }

    /// notification 为窗口关闭事件；解除当前引擎回调并停止引擎，返回void。
    func windowWillClose(_ notification: Notification) {
        pendingStartup?.cancel()
        pendingStartup = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }

    deinit {
        pendingStartup?.cancel()
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
    }
}
