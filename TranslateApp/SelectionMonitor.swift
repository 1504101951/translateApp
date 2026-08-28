import AppKit
import TranslateCore

/// 只监听左键指针事件，把完成的 Selection Gesture 交给应用层。
///
/// 不订阅键盘，因此键盘创建的选区不会开始 Selection Session。
@MainActor
final class SelectionMonitor {
    var onGesture: ((SelectionGesture, CGPoint) -> Void)?

    private var detector = SelectionGestureDetector()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let kind = Self.kind(from: event)
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.consume(kind: kind, clickCount: clickCount, location: location)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let kind = Self.kind(from: event)
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.consume(kind: kind, clickCount: clickCount, location: location)
            }
        }
    }

    nonisolated private static func kind(from event: NSEvent) -> MousePointerEvent.Kind? {
        switch event.type {
        case .leftMouseDown:
            return .down
        case .leftMouseDragged:
            return .dragged
        case .leftMouseUp:
            return .up
        default:
            return nil
        }
    }

    private func consume(kind: MousePointerEvent.Kind?, clickCount: Int, location: CGPoint) {
        guard let kind else { return }
        let pointer = MousePointerEvent(
            kind: kind,
            clickCount: clickCount,
            x: location.x,
            y: location.y
        )
        guard let gesture = detector.handle(pointer) else { return }

        // AX 选区在 mouseUp 当下有时尚未写完，短暂让出再读。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            self.onGesture?(gesture, location)
        }
    }
}
