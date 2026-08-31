import AppKit
import SwiftUI
import TranslateCore

/// 非激活浮层：展示 Trigger State 与 Result State，不抢前台应用焦点。
@MainActor
final class OverlayPanelController {
    var onActivate: (() async -> Void)?
    var onDismiss: (() -> Void)?

    private let session: SelectionSessionController
    private let panel: TranslationPanel
    private let hosting: NonActivatingHostingView<OverlayView>
    private var anchor = CGPoint.zero

    init(session: SelectionSessionController) {
        self.session = session
        let root = OverlayView(session: session, onActivate: {}, onDismiss: {}, onContentChange: {})
        hosting = NonActivatingHostingView(rootView: root)
        panel = TranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 88, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = hosting

        hosting.rootView = OverlayView(
            session: session,
            onActivate: { [weak self] in await self?.onActivate?() },
            onDismiss: { [weak self] in
                self?.onDismiss?()
                self?.panel.orderOut(nil)
            },
            onContentChange: { [weak self] in
                self?.syncFrame()
            }
        )
    }

    func contains(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    func present(snapshot: TranslationSnapshot, near point: CGPoint) {
        anchor = point
        if snapshot.phase == .idle {
            panel.orderOut(nil)
            return
        }
        syncFrame()
        // 只前置，不成为 Key Window，避免源应用失活、选区高亮消失。
        panel.orderFrontRegardless()
    }

    private func syncFrame() {
        hosting.invalidateIntrinsicContentSize()
        var size = hosting.fittingSize
        if size.width < 72 { size.width = 72 }
        if size.height < 32 { size.height = 32 }

        var origin = CGPoint(x: anchor.x + 8, y: anchor.y - size.height - 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// 拒绝成为 Key / Main，点击也不激活 TranslateApp。
final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI 默认 HostingView 会抢 first responder；关掉后点击不会把源应用挤掉。
final class NonActivatingHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
