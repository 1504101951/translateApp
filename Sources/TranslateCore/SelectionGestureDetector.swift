import CoreGraphics
import Foundation

/// 把鼠标按下、拖动、抬起识别为 Selection Gesture。
///
/// 只处理指针事件，因此纯键盘创建的选区永远不会从这里产生手势。
public struct SelectionGestureDetector: Sendable {
    /// 小于该距离的位移仍视为点击，避免微抖被当成拖拽选区。
    public static let dragThreshold: CGFloat = 4

    private var originX: CGFloat?
    private var originY: CGFloat?
    private var isDrag = false

    public init() {}

    /// 消化一个指针事件。
    /// - Parameter event: 左键 down/dragged/up。`clickCount` 只在 up 时参与判定。
    /// - Returns: 手势完成时返回对应 Selection Gesture；否则为 nil。
    public mutating func handle(_ event: MousePointerEvent) -> SelectionGesture? {
        switch event.kind {
        case .down:
            originX = event.x
            originY = event.y
            isDrag = false
            return nil
        case .dragged:
            if let originX, let originY {
                let distance = hypot(event.x - originX, event.y - originY)
                if distance >= Self.dragThreshold {
                    isDrag = true
                }
            }
            return nil
        case .up:
            let dragged = isDrag
            originX = nil
            originY = nil
            isDrag = false
            if dragged {
                return .drag
            }
            if event.clickCount == 2 {
                return .doubleClick
            }
            if event.clickCount >= 3 {
                return .tripleClick
            }
            return nil
        }
    }
}
