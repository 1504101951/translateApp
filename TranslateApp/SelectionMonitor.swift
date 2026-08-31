import AppKit
import TranslateCore

/// 监听左键指针事件，以及 Command-A / Escape。其他键盘选区不订阅。
@MainActor
final class SelectionMonitor {
    var onGesture: ((SelectionGesture, CGPoint) -> Void)?
    var onEscape: (() -> Void)?

    private var detector = SelectionGestureDetector()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    func start() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let kind = Self.kind(from: event)
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.consumeMouse(kind: kind, clickCount: clickCount, location: location)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let kind = Self.kind(from: event)
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.consumeMouse(kind: kind, clickCount: clickCount, location: location)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let press = Self.keyPress(from: event)
            Task { @MainActor in
                self?.consumeKey(press)
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let press = Self.keyPress(from: event)
            Task { @MainActor in
                self?.consumeKey(press)
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

    nonisolated private static func keyPress(from event: NSEvent) -> KeyPress {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyPress(
            keyCode: event.keyCode,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }

    private func consumeMouse(kind: MousePointerEvent.Kind?, clickCount: Int, location: CGPoint) {
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

    private func consumeKey(_ press: KeyPress) {
        if HotKeyRecognizer.isEscape(press) {
            onEscape?()
            return
        }
        guard let gesture = HotKeyRecognizer.selectionGesture(for: press) else { return }
        let location = NSEvent.mouseLocation
        // Command-A 之后系统需要一点时间填好选区。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.onGesture?(gesture, location)
        }
    }
}
