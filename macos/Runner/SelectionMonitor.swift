import AppKit
import ApplicationServices

/// 将鼠标、键盘和来源应用变化映射为选区事件；不处理翻译业务。
final class SelectionMonitor {
    private var detector = SelectionGestureDetector()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var keyboardMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var selectionObserver: AXObserver?
    private var observedPID: pid_t?
    private var captureTask: Task<Void, Never>?
    private var ignoreMouseGesture = false
    private var pendingKeySelection: (keyCode: UInt16, gesture: SelectionGesture)?

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
        captureTask?.cancel()
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
        let pointer = MousePointerEvent(kind: kind, clickCount: clickCount, x: location.x, y: location.y)
        // 检测器仅在拖选、双击或三击完成时产出手势。
        guard let gesture = detector.handle(pointer) else { return }
        capture(gesture: gesture, location: location)
    }

    /// type/keyCode/modifiers 为原始键盘事件；处理 Escape 和选择手势，无返回值。
    @MainActor
    private func consumeKey(type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let bridge = MacPlatformBridge.Shared.instance
        if keyCode == 53, type == .keyDown {
            pendingKeySelection = nil
            captureTask?.cancel()
            stopObservingSelection()
            bridge?.invalidateSelection(eventType: "escapePressed")
            return
        }
        if type == .keyDown {
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
            capture(gesture: pending.gesture, location: NSEvent.mouseLocation)
            return
        }
        if bridge?.hasSelection == true, let pid = observedPID {
            // 不支持 AX 通知的应用仍可在普通输入清空选区时结束会话。
            if !AccessibilitySelection.hasReadableSelection(sourcePID: pid) { bridge?.invalidateSelection() }
        }
    }

    /// gesture 为选区手势，location 为鼠标锚点；去抖读取并上报当前前台应用的文本，无返回值。
    @MainActor
    private func capture(gesture: SelectionGesture, location: NSPoint) {
        captureTask?.cancel()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        captureTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            // 读取绑定手势来源，切换应用或新手势会取消本次读取。
            let selection = await AccessibilitySelection.readFrontmostSelection(sourcePID: pid)
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let text = selection.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                MacPlatformBridge.Shared.instance?.invalidateSelection()
                return
            }
            // 键盘选择时鼠标可停在远处，优先使用真实选区的屏幕矩形。
            let anchor: NSPoint
            if (gesture == .selectAll || gesture == .keyboard), let bounds = selection.bounds, !bounds.isEmpty {
                anchor = NSPoint(x: bounds.midX, y: bounds.minY)
            } else {
                anchor = OverlayAnchor.point(mouse: location, bounds: selection.bounds)
            }
            MacPlatformBridge.Shared.instance?.emitSelectionCaptured(
                text: text, gesture: gesture.rawValue, x: anchor.x, y: anchor.y, sourcePID: pid
            )
            // 选区通知覆盖程序清空与控件焦点变化，不需要轮询剪贴板。
            self?.watchSelection(sourcePID: pid)
        }
    }

    /// sourcePID 为会话来源；注册焦点和选区变化通知，无返回值。
    @MainActor
    private func watchSelection(sourcePID: pid_t) {
        stopObservingSelection()
        observedPID = sourcePID
        let app = AXUIElementCreateApplication(sourcePID)
        guard let element = AccessibilitySelection.focusedElement(from: app) else { return }
        var observer: AXObserver?
        let status = AXObserverCreate(sourcePID, { observer, _, notification, context in
            guard let context else { return }
            let monitor = Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue()
            let name = notification as String
            Task { @MainActor in
                guard let active = monitor.selectionObserver, CFEqual(active, observer),
                      let pid = monitor.observedPID else { return }
                if name == kAXFocusedUIElementChangedNotification
                    || !AccessibilitySelection.hasReadableSelection(sourcePID: pid) {
                    MacPlatformBridge.Shared.instance?.invalidateSelection()
                }
            }
        }, &observer)
        guard status == .success, let observer else { return }
        selectionObserver = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, context)
        AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// 无参数；移除旧来源的 AX 监听，防止旧应用通知关闭新会话，无返回值。
    private func stopObservingSelection() {
        if let selectionObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(selectionObserver), .commonModes)
        }
        selectionObserver = nil
        observedPID = nil
    }
}
