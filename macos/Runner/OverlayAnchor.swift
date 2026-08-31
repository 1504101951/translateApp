import CoreGraphics
import Foundation

enum OverlayAnchor {
    static let maxBoundsDistance: CGFloat = 400

    static func point(mouse: CGPoint, bounds: CGRect?) -> CGPoint {
        guard let bounds, isTrusted(bounds, near: mouse) else { return mouse }
        return CGPoint(x: bounds.midX, y: bounds.minY)
    }

    private static func isTrusted(_ bounds: CGRect, near mouse: CGPoint) -> Bool {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              !bounds.isNull, !bounds.isInfinite, bounds.width >= 1, bounds.height >= 1
        else { return false }
        if bounds.contains(mouse) { return true }
        return hypot(bounds.midX - mouse.x, bounds.midY - mouse.y) <= maxBoundsDistance
    }
}
