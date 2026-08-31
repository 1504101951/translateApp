import AppKit
import Darwin
import TranslateCore

/// 把鼠标手势、Accessibility 选区和 Translation Overlay 接到同一条 Selection Session。
@MainActor
@Observable
final class AppModel {
    let session: SelectionSessionController
    var accessibilityTrusted: Bool

    private let overlay: OverlayPanelController
    private let monitor = SelectionMonitor()
    private var anchor = CGPoint.zero

    init() {
        let session = SelectionSessionController(provider: DefaultTranslationProvider.unconfigured())
        self.session = session
        self.overlay = OverlayPanelController(session: session)
        self.accessibilityTrusted = AccessibilitySelection.isTrusted(prompt: false)

        overlay.onActivate = { [weak session] in
            await session?.activate()
        }
        overlay.onDismiss = { [weak session] in
            session?.dismiss()
        }

        monitor.onGesture = { [weak self] gesture, mouse in
            Task { await self?.handle(gesture: gesture, mouse: mouse) }
        }
        monitor.onEscape = { [weak self] in
            self?.handleEscape()
        }
        monitor.start()

        if !accessibilityTrusted {
            accessibilityTrusted = AccessibilitySelection.isTrusted(prompt: true)
        }
    }

    func requestAccessibility() {
        accessibilityTrusted = AccessibilitySelection.isTrusted(prompt: true)
        if !accessibilityTrusted {
            AccessibilitySelection.openSettings()
        }
    }

    private func handleEscape() {
        guard session.snapshot.phase != .idle else { return }
        session.dismiss()
        overlay.present(snapshot: .idle, near: anchor)
    }

    private func handle(gesture: SelectionGesture, mouse: CGPoint) async {
        if overlay.contains(mouse) { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return }
        accessibilityTrusted = AccessibilitySelection.isTrusted(prompt: false)
        let selection = await AccessibilitySelection.readFrontmostSelection()
        session.beginSession(from: gesture, text: selection.text)
        // QQ 等应用的 AX 选区矩形经常是假坐标，会把浮层夹到屏幕右下角。
        anchor = OverlayAnchor.point(mouse: mouse, bounds: selection.bounds)
        overlay.present(snapshot: session.snapshot, near: anchor)
    }
}
