import AppKit
import FlutterMacOS

/// 菜单栏入口，提供设置、仅使用快捷键开关、辅助功能授权和退出操作。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var installed = false
    private var automaticItem: NSMenuItem?
    private var accessItem: NSMenuItem?
    private var stopCaptureItem: NSMenuItem?
    private var liveAbort = false
    /// 执行中或仍在最短保持时间内的 MCP 截图数；大于 0 时显示采集图标。
    private var mcpCaptures = 0
    private var abortLiveTranslation: (() -> Void)?
    var showSettings: (() -> Void)?
    var refreshSettings: (() -> Void)?
    var showHistory: (() -> Void)?

    /// 无参数；首次调用创建菜单栏图标与菜单，重复调用保持现有实例，无返回值。
    func install() {
        if installed { return }
        installed = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        item.button?.image = idleImage()
        item.button?.imagePosition = .imageOnly
        // 图标独占菜单栏方形位置，名称仍通过悬停与辅助功能提供。
        item.button?.title = ""
        item.button?.setAccessibilityLabel("选区翻译")
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
        menu.autoenablesItems = false
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        // 截图编辑工具栏承载媒体工具，菜单栏保留普通截图和采集停止。
        let screenshot = NSMenuItem(title: "区域截图…", action: #selector(captureScreenshot), keyEquivalent: "")
        screenshot.target = self
        menu.addItem(screenshot)
        let stop = NSMenuItem(title: "停止采集", action: #selector(stopCapture), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
        stopCaptureItem = stop
        menu.addItem(stop)
        menu.addItem(.separator())
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
        statusItem?.menu = liveAbort ? nil : menu
    }

    /// active 为实时翻译正在运行。图标变为中止按钮，点击执行结束并保留结果。
    func setLiveAbort(_ active: Bool, abort: (() -> Void)? = nil) {
        liveAbort = active
        abortLiveTranslation = abort
        let button = statusItem?.button
        if active {
            statusItem?.menu = nil
            if let image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "中止实时翻译") {
                image.isTemplate = true
                button?.image = image
            }
            button?.action = #selector(abortLive)
            button?.target = self
            button?.toolTip = "中止实时翻译"
            button?.setAccessibilityLabel("中止实时翻译")
            return
        }
        button?.action = nil
        button?.target = nil
        button?.image = idleImage()
        button?.toolTip = "选区翻译"
        button?.setAccessibilityLabel("选区翻译")
        reloadMenu()
    }

    /// 无参数。菜单栏中止执行结束语义，不放弃本次结果。
    /// 作用：MCP 截图开始，菜单栏图标换为采集图标（#96 待确认值：camera.viewfinder，至少保持 1000ms）。
    /// 实时翻译的中止图标优先，期间不切换图标。
    /// 返回：截图结束时调用的回调；到达最短保持时间后计数减一，无进行中截图时恢复普通图标。
    func beginMCPCapture() -> () -> Void {
        mcpCaptures += 1
        updateMCPIcon()
        let started = ContinuousClock.now
        return { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(until: started + AppConstants.mcpCaptureIndicatorMinimum, clock: .continuous)
                guard let self else { return }
                self.mcpCaptures -= 1
                self.updateMCPIcon()
            }
        }
    }

    /// 无参数；按 MCP 截图计数设置非实时翻译状态下的图标，无返回值。
    private func updateMCPIcon() {
        guard !liveAbort else { return }
        statusItem?.button?.image = idleImage()
    }

    /// 无参数；返回非实时翻译状态的模板图标：MCP 截图进行中为采集图标，否则为翻译图标。
    private func idleImage() -> NSImage? {
        let image = mcpCaptures > 0
            ? NSImage(systemSymbolName: AppConstants.mcpCaptureSymbol, accessibilityDescription: "agent 截图中")
            : NSImage(systemSymbolName: "translate", accessibilityDescription: "选区翻译")
                ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "选区翻译")
        image?.isTemplate = true
        return image
    }

    @objc private func abortLive() {
        abortLiveTranslation?()
    }

    /// enabled 为主 Dart 已成功保存的自动按钮设置；更新菜单状态，无返回值。
    func updateAutomatic(_ enabled: Bool) {
        // 菜单勾选表示仅使用快捷键，与底层自动捕获状态相反。
        automaticItem?.state = enabled ? .off : .on
    }

    /// menu 为即将展示的菜单；即时读取权限状态，无返回值。
    func menuWillOpen(_ menu: NSMenu) {
        stopCaptureItem?.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
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

    /// active为连续采集状态；更新提示与停止能力，保持图标入口宽度不变。
    func setCaptureActive(_ active: Bool) {
        if liveAbort { return }
        statusItem?.button?.title = ""
        let description = active ? "选区翻译，采集中" : "选区翻译"
        statusItem?.button?.toolTip = description
        statusItem?.button?.setAccessibilityLabel(description)
        stopCaptureItem?.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
    }

    /// 无参数；请求当前采集正常结束，编码完成前不发布文件。
    @objc private func stopCapture() { MacPlatformBridge.Shared.instance?.capture.stop() }

    /// 无参数；经主 Dart 修改全局开关，成功后刷新设置窗口，无返回值。
    @objc private func toggleAutomatic() {
        // requestApplication把菜单开关交给主引擎唯一设置队列。
        MacPlatformBridge.Shared.instance?.requestApplication(AppConstants.toggleAutomaticMethod) { [weak self] value in
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
