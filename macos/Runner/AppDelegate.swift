import Cocoa
import Carbon
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let settingsWindow = SettingsWindowController()
  private var launchedAtLogin = false

  /// notification 为应用启动通知；从系统 AppleEvent 识别登录项启动，无返回值。
  override func applicationWillFinishLaunching(_ notification: Notification) {
    let event = NSAppleEventManager.shared().currentAppleEvent
    launchedAtLogin = event?.eventID == kAEOpenApplication &&
      event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
  }
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
        let bridge = MacPlatformBridge.register(
            with: flutter.engine.binaryMessenger,
            overlay: overlay,
            selectionMonitor: selectionMonitor
        )

        NSApp.setActivationPolicy(.accessory)
        hideMainWindowOnly()
        StatusBarController.shared.showSettings = { [weak self] in self?.settingsWindow.show() }
        StatusBarController.shared.refreshSettings = { [weak self] in self?.settingsWindow.refresh() }
        StatusBarController.shared.install()
        bridge.onReady = { [weak self] in
            if self?.launchedAtLogin == false { self?.settingsWindow.show() }
        }
        selectionMonitor.start()
        // 不调用 super.applicationDidFinishLaunching：FlutterAppDelegate 未实现该方法，
        // Swift super 会进入嵌套 run loop 且永不返回。AppKit 因此认为启动未结束，
        // 选区监听起不来，浮层窗口也合成不到屏幕上。
    }

    /// notification 为 App 退出通知；不遗留系统框选进程或临时 PNG，无返回值。
    override func applicationWillTerminate(_ notification: Notification) {
        MacPlatformBridge.Shared.instance?.screenshot.shutdown()
    }

    /// sender 为当前应用，flag 为窗口可见性；Finder 再次打开时展示设置并返回 false。
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
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
