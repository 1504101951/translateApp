import AppKit

/// 鼠标拖拽/双击/三击上报给 Dart。不监听 Command-A（#11）。
final class SelectionMonitor {
    private var detector = SelectionGestureDetector()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var escapeMonitor: Any?

    func start() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let type = event.type
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
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
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                MacPlatformBridge.Shared.instance?.emitEscape()
            }
        }
        _ = AccessibilitySelection.isTrusted(prompt: true)
    }

    @MainActor
    private func consumeMouse(type: NSEvent.EventType, clickCount: Int, location: NSPoint) {
        let kind: MousePointerEvent.Kind?
        switch type {
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        default: kind = nil
        }
        guard let kind else { return }
        if MacPlatformBridge.Shared.instance?.overlayContains(location) == true {
            return
        }
        let pointer = MousePointerEvent(kind: kind, clickCount: clickCount, x: location.x, y: location.y)
        guard let gesture = detector.handle(pointer) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            let selection = await AccessibilitySelection.readFrontmostSelection()
            guard let text = selection.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            let anchor = OverlayAnchor.point(mouse: location, bounds: selection.bounds)
            MacPlatformBridge.Shared.instance?.emitSelectionCaptured(
                text: text,
                gesture: gesture.rawValue,
                x: anchor.x,
                y: anchor.y
            )
        }
    }
}
