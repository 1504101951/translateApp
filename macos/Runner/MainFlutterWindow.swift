import Cocoa
import FlutterMacOS

/// xib 仍会实例化这扇窗口。引擎改在 AppDelegate 创建，这里只负责立刻藏起来。
class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        super.awakeFromNib()
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        alphaValue = 0
        orderOut(nil)
        StatusBarController.shared.install()
    }
}
