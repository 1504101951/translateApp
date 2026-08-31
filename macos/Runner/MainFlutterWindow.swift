import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    private let overlay = OverlayPanelController()

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        RegisterGeneratedPlugins(registry: flutterViewController)

        // 主窗口只用来启动引擎，立刻隐藏；Flutter 视图嵌进非激活 NSPanel。
        contentViewController = nil
        overlay.attachFlutter(flutterViewController)
        MacPlatformBridge.register(
            with: flutterViewController.engine.binaryMessenger,
            overlay: overlay
        )

        isReleasedWhenClosed = false
        orderOut(nil)
        super.awakeFromNib()
    }
}
