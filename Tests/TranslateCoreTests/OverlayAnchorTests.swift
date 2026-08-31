import CoreGraphics
import Testing
import TranslateCore

struct OverlayAnchorTests {
    /// 目的：没有可靠选区矩形时，浮层跟鼠标，避免跑到屏幕角落。
    /// 边界：bounds 为 nil。
    @Test func missingBoundsUsesMouse() {
        let mouse = CGPoint(x: 120, y: 340)
        #expect(OverlayAnchor.point(mouse: mouse, bounds: nil) == mouse)
    }

    /// 目的：选区矩形就在鼠标附近时，锚在选区下沿。
    /// 边界：矩形包含鼠标。
    @Test func nearbyBoundsUsesSelectionBottom() {
        let mouse = CGPoint(x: 50, y: 60)
        let bounds = CGRect(x: 40, y: 50, width: 80, height: 20)
        let point = OverlayAnchor.point(mouse: mouse, bounds: bounds)
        #expect(point.x == bounds.midX)
        #expect(point.y == bounds.minY)
    }

    /// 目的：QQ 一类应用给出远离选区的假矩形时，不能夹到屏幕右下角。
    /// 边界：矩形在 (1800, 20)，鼠标在 (200, 400)，距离超过 400。
    @Test func distantBoundsFallBackToMouse() {
        let mouse = CGPoint(x: 200, y: 400)
        let bounds = CGRect(x: 1800, y: 8, width: 40, height: 16)
        #expect(OverlayAnchor.point(mouse: mouse, bounds: bounds) == mouse)
    }

    /// 目的：零尺寸或非有限矩形不可信。
    /// 边界：宽为 0；原点含 inf。
    @Test func invalidBoundsFallBackToMouse() {
        let mouse = CGPoint(x: 10, y: 10)
        #expect(OverlayAnchor.point(mouse: mouse, bounds: .zero) == mouse)
        let inf = CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)
        #expect(OverlayAnchor.point(mouse: mouse, bounds: inf) == mouse)
    }
}
