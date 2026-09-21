import Cocoa
import Carbon
import FlutterMacOS

@main
/// 应用启动协调器；持有主引擎、辅助窗口、浮层及选区监听，将AppKit生命周期连接到平台桥。
class AppDelegate: FlutterAppDelegate {
  private let settingsWindow = SettingsWindowController()
  private let permissionWizard = AuxiliaryWindowController(
    engineName: "permission-wizard",
    entrypoint: AppConstants.permissionWizardEntrypoint,
    title: "TranslateApp 权限",
    size: NSSize(width: 480, height: 360)
  )
  private let historyWindow = AuxiliaryWindowController(
    engineName: "history",
    entrypoint: AppConstants.historyEntrypoint,
    title: "翻译历史",
    size: NSSize(width: 520, height: 640)
  )
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
        // 平台视图工厂按引擎注册，避免独立窗口缺少原生玻璃材料。
        NativeGlassFactory.register(with: flutter)
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
        StatusBarController.shared.showHistory = { [weak self] in self?.historyWindow.show() }
        StatusBarController.shared.install()
        bridge.closePermissionWizard = { [weak self] in self?.permissionWizard.close() }
        bridge.showHistory = { [weak self] in self?.historyWindow.show() }
        bridge.onReady = { [weak self] in
            let access = AccessibilitySelection.isTrusted(prompt: false)
            let screen = ScreenCaptureService.isAuthorized()
            if access && screen {
                UserDefaults.standard.set(true, forKey: AppConstants.permissionWizardFinishedKey)
                if self?.launchedAtLogin == false { self?.settingsWindow.show() }
                return
            }
            // 缺权限就弹向导；稍后只关这一次，下次启动仍要检查实际 TCC。
            self?.permissionWizard.show()
        }
        selectionMonitor.start()
        // 不调用 super.applicationDidFinishLaunching：FlutterAppDelegate 未实现该方法，
        // Swift super 会进入嵌套 run loop 且永不返回。AppKit 因此认为启动未结束，
        // 选区监听起不来，浮层窗口也合成不到屏幕上。
    }

    /// notification 为激活通知；从系统设置返回后刷新权限向导步骤。
    override func applicationDidBecomeActive(_ notification: Notification) {
        permissionWizard.notifyPermissionStatusChanged()
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
