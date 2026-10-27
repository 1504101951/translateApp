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
    /// 「取消延时截图」只在倒计时期间显示；「截取上次区域」只在有记录时可用；显示器子菜单在菜单打开时重建（#105）。
    private var cancelDelayItem: NSMenuItem?
    private var lastRegionItem: NSMenuItem?
    private var displayMenu: NSMenu?
    /// 延时截图的剩余秒数与倒计时任务；没有倒计时时均为 nil。
    private var countdown: Int?
    private var delayTask: Task<Void, Never>?
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
        applyIdleLabel(to: item.button)
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
        // 截图编辑工具栏承载媒体工具，菜单栏保留普通截图、捕获选项和采集停止。
        let cancelDelay = NSMenuItem(title: "取消延时截图", action: #selector(cancelDelay), keyEquivalent: "")
        cancelDelay.target = self
        cancelDelay.isHidden = countdown == nil
        cancelDelayItem = cancelDelay
        menu.addItem(cancelDelay)
        let screenshot = NSMenuItem(title: "区域截图…", action: #selector(captureScreenshot), keyEquivalent: "")
        screenshot.target = self
        menu.addItem(screenshot)
        let lastRegion = NSMenuItem(title: "截取上次区域", action: #selector(captureLastRegion), keyEquivalent: "")
        lastRegion.target = self
        lastRegion.isEnabled = ScreenshotRegion.saved != nil
        lastRegionItem = lastRegion
        menu.addItem(lastRegion)
        let displays = NSMenuItem(title: "截取显示器", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        displays.submenu = displayMenu
        self.displayMenu = displayMenu
        menu.addItem(displays)
        let delay = NSMenuItem(title: "延时截图", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        delayMenu.autoenablesItems = false
        for seconds in AppConstants.screenshotDelays {
            let item = NSMenuItem(title: "\(seconds) 秒", action: #selector(startDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            delayMenu.addItem(item)
        }
        delay.submenu = delayMenu
        menu.addItem(delay)
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
        let access = NSMenuItem(title: "", action: #selector(requestAccess), keyEquivalent: "")
        accessItem = access
        access.target = self
        applyAccessState(to: access, trusted: trusted)
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
        applyIdleLabel(to: button)
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

    /// 无参数；返回非实时翻译状态的模板图标：延时截图倒计时为剩余秒数，MCP 截图进行中为采集图标，否则为翻译图标。
    private func idleImage() -> NSImage? {
        if let countdown {
            let image = NSImage(systemSymbolName: "\(countdown).circle", accessibilityDescription: "\(countdown) 秒后截图")
            image?.isTemplate = true
            return image
        }
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

    /// menu 为即将展示的菜单；即时读取权限、倒计时、上次区域与显示器列表，无返回值。
    func menuWillOpen(_ menu: NSMenu) {
        stopCaptureItem?.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
        cancelDelayItem?.isHidden = countdown == nil
        lastRegionItem?.isEnabled = ScreenshotRegion.saved != nil
        // 显示器可能在两次打开菜单之间接入或断开，按当前系统顺序重建。
        displayMenu?.removeAllItems()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let item = NSMenuItem(title: screen.localizedName, action: #selector(captureDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            displayMenu?.addItem(item)
        }
        let trusted = AccessibilitySelection.isTrusted(prompt: false)
        if let accessItem { applyAccessState(to: accessItem, trusted: trusted) }
    }

    /// item 为辅助功能菜单项，trusted 为是否已获得辅助功能权限；已授权时显示已开启且不可点，无返回值。
    private func applyAccessState(to item: NSMenuItem, trusted: Bool) {
        item.title = trusted ? "辅助功能已开启" : "授予辅助功能权限…"
        item.isEnabled = !trusted
    }

    /// button 为菜单栏图标按钮；写入空闲态的悬停提示与辅助功能名称，无返回值。
    private func applyIdleLabel(to button: NSStatusBarButton?) {
        button?.toolTip = "选区翻译"
        button?.setAccessibilityLabel("选区翻译")
    }

    /// 无参数；打开普通设置窗口，无返回值。
    @objc private func openSettings() { showSettings?() }

    /// 无参数；打开翻译历史窗口，无返回值。
    @objc private func openHistory() { showHistory?() }

    /// 无参数；菜单关闭后进入系统区域框选，不触发翻译，无返回值。
    @objc private func captureScreenshot() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture() }
    }

    /// 无参数；冻结上次导出选区所在显示器并选中同一区域，无返回值（#105）。
    @objc private func captureLastRegion() {
        // 菜单项只在已有上次区域时可用。
        let region = ScreenshotRegion.saved!
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture(.lastRegion(region)) }
    }

    /// sender 的 tag 为显示器 ID；冻结该显示器并选中整屏，无返回值（#105）。
    @objc private func captureDisplay(_ sender: NSMenuItem) {
        let id = CGDirectDisplayID(sender.tag)
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture(.display(id)) }
    }

    /// sender 的 tag 为倒计时秒数；开始延时截图，无返回值（#105）。
    @objc private func startDelay(_ sender: NSMenuItem) { startDelayedCapture(seconds: sender.tag) }

    /// 无参数；取消延时截图，无返回值（#105）。
    @objc private func cancelDelay() { cancelDelayedCapture() }

    /// 无参数；返回是否有未结束的延时截图。
    var isDelayingCapture: Bool { delayTask != nil }

    /// seconds 为倒计时秒数；每秒把菜单栏图标换为剩余秒数，到时恢复图标后截取指针所在显示器，无返回值（#105）。
    func startDelayedCapture(seconds: Int) {
        cancelDelayedCapture()
        delayTask = Task { @MainActor [weak self] in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self?.showCountdown(remaining)
                try? await Task.sleep(for: .seconds(1))
                // 取消时由 cancelDelayedCapture 恢复图标。
                guard !Task.isCancelled else { return }
            }
            self?.delayTask = nil
            self?.showCountdown(nil)
            // 下一拍再冻结画面，菜单栏先重绘为原图标，倒计时不进入截图。
            DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture() }
        }
    }

    /// 无参数；取消未结束的延时截图并恢复图标，没有倒计时时保持原状，无返回值。
    func cancelDelayedCapture() {
        guard let delayTask else { return }
        delayTask.cancel()
        self.delayTask = nil
        showCountdown(nil)
    }

    /// remaining 为剩余秒数，nil 表示倒计时结束；更新菜单栏图标，实时翻译的中止图标优先，无返回值。
    private func showCountdown(_ remaining: Int?) {
        countdown = remaining
        guard !liveAbort else { return }
        statusItem?.button?.image = idleImage()
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
