import AppKit
import Foundation

enum SelectionGesture: String {
    case drag
    case doubleClick
    case tripleClick
    case selectAll
    case keyboard
    case hotkey

    /// keyCode 为硬件键码，modifiers 为修饰键；返回创建文本选区的手势或 nil。
    static func keyboardGesture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> SelectionGesture? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if keyCode == 0, flags == .command { return .selectAll }
        // Shift 配合方向/Home/End/Page 键覆盖按字、按词、按行及全文扩选。
        let navigationKeys: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        if flags.contains(.shift), navigationKeys.contains(keyCode) { return .keyboard }
        return nil
    }
}

struct MousePointerEvent {
    enum Kind { case down, dragged, up }
    var kind: Kind
    var clickCount: Int
    var x: CGFloat
    var y: CGFloat
}

/// 识别鼠标拖拽/双击/三击；键盘手势由 SelectionGesture 判定。
struct SelectionGestureDetector {
    static let dragThreshold: CGFloat = 4
    private var originX: CGFloat?
    private var originY: CGFloat?
    private var isDrag = false

    mutating func handle(_ event: MousePointerEvent) -> SelectionGesture? {
        switch event.kind {
        case .down:
            originX = event.x
            originY = event.y
            isDrag = false
            return nil
        case .dragged:
            if let originX, let originY {
                if hypot(event.x - originX, event.y - originY) >= Self.dragThreshold {
                    isDrag = true
                }
            }
            return nil
        case .up:
            let dragged = isDrag
            originX = nil
            originY = nil
            isDrag = false
            if dragged { return .drag }
            if event.clickCount == 2 { return .doubleClick }
            if event.clickCount >= 3 { return .tripleClick }
            return nil
        }
    }
}
