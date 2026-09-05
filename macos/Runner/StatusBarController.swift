import AppKit

/// 菜单栏入口，提供辅助功能授权和退出操作。
final class StatusBarController {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var installed = false

    func install() {
        if installed { return }
        installed = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "选区翻译")
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "选区翻译") {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        }
        item.button?.title = "选区翻译"
        item.button?.toolTip = "选区翻译"
        statusItem = item
        reloadMenu()
        // 刚创建时窗口高度可能是 0，下一拍再强制显示。
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.isVisible = true
        }
    }

    func reloadMenu() {
        let trusted = AccessibilitySelection.isTrusted(prompt: false)
        let menu = NSMenu()
        let access = NSMenuItem(
            title: trusted ? "辅助功能已开启" : "授予辅助功能权限…",
            action: #selector(requestAccess),
            keyEquivalent: ""
        )
        access.target = self
        access.isEnabled = !trusted
        menu.addItem(access)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func requestAccess() {
        if AccessibilitySelection.isTrusted(prompt: true) {
            reloadMenu()
            return
        }
        AccessibilitySelection.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

}
