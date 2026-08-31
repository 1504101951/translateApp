import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let selectionMonitor = SelectionMonitor()

    override func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        selectionMonitor.start()
        configureStatusItem()
        super.applicationDidFinishLaunching(notification)
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func configureStatusItem() {
        statusItem.button?.title = "选区翻译"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "探测 Overlay", action: #selector(probeOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func probeOverlay() {
        MacPlatformBridge.Shared.instance?.emitProbeSelection()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
