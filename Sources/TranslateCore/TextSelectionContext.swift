import Foundation

/// 判断当前焦点是否在可翻译的文本控件里，而不是文件树、表格等非文本选区。
public enum TextSelectionContext {
    public static let textRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXSearchField",
        "AXComboBox",
        "AXWebArea",
        "AXTextView",
    ]

    public static let nonTextRoles: Set<String> = [
        "AXOutline",
        "AXTable",
        "AXBrowser",
        "AXRow",
        "AXCell",
        "AXColumn",
        "AXImage",
        "AXButton",
        "AXMenu",
        "AXMenuBar",
        "AXMenuItem",
        "AXToolbar",
        "AXTabGroup",
    ]

    /// 是否允许把辅助功能读到的字符串当作选区文本。
    /// - Parameter ancestorRoles: 从焦点控件到窗口的角色链，焦点在前。
    /// - Returns: 链上先遇到非文本角色则为 false；先遇到文本角色或没有强信号则为 true。
    public static func shouldReadSelectedText(ancestorRoles: [String]) -> Bool {
        for role in ancestorRoles {
            if nonTextRoles.contains(role) {
                return false
            }
            if textRoles.contains(role) {
                return true
            }
        }
        return true
    }

    /// Command-C 在非文件树上下文可用。Codex / Electron 常没有 AXTextArea，只能靠复制。
    /// - Parameter ancestorRoles: 从焦点控件到窗口的角色链，焦点在前。
    /// - Returns: 链上没有非文本角色。
    public static func shouldCopyFallback(ancestorRoles: [String]) -> Bool {
        !ancestorRoles.contains { nonTextRoles.contains($0) }
    }
}
