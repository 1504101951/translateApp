import AppKit
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

    private func handle(gesture: SelectionGesture, mouse: CGPoint) async {
        if overlay.contains(mouse) { return }
        accessibilityTrusted = AccessibilitySelection.isTrusted(prompt: false)
        let selection = await AccessibilitySelection.readFrontmostSelection()
        session.beginSession(from: gesture, text: selection.text)
        if let bounds = selection.bounds {
            anchor = CGPoint(x: bounds.midX, y: bounds.minY)
        } else {
            anchor = mouse
        }
        overlay.present(snapshot: session.snapshot, near: anchor)
    }
}
