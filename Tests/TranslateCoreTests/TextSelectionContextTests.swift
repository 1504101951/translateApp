import Testing
import TranslateCore

struct TextSelectionContextTests {
    /// 目的：项目树/文件大纲里的文件名不是翻译选区。
    /// 边界：焦点或其祖先为 AXOutline，对应 PyCharm 项目树。
    @Test func outlineAncestorsRejectSelectedTextAndCopy() {
        let roles = ["AXOutline", "AXScrollArea", "AXWindow"]
        #expect(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) == false)
        #expect(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles) == false)
    }

    /// 目的：表格单元格选中也不翻译。
    /// 边界：焦点是 AXCell，祖先是 AXTable。
    @Test func tableCellRejectsSelectedTextAndCopy() {
        let roles = ["AXCell", "AXRow", "AXTable", "AXWindow"]
        #expect(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) == false)
        #expect(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles) == false)
    }

    /// 目的：聊天列表（Codex / QQ）里的文本选区仍可翻译。AXList 不是文件树。
    /// 边界：祖先含 AXList，不含 AXOutline。
    @Test func listAncestorsAllowSelectedTextAndCopy() {
        let roles = ["AXGroup", "AXList", "AXWindow"]
        #expect(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) == true)
        #expect(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles) == true)
    }

    /// 目的：编辑器文本域仍可翻译。
    /// 边界：AXTextArea 在滚动区域和窗口内。
    @Test func textAreaAllowsSelectedTextAndCopy() {
        let roles = ["AXTextArea", "AXScrollArea", "AXGroup", "AXWindow"]
        #expect(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) == true)
        #expect(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles) == true)
    }

    /// 目的：网页区域仍可翻译。
    /// 边界：AXWebArea。
    @Test func webAreaAllowsSelectedTextAndCopy() {
        let roles = ["AXWebArea", "AXGroup", "AXWindow"]
        #expect(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) == true)
        #expect(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles) == true)
    }

    /// 目的：Electron / Codex 往往只有 Group，没有 AXTextArea，仍允许 AX 和 Command-C。
    /// 边界：没有文本角色也没有非文本角色。
    @Test func unknownEditorAllowsAXAndCopy() {
        let roles = ["AXGroup", "AXWindow"]
        #expect(TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) == true)
        #expect(TextSelectionContext.shouldCopyFallback(ancestorRoles: roles) == true)
    }
}
