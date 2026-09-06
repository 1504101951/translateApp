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

    /// 无参数；创建不能成为 key/main 的透明浮层。
    init() {
        panel = TranslationPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 来源 App 的浮动窗口可能反复置前；更高层级保持译文可见，仍不取得 key/main。
        panel.level = .statusBar
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
        panel.orderFrontRegardless()
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
        guard currentSessionId == sessionId else { return }
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

    /// sessionId 标识会话；将该窗口原始按下事件交给系统拖动，无返回值。
    func drag(sessionId: String) {
        guard currentSessionId == sessionId, let event = dragStartEvent,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        dragStartEvent = nil
        panel.performDrag(with: event)
    }
}

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
