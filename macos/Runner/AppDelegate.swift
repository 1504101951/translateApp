import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    private var flutterViewController: FlutterViewController?
    private let overlay = OverlayPanelController()
    private let selectionMonitor = SelectionMonitor()

    override func applicationDidFinishLaunching(_ notification: Notification) {
        let flutter = FlutterViewController()
        flutterViewController = flutter
        _ = flutter.view
        _ = flutter.engine.run(withEntrypoint: nil)
        RegisterGeneratedPlugins(registry: flutter)
        overlay.attachFlutter(flutter)
        MacPlatformBridge.register(
            with: flutter.engine.binaryMessenger,
            overlay: overlay
        )

        NSApp.setActivationPolicy(.accessory)
        hideMainWindowOnly()
        StatusBarController.shared.install()
        selectionMonitor.start()
        // 不调用 super.applicationDidFinishLaunching：FlutterAppDelegate 未实现该方法，
        // Swift super 会进入嵌套 run loop 且永不返回。AppKit 因此认为启动未结束，
        // 选区监听起不来，浮层窗口也合成不到屏幕上。
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    /// 只藏 xib 主窗口，绝不碰 NSStatusItem 自己的窗口。
    private func hideMainWindowOnly() {
        for window in NSApp.windows where window is MainFlutterWindow {
            window.orderOut(nil)
        }
    }
}
