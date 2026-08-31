import Foundation

/// 全局按键监听交给识别器的按键状态。不含鼠标。
public struct KeyPress: Equatable, Sendable {
    public var keyCode: UInt16
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}

/// 只把 Command-A 识别为 Select All Gesture；Escape 结束会话。其他键盘选区不识别。
public enum HotKeyRecognizer {
    public static let commandAKeyCode: UInt16 = 0x00
    public static let escapeKeyCode: UInt16 = 53

    /// - Parameter press: 一次 keyDown。
    /// - Returns: 仅纯 Command-A 返回 `.selectAll`。
    public static func selectionGesture(for press: KeyPress) -> SelectionGesture? {
        guard press.keyCode == commandAKeyCode,
              press.command,
              !press.shift,
              !press.option,
              !press.control
        else {
            return nil
        }
        return .selectAll
    }

    /// - Parameter press: 一次 keyDown。
    /// - Returns: Escape 为 true，不要求修饰键。
    public static func isEscape(_ press: KeyPress) -> Bool {
        press.keyCode == escapeKeyCode
    }
}
