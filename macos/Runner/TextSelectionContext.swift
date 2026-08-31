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

    static func shouldCopyFallback(ancestorRoles: [String]) -> Bool {
        !ancestorRoles.contains { nonTextRoles.contains($0) }
    }
}
