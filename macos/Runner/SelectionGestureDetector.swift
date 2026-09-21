import AppKit
import Foundation


/// 单次指针事件；阶段、点击次数和坐标供手势识别器判定，不直接读取选中文字。
struct MousePointerEvent {
    /// 指针阶段：down初始化拖拽原点，dragged更新状态，up产生最终手势。
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

    /// event为指针事件；更新拖拽状态，仅在抬起时返回拖拽、双击或三击手势，其他情况返回nil。
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
