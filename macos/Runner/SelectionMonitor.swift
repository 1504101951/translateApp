import AppKit

/// 全局按键里只接 Escape 上报给 Dart。鼠标选区和 Command-A 在后续 Issue 接入。
final class SelectionMonitor {
    private var escapeMonitor: Any?

    func start() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                MacPlatformBridge.Shared.instance?.emitEscape()
            }
        }
    }
}
