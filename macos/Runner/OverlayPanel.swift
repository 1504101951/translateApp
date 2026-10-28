import AppKit
import FlutterMacOS

/// 非激活窗口只承载 Flutter 内容；拖动、显隐和屏幕边界由原生处理。
final class OverlayPanelController {
    var isPanelVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    private let panel: TranslationPanel
    private let host = OverlayHostViewController()
    private var currentSessionId: String?
    private var mouseMonitor: Any?
    private var dragStartEvent: NSEvent?
    private var capturedSessionId: String?
    private var captureHidden = false

    /// 无参数；创建不能成为 key/main 的透明浮层。
    init() {
        panel = TranslationPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Warp 等来源 App 的置顶窗口可能位于 status-bar 及以上并反复置前；screenSaver 层级保持译文可见，仍不取得 key/main。
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentViewController = host
        // AppKit 要求最初的 mouseDown；跨 Flutter 通道后 currentEvent 已不可靠。
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            self.dragStartEvent = event.type == .leftMouseDown && event.window === self.panel ? event : nil
            return event
        }
    }

    /// 无参数、无返回值；释放窗口鼠标监听，避免旧控制器残留。
    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    /// point 为 AppKit 屏幕坐标；返回它是否位于可见浮层中。
    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    /// controller 为共享 Flutter 引擎的视图控制器；挂载内容，无返回值。
    func attachFlutter(_ controller: FlutterViewController) {
        // child controller 保持引擎及视图生命周期一致。
        host.embed(controller)
    }

    /// point 为选区锚点，size 为完整内容尺寸，sessionId 为会话；显示窗口，无返回值。
    func show(at point: NSPoint, size: NSSize, sessionId: String) {
        currentSessionId = sessionId
        dragStartEvent = nil
        var frame = NSRect(x: point.x + 8, y: point.y - size.height - 8, width: size.width, height: size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        panel.setFrame(frame, display: true)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        // 显示和交互都不调用 activate / makeKey，键盘继续留在来源应用。
        if captureHidden { capturedSessionId = sessionId } else { panel.orderFrontRegardless() }
    }

    /// sessionId 标识要关闭的会话；过期指令不影响当前窗口，无返回值。
    func hide(sessionId: String) {
        guard currentSessionId == sessionId else { return }
        currentSessionId = nil
        dragStartEvent = nil
        panel.orderOut(nil)
    }

    /// sessionId 标识会话，size 为内容尺寸；保留左上角并夹取屏幕边界，无返回值。
    func resize(sessionId: String, size: NSSize) {
        // 流式译文反复通知同一尺寸，不能在系统拖动期间重新夹取窗口位置。
        guard currentSessionId == sessionId, panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let screen = panel.screen {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        panel.setFrame(frame, display: true)
    }

    /// hidden 表示系统正在框选；临时排除翻译浮层，完成后只恢复仍有效的会话，无返回值。
    func setCaptureHidden(_ hidden: Bool) {
        captureHidden = hidden
        if hidden {
            capturedSessionId = panel.isVisible ? currentSessionId : nil
            panel.orderOut(nil)
        } else {
            if let capturedSessionId, capturedSessionId == currentSessionId { panel.orderFrontRegardless() }
            capturedSessionId = nil
        }
    }

    /// sessionId 标识会话；将该窗口原始按下事件交给系统拖动，无返回值。
    func drag(sessionId: String) {
        guard currentSessionId == sessionId, let event = dragStartEvent,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        dragStartEvent = nil
        panel.performDrag(with: event)
    }
}

/// 不可成为key或main的透明浮层窗口；显示译文时不夺取来源应用的键盘焦点。
final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Flutter 填满窗口，圆角裁切不额外占用内容空间。
final class OverlayHostViewController: NSViewController {
    /// 无参数；创建透明圆角容器，无返回值。
    override func loadView() {
        view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 9
        view.layer?.masksToBounds = true
    }

    /// controller 为 Flutter 内容；约束至容器四边，无返回值。
    func embed(_ controller: FlutterViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// 输入翻译失败气泡：非激活玻璃提示，显示在选中区域附近，不抢焦点，样式与长截图提示相同（#99）。
@MainActor
final class InputFailureBubble {
    static let shared = InputFailureBubble()
    private var panel: NSPanel?
    private var generation = 0

    /// message 为失败原因，anchor 为选中区域（AppKit 全局坐标）；替换旧气泡，到时或点击后关闭，无返回值。
    func show(_ message: String, anchor: NSRect) {
        close()
        let padding = AppConstants.scrollHintPadding
        // hintTextSize/hintText 与长截图提示共用文字排版：13/18、最大宽 240pt 换行。
        let textSize = CaptureShadeView.hintTextSize(message, width: AppConstants.scrollHintMaxWidth - padding.width * 2)
        let size = NSSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        // 锚点所在屏；锚点不在任何屏幕上时按主屏放置。
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.screens[0]
        let frame = Self.frame(size: size, anchor: anchor, visible: screen.visibleFrame)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        let label = NSTextField(wrappingLabelWithString: message)
        label.attributedStringValue = CaptureShadeView.hintText(message, isError: true)
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: textSize)
        let content = BubbleClickView(frame: NSRect(origin: .zero, size: size))
        content.onClick = { [weak self] in self?.close() }
        content.addSubview(label)
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = AppConstants.scrollHintRadius
        glass.contentView = content
        panel.contentView = glass
        panel.orderFrontRegardless()
        self.panel = panel
        NSAccessibility.post(element: glass, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        generation += 1
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(AppConstants.inputFailureDurationMs))
            guard let self, self.generation == current else { return }
            self.close()
        }
    }

    /// 无参数；关闭当前气泡，没有气泡时保持原状，无返回值。
    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// size 为气泡尺寸，anchor 为选中区域，visible 为锚点所在屏可用区（均为 AppKit 坐标）；
    /// 返回锚点下方 8pt、放不下时上方 8pt、左边对齐并限制在可用区水平范围内的整点位置。
    nonisolated static func frame(size: NSSize, anchor: NSRect, visible: NSRect) -> NSRect {
        let gap = AppConstants.inputFailureGap
        let below = anchor.minY - gap - size.height
        let y = below >= visible.minY ? below : anchor.maxY + gap
        let x = min(max(anchor.minX, visible.minX), visible.maxX - size.width)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

/// 失败气泡内容视图：非激活面板首次点击即关闭气泡。
private final class BubbleClickView: NSView {
    var onClick: (() -> Void)?

    /// event 为首次点击；非激活面板不先激活应用，返回 true 直接处理。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// event 为鼠标按下；关闭气泡，无返回值。
    override func mouseDown(with event: NSEvent) { onClick?() }
}
