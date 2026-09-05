import Foundation

/// 文件树/表格不是文本选区；聊天列表可以。
enum TextSelectionContext {
    static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXWebArea", "AXTextView",
    ]
    static let nonTextRoles: Set<String> = [
        "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXColumn",
        "AXImage", "AXButton", "AXMenu", "AXMenuBar", "AXMenuItem", "AXToolbar", "AXTabGroup",
    ]

    static func shouldReadSelectedText(ancestorRoles: [String]) -> Bool {
        for role in ancestorRoles {
            if nonTextRoles.contains(role) { return false }
            if textRoles.contains(role) { return true }
        }
        return true
    }

    /// ancestorRoles 按控件到祖先排列，hasAXText 表示已读到 AX 文字；返回是否需一次性复制读取。
    static func shouldCopySelection(ancestorRoles: [String], hasAXText: Bool) -> Bool {
        guard !ancestorRoles.contains(where: { nonTextRoles.contains($0) }) else { return false }
        // 浏览器 AX 文本可能已丢段落；其他文本控件仅在 AX 无文字时才回退到复制。
        return !hasAXText || ancestorRoles.contains("AXWebArea")
    }
}
