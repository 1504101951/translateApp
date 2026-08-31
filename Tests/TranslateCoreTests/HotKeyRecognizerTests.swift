import Testing
import TranslateCore

struct HotKeyRecognizerTests {
    /// 目的：纯 Command-A 是 Select All Gesture。
    /// 边界：只有 command，没有 shift/option/control。
    @Test func commandAIsSelectAllGesture() {
        let press = KeyPress(keyCode: 0x00, command: true, shift: false, option: false, control: false)
        #expect(HotKeyRecognizer.selectionGesture(for: press) == .selectAll)
    }

    /// 目的：带 Shift 的 Command-A 不是全选手势，避免和系统其他快捷键混淆。
    /// 边界：command+shift+A。
    @Test func commandShiftAIsNotSelectAll() {
        let press = KeyPress(keyCode: 0x00, command: true, shift: true, option: false, control: false)
        #expect(HotKeyRecognizer.selectionGesture(for: press) == nil)
    }

    /// 目的：Shift+方向键等其他键盘选区不开始会话。
    /// 边界：左方向键带 shift，无 command。
    @Test func shiftArrowIsNotASelectionGesture() {
        let press = KeyPress(keyCode: 0x7B, command: false, shift: true, option: false, control: false)
        #expect(HotKeyRecognizer.selectionGesture(for: press) == nil)
        #expect(HotKeyRecognizer.isEscape(press) == false)
    }

    /// 目的：没有 Command 的 A 不是全选。
    /// 边界：keyCode 仍是 A。
    @Test func plainAIsNotSelectAll() {
        let press = KeyPress(keyCode: 0x00, command: false, shift: false, option: false, control: false)
        #expect(HotKeyRecognizer.selectionGesture(for: press) == nil)
    }

    /// 目的：Escape 结束会话，不依赖 Overlay 成为 Key Window。
    /// 边界：无修饰键。
    @Test func escapeIsRecognized() {
        let press = KeyPress(keyCode: 53, command: false, shift: false, option: false, control: false)
        #expect(HotKeyRecognizer.isEscape(press) == true)
        #expect(HotKeyRecognizer.selectionGesture(for: press) == nil)
    }
}
