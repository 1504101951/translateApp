import ApplicationServices
import AppKit
import Darwin
import Foundation
import TranslateCore

/// 从前台应用读取当前选区和选区矩形。
///
/// 先走 Accessibility。Chromium / Electron 要先打开 AXManualAccessibility。
/// 仍读不到时，用一次可还原的 Command-C；剪贴板 changeCount 不变则不当成选区。
enum AccessibilitySelection {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    /// - Returns: `text` 为当前选区；不可读时为 nil。`bounds` 为屏幕坐标下的选区矩形。
    static func readFrontmostSelection() async -> (text: String?, bounds: CGRect?) {
        guard let running = NSWorkspace.shared.frontmostApplication else {
            return (nil, nil)
        }
        if running.processIdentifier == getpid() {
            return (nil, nil)
        }

        let app = AXUIElementCreateApplication(running.processIdentifier)
        enableManualAccessibility(app)

        var result = readOnce(app: app)
        if isUsable(result.text) {
            return result
        }

        // Chromium 第一次打开辅助功能树需要一点时间。
        for delay in [80, 180] {
            try? await Task.sleep(for: .milliseconds(delay))
            result = readOnce(app: app)
            if isUsable(result.text) {
                return result
            }
        }

        if isSecure(focusedElement(from: app)) {
            return (nil, nil)
        }

        let copyRoles = focusedElement(from: app).map(ancestorRoles(of:)) ?? []
        if TextSelectionContext.shouldCopyFallback(ancestorRoles: copyRoles),
           let copied = await readByCopyingSelection() {
            return (copied, result.bounds)
        }

        return result
    }

    private static func readOnce(app: AXUIElement) -> (text: String?, bounds: CGRect?) {
        var candidates: [AXUIElement] = []
        if let focused = focusedElement(from: app) {
            candidates.append(focused)
        }
        if let systemFocused = systemFocusedElement(), !candidates.contains(where: { CFEqual($0, systemFocused) }) {
            candidates.append(systemFocused)
        }

        for element in candidates {
            if isSecure(element) {
                return (nil, nil)
            }
            let roles = ancestorRoles(of: element)
            if !TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) {
                continue
            }
            if let hit = selection(from: element) {
                return (hit.text, hit.bounds)
            }
        }

        if let hit = searchSelectedText(roots: candidates) {
            return (hit.text, hit.bounds)
        }

        return (nil, nil)
    }

    private static func enableManualAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func focusedElement(from app: AXUIElement) -> AXUIElement? {
        axElement(attribute(app, kAXFocusedUIElementAttribute as CFString))
    }

    private static func systemFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return axElement(attribute(system, kAXFocusedUIElementAttribute as CFString))
    }

    private static func axElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func selection(from element: AXUIElement) -> (text: String, bounds: CGRect?)? {
        if let text = stringAttribute(element, kAXSelectedTextAttribute as CFString), isUsable(text) {
            return (text, selectedBounds(of: element))
        }
        if let text = selectedTextFromValue(element), isUsable(text) {
            return (text, selectedBounds(of: element))
        }
        return nil
    }

    private static func selectedTextFromValue(_ element: AXUIElement) -> String? {
        guard let value = stringAttribute(element, kAXValueAttribute as CFString) else { return nil }
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute as CFString) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        guard range.location >= 0, range.length > 0 else { return nil }
        let utf16 = value.utf16
        guard range.location + range.length <= utf16.count else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let end = utf16.index(start, offsetBy: range.length)
        return String(utf16[start..<end])
    }

    private static func searchSelectedText(roots: [AXUIElement]) -> (text: String, bounds: CGRect?)? {
        var queue = roots
        var seen = 0
        while !queue.isEmpty, seen < 80 {
            let element = queue.removeFirst()
            seen += 1
            if isSecure(element) { continue }
            if let nodeRole = role(of: element), TextSelectionContext.nonTextRoles.contains(nodeRole) {
                continue
            }
            if let hit = selection(from: element) {
                return hit
            }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute as CFString) else { return [] }
        guard let array = value as? NSArray else { return [] }
        return array.map { $0 as! AXUIElement }
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as CFString)
    }

    /// 从焦点控件走到窗口，供 Text Selection Context 判断。
    private static func ancestorRoles(of element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element
        var steps = 0
        while let node = current, steps < 16 {
            if let role = role(of: node) {
                roles.append(role)
            }
            current = axElement(attribute(node, kAXParentAttribute as CFString))
            steps += 1
        }
        return roles
    }

    private static func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        let role = role(of: element)
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static func isUsable(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        guard status == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func selectedBounds(of element: AXUIElement) -> CGRect? {
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute as CFString) else { return nil }
        var boundsValue: CFTypeRef?
        let boundsStatus = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        guard boundsStatus == .success, let boundsValue else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }

        let maxY = NSScreen.main?.frame.maxY ?? 0
        rect.origin.y = maxY - rect.origin.y - rect.height
        return rect
    }

    /// Command-C 回退。只有剪贴板真正变化才采用，避免把旧剪贴板当成选区。
    private static func readByCopyingSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let changeCount = pasteboard.changeCount

        postCopyKey()

        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            if pasteboard.changeCount != changeCount {
                let text = pasteboard.string(forType: .string)
                snapshot.restore(pasteboard)
                return isUsable(text) ? text : nil
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        snapshot.restore(pasteboard)
        return nil
    }

    private static func postCopyKey() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let encoded = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }
        return PasteboardSnapshot(items: encoded)
    }

    func restore(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let objects = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(objects)
    }
}
