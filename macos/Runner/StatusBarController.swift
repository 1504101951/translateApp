import AppKit
import FlutterMacOS

/// 菜单栏入口，提供设置、仅使用快捷键开关、辅助功能授权和退出操作。
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var installed = false
    private var automaticItem: NSMenuItem?
    private var accessItem: NSMenuItem?
    var showSettings: (() -> Void)?
    var refreshSettings: (() -> Void)?
    var showHistory: (() -> Void)?

    /// 无参数；首次调用创建菜单栏图标与菜单，重复调用保持现有实例，无返回值。
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

    /// 无参数；按当前辅助功能授权状态重建菜单项与动作，无返回值。
    func reloadMenu() {
        let trusted = AccessibilitySelection.isTrusted(prompt: false)
        let menu = NSMenu()
        menu.delegate = self
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let screenshot = NSMenuItem(title: "区域截图…", action: #selector(captureScreenshot), keyEquivalent: "")
        screenshot.target = self
        menu.addItem(screenshot)
        let history = NSMenuItem(title: "翻译历史…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        let automatic = NSMenuItem(title: "仅使用快捷键", action: #selector(toggleAutomatic), keyEquivalent: "")
        automatic.target = self
        automaticItem = automatic
        menu.addItem(automatic)
        menu.addItem(.separator())
        let access = NSMenuItem(
            title: trusted ? "辅助功能已开启" : "授予辅助功能权限…",
            action: #selector(requestAccess),
            keyEquivalent: ""
        )
        accessItem = access
        access.target = self
        access.isEnabled = !trusted
        menu.addItem(access)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    /// enabled 为主 Dart 已成功保存的自动按钮设置；更新菜单状态，无返回值。
    func updateAutomatic(_ enabled: Bool) {
        // 菜单勾选表示仅使用快捷键，与底层自动捕获状态相反。
        automaticItem?.state = enabled ? .off : .on
    }

    /// menu 为即将展示的菜单；即时读取权限状态，无返回值。
    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AccessibilitySelection.isTrusted(prompt: false)
        accessItem?.title = trusted ? "辅助功能已开启" : "授予辅助功能权限…"
        accessItem?.isEnabled = !trusted
    }

    /// 无参数；打开普通设置窗口，无返回值。
    @objc private func openSettings() { showSettings?() }

    /// 无参数；打开翻译历史窗口，无返回值。
    @objc private func openHistory() { showHistory?() }

    /// 无参数；菜单关闭后进入系统区域框选，不触发翻译，无返回值。
    @objc private func captureScreenshot() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture() }
    }

    /// 无参数；经主 Dart 修改全局开关，成功后刷新设置窗口，无返回值。
    @objc private func toggleAutomatic() {
        MacPlatformBridge.Shared.instance?.requestSettings(AppConstants.toggleAutomaticMethod) { [weak self] value in
            if let error = value as? FlutterError {
                let alert = NSAlert()
                alert.messageText = "设置未保存"
                alert.informativeText = error.message ?? error.code
                alert.runModal()
                return
            }
            self?.refreshSettings?()
        }
    }

    /// 无参数；已授权则只刷新菜单，未授权才弹出系统提示。
    @objc private func requestAccess() {
        if AccessibilitySelection.isTrusted(prompt: false) {
            reloadMenu()
            return
        }
        _ = AccessibilitySelection.isTrusted(prompt: true)
        AccessibilitySelection.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

}
