import AppKit
import Carbon
import ApplicationServices

/// 将鼠标、键盘和来源应用变化映射为选区事件；不处理翻译业务。
final class SelectionMonitor {
    private(set) var automatic = false
    private var excludedApps: Set<String> = []
    /// 已注册的全局热键；键为用途，值为系统热键 ID、组合与注册引用，按用途查找避免多组平行变量。
    private var hotKeys: [GlobalHotKey: RegisteredHotKey] = [:]
    private var nextHotKeyId: UInt32 = 1
    var isCapturingScreenshot = false
    private var hotKeyHandler: EventHandlerRef?
    private var detector = SelectionGestureDetector()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var keyboardMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var selectionObserver: AXObserver?
    private var observedPID: pid_t?
    private var selectionElement: AXUIElement?
    private var validationTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var ignoreMouseGesture = false
    private var pendingKeySelection: (keyCode: UInt16, gesture: SelectionGesture)?

    /// 一个已注册的全局热键；id 为系统回调中的热键标识，binding 为组合，reference 为注销用的系统引用。
    struct RegisteredHotKey {
        let id: UInt32
        let binding: HotKeyBinding
        let reference: EventHotKeyRef
    }

    /// 一个快捷键组合；keyCode 为硬件键码，modifiers 为 Carbon 修饰键位。
    struct HotKeyBinding: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// automatic/excludedApps 为选区采集配置，shortcuts 为三种用途各自的组合，均来自 Dart。
    /// 全部新组合注册成功后才替换旧配置；组合非法、重复或被占用时抛出错误并保留原注册。
    func configure(automatic: Bool, excludedApps: Set<String>, shortcuts: [GlobalHotKey: HotKeyBinding]) throws {
        guard Set(GlobalHotKey.allCases) == Set(shortcuts.keys) else {
            throw NSError(domain: AppConstants.errorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "全局快捷键配置不完整。"])
        }
        for binding in shortcuts.values {
            try Self.validateShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
        guard Set(shortcuts.values).count == shortcuts.count else {
            throw NSError(domain: AppConstants.errorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: "翻译、输入翻译与截图快捷键不能相同。"])
        }
        if hotKeyHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // 必须挂在 dispatcher：Application 目标只在本 App 前台时收热键。
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard identifier.signature == 0x5452414E else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in
                    guard let entry = monitor.hotKeys.first(where: { $0.value.id == identifier.id }) else { return }
                    // 录制快捷键时，已注册组合被系统吞掉，直接把组合交给录制方。
                    if let recorder = MacPlatformBridge.Shared.instance?.shortcutRecorder {
                        recorder(entry.value.binding.keyCode, entry.value.binding.modifiers)
                        return
                    }
                    switch entry.key {
                    case .screenshot:
                        MacPlatformBridge.Shared.instance?.screenshot.capture()
                    case .translate:
                        // 翻译热键复用选区读取，不激活 TranslateApp。
                        monitor.capture(gesture: .hotkey)
                    case .input:
                        // 输入翻译读取当前输入，完成后由 Dart 请求替换原文。
                        monitor.capture(gesture: .inputHotkey)
                    }
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        var replacements: [GlobalHotKey: RegisteredHotKey] = [:]
        var created: [EventHotKeyRef] = []
        do {
            // 已注册的组合可直接换用途：交换任意两个快捷键无需释放系统占用。
            for purpose in GlobalHotKey.allCases {
                let binding = shortcuts[purpose]!
                if let existing = hotKeys.values.first(where: { $0.binding == binding }) {
                    replacements[purpose] = RegisteredHotKey(id: existing.id, binding: binding, reference: existing.reference)
                    continue
                }
                var reference: EventHotKeyRef?
                let id = nextHotKeyId
                nextHotKeyId += 1
                let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x5452414E, id: id), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
                guard status == noErr, let reference else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "快捷键已被占用，请换一个组合。"])
                }
                created.append(reference)
                replacements[purpose] = RegisteredHotKey(id: id, binding: binding, reference: reference)
            }
        } catch {
            for reference in created { UnregisterEventHotKey(reference) }
            throw error
        }
        // 新配置不再使用的旧组合才注销，复用的组合保留系统占用。
        for old in hotKeys.values where !replacements.values.contains(where: { $0.id == old.id }) {
            UnregisterEventHotKey(old.reference)
        }
        hotKeys = replacements
        self.automatic = automatic
        self.excludedApps = excludedApps
        detector = SelectionGestureDetector()
        pendingKeySelection = nil
        captureTask?.cancel()
        stopObservingSelection()
        MacPlatformBridge.Shared.instance?.invalidateSelection()
    }

    /// keyCode/modifiers 为待注册组合；拒绝普通输入与已启用的系统保留键，成功无返回值。
    static func validateShortcut(keyCode: UInt32, modifiers: UInt32) throws {
        guard keyCode <= 127, keyCode != UInt32(AppConstants.escapeKeyCode),
              modifiers & AppConstants.shortcutRequiredModifiers != 0,
              modifiers & ~AppConstants.shortcutAllowedModifiers == 0 else {
            throw NSError(domain: AppConstants.errorDomain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "快捷键至少需要 Control、Option 或 Command，并搭配一个非 Esc 按键。",
            ])
        }
        var shortcuts: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&shortcuts)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        for item in shortcuts?.takeRetainedValue() as? [[String: Any]] ?? [] {
            if item[kHISymbolicHotKeyEnabled as String] as? Bool == true,
               item[kHISymbolicHotKeyCode as String] as? UInt32 == keyCode,
               item[kHISymbolicHotKeyModifiers as String] as? UInt32 == modifiers {
                throw NSError(domain: AppConstants.errorDomain, code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "这个组合已用于 macOS 系统快捷键，请换一个组合。",
                ])
            }
        }
    }

    /// 无参数；安装不吞掉原应用输入的全局监听，无返回值。
    func start() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let type = event.type
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                // 同一路径处理本地浮层与外部应用的鼠标事件。
                self?.consumeMouse(type: type, clickCount: clickCount, location: location)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let type = event.type
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.consumeMouse(type: type, clickCount: clickCount, location: location)
            }
        }
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let type = event.type
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            Task { @MainActor in
                // keyUp 时来源应用已经完成选区更新，监听不消费键盘事件。
                self?.consumeKey(type: type, keyCode: keyCode, modifiers: modifiers)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.captureTask?.cancel()
                self?.pendingKeySelection = nil
                self?.stopObservingSelection()
                // 比较来源 PID，不把非激活浮层的显示当作应用切换。
                MacPlatformBridge.Shared.instance?.sourceApplicationChanged(to: app?.processIdentifier)
            }
        }
    }

    /// 无参数；释放事件监听和待完成读取，防止残留回调。
    deinit {
        for registered in hotKeys.values { UnregisterEventHotKey(registered.reference) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        captureTask?.cancel()
        validationTask?.cancel()
        for monitor in [localMouseMonitor, globalMouseMonitor, keyboardMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let selectionObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(selectionObserver), .commonModes)
        }
    }

    /// type/clickCount 为鼠标事件，location 为屏幕坐标；识别选区或结束旧会话，无返回值。
    @MainActor
    private func consumeMouse(type: NSEvent.EventType, clickCount: Int, location: NSPoint) {
        guard !isCapturingScreenshot else { return }
        let bridge = MacPlatformBridge.Shared.instance
        if type == .leftMouseDown {
            pendingKeySelection = nil
            // 浮层内发起的整次拖动都忽略，即使指针随后离开了浮层。
            ignoreMouseGesture = bridge?.overlayContains(location) == true
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        }
        guard !ignoreMouseGesture else { return }
        let kind: MousePointerEvent.Kind
        switch type {
        case .leftMouseDown:
            captureTask?.cancel()
            stopObservingSelection()
            bridge?.invalidateSelection()
            kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        default: return
        }
        guard automatic else { return }
        let pointer = MousePointerEvent(kind: kind, clickCount: clickCount, x: location.x, y: location.y)
        // 检测器仅在拖选、双击或三击完成时产出手势。
        guard let gesture = detector.handle(pointer) else { return }
        capture(gesture: gesture)
    }

    /// type/keyCode/modifiers 为原始键盘事件；处理 Escape 和选择手势，无返回值。
    @MainActor
    private func consumeKey(type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard !isCapturingScreenshot else { return }
        let bridge = MacPlatformBridge.Shared.instance
        if keyCode == AppConstants.escapeKeyCode, type == .keyDown {
            pendingKeySelection = nil
            captureTask?.cancel()
            stopObservingSelection()
            bridge?.invalidateSelection(eventType: AppConstants.escapePressedMethod)
            return
        }
        if automatic, type == .keyDown {
            // 修饰键可能先于方向键释放，因此在按下时记住手势，不保存输入字符。
            if let gesture = SelectionGesture.keyboardGesture(keyCode: keyCode, modifiers: modifiers) {
                pendingKeySelection = (keyCode, gesture)
            }
            return
        }
        guard type == .keyUp else { return }
        if let pending = pendingKeySelection, pending.keyCode == keyCode {
            pendingKeySelection = nil
            // 非激活浮层不接收键盘焦点，鼠标悬停位置不能屏蔽来源应用的扩选。
            capture(gesture: pending.gesture)
            return
        }
        if bridge?.hasSelection == true, observedPID != nil {
            // 不支持 AX 通知的应用仍可在普通输入清空选区时结束会话。
            validateSelection()
        }
    }

    /// gesture 为选区手势；去抖读取文本，在上报时获取当前鼠标位置，无返回值。
    @MainActor
    private func capture(gesture: SelectionGesture) {
        guard !isCapturingScreenshot else { return }
        // 保留的译文框不消费新的被动选区；全局热键仍可明确发起下一次翻译。
        guard gesture.isExplicit || MacPlatformBridge.Shared.instance?.retainsResult != true else { return }
        captureTask?.cancel()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(),
              !excludedApps.contains(app.bundleIdentifier ?? "") else { return }
        let pid = app.processIdentifier
        // 在原文采集开始时冻结来源名称，不在异步完成后重新按PID查询。
        let sourceAppName = app.localizedName
        captureTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            // 读取绑定手势来源，切换应用或新手势会取消本次读取。
            var selection = await AccessibilitySelection.readFrontmostSelection(sourcePID: pid, allowCopy: gesture.isExplicit)
            // 输入翻译读不到选区时，在非安全文本输入框内全选后再读，替换整个输入框。
            if gesture == .inputHotkey, (selection.text ?? "").isEmpty, !Task.isCancelled,
               AccessibilitySelection.selectAllInFocusedTextInput(sourcePID: pid) {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                selection = await AccessibilitySelection.readFrontmostSelection(sourcePID: pid, allowCopy: true)
            }
            guard self?.isCapturingScreenshot != true, !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  gesture.isExplicit || MacPlatformBridge.Shared.instance?.retainsResult != true else { return }
            let text = selection.text ?? ""
            let keyboardCandidate = (gesture == .selectAll || gesture == .keyboard)
                && AccessibilitySelection.permitsKeyboardTrigger(sourcePID: pid)
            // 明确热键即使读不到文字也要展示失败卡片，不能静默丢弃用户操作。
            guard gesture.isExplicit || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyboardCandidate else {
                MacPlatformBridge.Shared.instance?.invalidateSelection()
                return
            }
            // 异步读取完成后以最新鼠标位置定位新会话；输入翻译另取选中区域作为失败气泡锚点（#99）。
            let anchor = NSEvent.mouseLocation
            MacPlatformBridge.Shared.instance?.emitSelectionCaptured(
                text: text, gesture: gesture.rawValue, x: anchor.x, y: anchor.y, sourcePID: pid, sourceAppName: sourceAppName,
                inputAnchor: gesture == .inputHotkey ? AccessibilitySelection.inputAnchor(sourcePID: pid) : nil
            )
            // 选区通知覆盖程序清空与控件焦点变化，不需要轮询剪贴板。
            self?.watchSelection(sourcePID: pid, selectionElement: selection.element)
        }
    }

    /// sourcePID 为来源，selectionElement 为实际文字节点；注册焦点和选区通知，无返回值。
    @MainActor
    private func watchSelection(sourcePID: pid_t, selectionElement: AXUIElement?) {
        stopObservingSelection()
        observedPID = sourcePID
        self.selectionElement = selectionElement
        let app = AXUIElementCreateApplication(sourcePID)
        guard let element = AccessibilitySelection.focusedElement(from: app) else { return }
        var observer: AXObserver?
        let status = AXObserverCreate(sourcePID, { observer, _, _, context in
            guard let context else { return }
            let monitor = Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                guard let active = monitor.selectionObserver, CFEqual(active, observer),
                      monitor.observedPID != nil else { return }
                // Chrome 会重复发送焦点通知；通知名本身不能证明选区失效。
                monitor.validateSelection()
            }
        }, &observer)
        guard status == .success, let observer else { return }
        selectionObserver = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, context)
        AXObserverAddNotification(observer, selectionElement ?? element, kAXSelectedTextChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// 无参数；合并 AX/键盘通知，以实际文字节点确认清空；焦点容器变化本身不结束会话。
    @MainActor
    private func validateSelection() {
        validationTask?.cancel()
        guard let pid = observedPID else { return }
        validationTask = Task { @MainActor [weak self] in
            // AX 通知可能先于浏览器选区树更新到达；与捕获使用同一个 80ms 稳定窗口。
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, self.observedPID == pid else { return }
            // 焦点可能在同一浏览器文本树内迁移；不可读保持未知，不能由节点身份变化推断清空。
            if AccessibilitySelection.hasReadableSelection(sourcePID: pid, selectionElement: self.selectionElement) == false {
                MacPlatformBridge.Shared.instance?.invalidateSelection()
                self.stopObservingSelection()
            }
        }
    }

    /// 无参数；移除旧来源的 AX 监听，防止旧应用通知关闭新会话，无返回值。
    private func stopObservingSelection() {
        validationTask?.cancel()
        validationTask = nil
        if let selectionObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(selectionObserver), .commonModes)
        }
        selectionObserver = nil
        observedPID = nil
        selectionElement = nil
    }
}
