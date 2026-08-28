import CoreGraphics
import Testing
import TranslateCore

struct SelectionGestureDetectorTests {
    /// 目的：单击不构成 Selection Gesture，避免普通点击弹出浮层。
    /// 边界：down + up 且 clickCount 为 1，位移为 0。
    @Test func singleClickDoesNotBeginSelectionGesture() {
        var detector = SelectionGestureDetector()
        #expect(detector.handle(down(clickCount: 1, x: 0, y: 0)) == nil)
        #expect(detector.handle(up(clickCount: 1, x: 0, y: 0)) == nil)
    }

    /// 目的：拖拽选区在鼠标抬起时产生 drag 手势。
    /// 边界：位移刚好达到 4pt 阈值。
    @Test func dragPastThresholdBeginsDragGesture() {
        var detector = SelectionGestureDetector()
        #expect(detector.handle(down(clickCount: 1, x: 0, y: 0)) == nil)
        #expect(detector.handle(dragged(x: 4, y: 0)) == nil)
        #expect(detector.handle(up(clickCount: 1, x: 4, y: 0)) == .drag)
    }

    /// 目的：低于阈值的抖动仍视为点击，不创建选区会话。
    /// 边界：位移 3pt，小于 4pt 阈值。
    @Test func tinyMovementIsNotADrag() {
        var detector = SelectionGestureDetector()
        _ = detector.handle(down(clickCount: 1, x: 0, y: 0))
        _ = detector.handle(dragged(x: 3, y: 0))
        #expect(detector.handle(up(clickCount: 1, x: 3, y: 0)) == nil)
    }

    /// 目的：双击选词是 Selection Gesture。
    /// 边界：第一次抬起 clickCount=1 必须忽略，第二次 clickCount=2 才成立。
    @Test func doubleClickBeginsGestureOnSecondUp() {
        var detector = SelectionGestureDetector()
        _ = detector.handle(down(clickCount: 1, x: 1, y: 1))
        #expect(detector.handle(up(clickCount: 1, x: 1, y: 1)) == nil)
        _ = detector.handle(down(clickCount: 2, x: 1, y: 1))
        #expect(detector.handle(up(clickCount: 2, x: 1, y: 1)) == .doubleClick)
    }

    /// 目的：三击选段是 Selection Gesture。
    /// 边界：clickCount >= 3 都映射为 tripleClick。
    @Test func tripleClickBeginsGesture() {
        var detector = SelectionGestureDetector()
        _ = detector.handle(down(clickCount: 3, x: 2, y: 2))
        #expect(detector.handle(up(clickCount: 3, x: 2, y: 2)) == .tripleClick)
    }

    /// 目的：检测器不接收键盘事件，因此键盘选区无法从该入口开始会话。
    /// 边界：只暴露指针事件 API；没有 keyDown 处理。
    @Test func detectorHasNoKeyboardEventPath() {
        var detector = SelectionGestureDetector()
        #expect(detector.handle(up(clickCount: 1, x: 0, y: 0)) == nil)
    }
}

private func down(clickCount: Int, x: CGFloat, y: CGFloat) -> MousePointerEvent {
    MousePointerEvent(kind: .down, clickCount: clickCount, x: x, y: y)
}

private func dragged(x: CGFloat, y: CGFloat) -> MousePointerEvent {
    MousePointerEvent(kind: .dragged, clickCount: 1, x: x, y: y)
}

private func up(clickCount: Int, x: CGFloat, y: CGFloat) -> MousePointerEvent {
    MousePointerEvent(kind: .up, clickCount: clickCount, x: x, y: y)
}
