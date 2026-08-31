import AppKit
import FlutterMacOS

/// 非激活 Overlay 承载窗口。拖动由原生 NSPanel 处理，内容由 Flutter 绘制。
final class OverlayPanelController {
    private let panel: TranslationPanel
    private let dragBar = OverlayDragBar()
    private var flutterController: FlutterViewController?
    private var currentSessionId: String?

    init() {
        panel = TranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false

        let container = NSView(frame: panel.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        dragBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dragBar)
        NSLayoutConstraint.activate([
            dragBar.topAnchor.constraint(equalTo: container.topAnchor),
            dragBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dragBar.heightAnchor.constraint(equalToConstant: 22),
        ])
        panel.contentView = container
        dragBar.panel = panel
    }

    func attachFlutter(_ controller: FlutterViewController) {
        flutterController = controller
        guard let container = panel.contentView else { return }
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: dragBar.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// - Parameters:
    ///   - point: Cocoa 底左原点。
    ///   - sessionId: Dart 当前 Selection Session。过期 id 由调用方丢弃。
    func show(at point: NSPoint, size: NSSize, sessionId: String) {
        currentSessionId = sessionId
        var origin = NSPoint(x: point.x + 8, y: point.y - size.height - 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size.width, height: size.height + 22)), display: true)
        panel.orderFrontRegardless()
    }

    func hide(sessionId: String) {
        guard currentSessionId == sessionId else { return }
        panel.orderOut(nil)
    }

    func resize(sessionId: String, size: NSSize) {
        guard currentSessionId == sessionId else { return }
        var frame = panel.frame
        frame.size = NSSize(width: size.width, height: size.height + 22)
        panel.setFrame(frame, display: true)
    }
}

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 顶部拖动条。NSPanel 原生 `performDrag`，不经过 Flutter。
final class OverlayDragBar: NSView {
    weak var panel: NSPanel?

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        panel?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let handle = NSRect(x: (bounds.width - 36) / 2, y: bounds.midY - 1.5, width: 36, height: 3)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
