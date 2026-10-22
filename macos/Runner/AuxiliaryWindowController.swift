import Cocoa
import FlutterMacOS

/// 独立可激活 Flutter 窗口（权限向导 / 翻译历史）；不与浮层共享引擎。
final class AuxiliaryWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var historyObserver: NSObjectProtocol?
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
        super.init()
        if entrypoint == AppConstants.historyEntrypoint {
            historyObserver = NotificationCenter.default.addObserver(forName: AppConstants.historyChangedNotification, object: nil, queue: .main) { [weak self] _ in
                self?.channel?.invokeMethod(AppConstants.historyChangedMethod, arguments: nil)
            }
        }
    }

    deinit {
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }

    /// 无参数；显示窗口，已存在则前置。
    func show() {
        if let window {
            if entrypoint == AppConstants.historyEntrypoint {
                channel?.invokeMethod(AppConstants.historyChangedMethod, arguments: nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // WindowEngine 统一装配附属窗口引擎（#120）；启动失败时不显示窗口。
        guard let started = WindowEngine.start(
            name: engineName, entrypoint: entrypoint, channel: AppConstants.settingsChannel,
            handler: { call, result in
                let bridge = MacPlatformBridge.Shared.instance!
                // routeWindowRequest负责跨引擎分发，辅助窗口不保存业务方法表。
                bridge.routeWindowRequest(call, result: result)
            }) else { return }
        engine = started.engine
        channel = started.channel
        let flutter = started.flutter
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = title
        window.isReleasedWhenClosed = false
        // 辅助窗口共用透明承载，玻璃材料由各自 Flutter 引擎的原生视图绘制。
        window.isOpaque = false
        window.backgroundColor = .clear
        NativeGlassFactory.installContent(flutter, in: window)
        window.setContentSize(size)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 无参数；通知 Dart 重新读取系统授权，用于从系统设置返回后刷新步骤。
    func notifyPermissionStatusChanged() {
        channel?.invokeMethod(AppConstants.permissionStatusChangedMethod, arguments: nil)
    }

    /// notification 为窗口成为 key；用户点回向导时补一次授权读取。
    func windowDidBecomeKey(_ notification: Notification) {
        notifyPermissionStatusChanged()
    }

    /// 无参数；关闭窗口但不销毁引擎标记，下次 show 可重建。
    func close() {
        window?.close()
    }

    /// notification 为窗口关闭事件；解除当前引擎回调并停止引擎，返回void。
    func windowWillClose(_ notification: Notification) {
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }
}
