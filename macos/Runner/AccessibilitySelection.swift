import ApplicationServices
import AppKit
import Darwin
import Foundation

/// 从前台应用读取当前选区。翻译业务在 Dart。
enum AccessibilitySelection {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// sourcePID 绑定来源，allowCopy 仅在明确翻译时开启；返回文字、AppKit 矩形及实际文字节点。
    static func readFrontmostSelection(sourcePID: pid_t, allowCopy: Bool) async -> (text: String?, bounds: CGRect?, element: AXUIElement?) {
        guard !Task.isCancelled, sourcePID != getpid(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return (nil, nil, nil) }
        let app = AXUIElementCreateApplication(sourcePID)
        // 部分 Electron 应用只有开启手动辅助功能后才暴露文本。
        enableManualAccessibility(app)
        var result = readOnce(app: app)
        for delay in [80, 180] where !isUsable(result.text) {
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return (nil, nil, nil) }
            // 重试期间切换应用时，不能读取或复制另一个应用的内容。
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return (nil, nil, nil) }
            result = readOnce(app: app)
        }
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID,
              !isSecure(focusedElement(from: app)) else { return (nil, nil, nil) }
        let copyRoles = focusedElement(from: app).map(ancestorRoles(of:)) ?? []
        // 网页的 AXSelectedText 会省略段落分隔；一次性复制保留浏览器生成的文本结构。
        if TextSelectionContext.shouldCopySelection(ancestorRoles: copyRoles, hasAXText: isUsable(result.text), allowCopy: allowCopy),
           let copied = await readByCopyingSelection(pasteboard: .general, copy: postCopyKey, accepts: { copied in
               guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return false }
               guard let original = result.text else { return true }
               // 只允许浏览器补回空白；其他文本可能来自用户的新复制，不能恢复旧剪贴板覆盖它。
               return original.filter { !$0.isWhitespace } == copied.filter { !$0.isWhitespace }
           }) {
            return (copied, result.bounds, result.element)
        }
        return result
    }

    /// sourcePID 为来源，selectionElement 为捕获时的文字节点；true 有选区，false 确认失效，nil 不可读。
    static func hasReadableSelection(sourcePID: pid_t, selectionElement: AXUIElement?) -> Bool? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return false }
        let app = AXUIElementCreateApplication(sourcePID)
        guard let element = focusedElement(from: app) else { return nil }
        guard !isSecure(element), TextSelectionContext.shouldReadSelectedText(ancestorRoles: ancestorRoles(of: element)) else { return false }
        // 浏览器焦点可能移到容器；原文字节点仍有选区时，不能用容器的空范围结束会话。
        if let selectionElement, selection(from: selectionElement) != nil { return true }
        if isUsable(readOnce(app: app).text) { return true }
        // 只有实际读到过文字的节点才可证明清空；复制回退没有 AX 节点时保持未知。
        guard let selectionElement else { return nil }
        if let text = stringAttribute(selectionElement, kAXSelectedTextAttribute as CFString) {
            return isUsable(text)
        }
        if let value = attribute(selectionElement, kAXSelectedTextRangeAttribute as CFString),
           CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range), range.length == 0 { return false }
        }
        return nil
    }

    /// app 为来源应用；返回可读文字、矩形与持有选区的节点，缺失时均为空。
    private static func readOnce(app: AXUIElement) -> (text: String?, bounds: CGRect?, element: AXUIElement?) {
        var candidates: [AXUIElement] = []
        if let focused = focusedElement(from: app) {
            candidates.append(focused)
        }
        if let systemFocused = systemFocusedElement(),
           !candidates.contains(where: { CFEqual($0, systemFocused) }) {
            candidates.append(systemFocused)
        }

        for element in candidates {
            if isSecure(element) { return (nil, nil, nil) }
            let roles = ancestorRoles(of: element)
            if !TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) {
                continue
            }
            if let hit = selection(from: element) {
                return (hit.text, hit.bounds, element)
            }
        }
        if let hit = searchSelectedText(roots: candidates.filter {
            !isSecure($0) && TextSelectionContext.shouldReadSelectedText(ancestorRoles: ancestorRoles(of: $0))
        }) {
            return hit
        }
        return (nil, nil, nil)
    }

    private static func enableManualAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// app 为 AX 应用元素；返回焦点控件，用于读取文本和注册选区通知。
    static func focusedElement(from app: AXUIElement) -> AXUIElement? {
        axElement(attribute(app, kAXFocusedUIElementAttribute as CFString))
    }

    private static func systemFocusedElement() -> AXUIElement? {
        axElement(attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString))
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

    /// roots 为待遍历的 AX 根节点；返回首个可读选区及其节点，80 个节点内未发现时返回 nil。
    private static func searchSelectedText(roots: [AXUIElement]) -> (text: String, bounds: CGRect?, element: AXUIElement)? {
        var queue = roots
        var seen = 0
        while !queue.isEmpty, seen < 80 {
            let element = queue.removeFirst()
            seen += 1
            if isSecure(element) { continue }
            if let nodeRole = role(of: element), TextSelectionContext.nonTextRoles.contains(nodeRole) {
                continue
            }
            if let hit = selection(from: element) { return (hit.text, hit.bounds, element) }
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

    private static func ancestorRoles(of element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element
        var steps = 0
        while let node = current, steps < 16 {
            if let role = role(of: node) { roles.append(role) }
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
        // AX 原点位于菜单栏屏幕顶部，不随 key 窗口所在屏幕改变。
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        rect.origin.y = maxY - rect.origin.y - rect.height
        return rect
    }

    /// pasteboard 为剪贴板，copy 发起复制，accepts 确认文本仍属于当前选区；返回文字，失败或取消为 nil。
    static func readByCopyingSelection(
        pasteboard: NSPasteboard, copy: () -> Void, accepts: (String) -> Bool
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let changeCount = pasteboard.changeCount
        copy()
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            // 取消后剪贴板可能已属于用户的新操作，旧任务不能再读取或恢复快照。
            guard !Task.isCancelled else { return nil }
            if pasteboard.changeCount != changeCount {
                let copiedChangeCount = pasteboard.changeCount
                guard let text = pasteboard.string(forType: .string), isUsable(text), accepts(text),
                      !Task.isCancelled, pasteboard.changeCount == copiedChangeCount else { return nil }
                snapshot.restore(pasteboard)
                return text
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
        }
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
