import CoreGraphics
import Foundation

/// 决定 Translation Overlay 的锚点。AX 选区矩形在部分应用里是垃圾坐标，不能直接用。
public enum OverlayAnchor {
    /// 选区中心离鼠标超过该距离时，视为不可信，改用鼠标位置。
    public static let maxBoundsDistance: CGFloat = 400

    /// - Parameters:
    ///   - mouse: Selection Gesture 结束时的指针位置（Cocoa 底左原点）。
    ///   - bounds: 辅助功能给出的选区矩形；可能为空或完全错位。
    /// - Returns: 靠近选区的锚点。QQ 等应用若给出屏幕右下角的假矩形，会退回鼠标位置。
    public static func point(mouse: CGPoint, bounds: CGRect?) -> CGPoint {
        guard let bounds, isTrusted(bounds, near: mouse) else {
            return mouse
        }
        return CGPoint(x: bounds.midX, y: bounds.minY)
    }

    private static func isTrusted(_ bounds: CGRect, near mouse: CGPoint) -> Bool {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite
        else {
            return false
        }
        guard !bounds.isNull, !bounds.isInfinite, bounds.width >= 1, bounds.height >= 1 else {
            return false
        }
        if bounds.contains(mouse) {
            return true
        }
        let dx = bounds.midX - mouse.x
        let dy = bounds.midY - mouse.y
        return hypot(dx, dy) <= maxBoundsDistance
    }
}
