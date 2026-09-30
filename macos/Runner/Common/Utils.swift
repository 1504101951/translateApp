import AppKit
import CoreGraphics
import Darwin
import OSLog

/// 录制启动的本地耗时记录；只记录固定步骤与时长，不包含图像、窗口标题或输出路径。
enum CaptureStartupLog {
    private static let logger = Logger(subsystem: "TranslateApp", category: "CaptureStartup")

    /// stage为固定步骤名，start为该步骤的单调时钟起点；向系统日志写入毫秒耗时，无返回值。
    static func record(_ stage: String, since start: ContinuousClock.Instant) {
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1_000_000_000_000_000
        logger.notice("stage=\(stage, privacy: .public) duration_ms=\(milliseconds, privacy: .public)")
    }
}

/// 窗口列表与显示器坐标换算；截图默认选区用。
enum CaptureGeometry {
    /// cgBounds 为 CGWindow 顶左原点矩形；返回 AppKit 底左原点矩形。
    static func appKitRect(fromCGWindowBounds cgBounds: CGRect) -> NSRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let top = primary?.frame.maxY ?? cgBounds.maxY
        return NSRect(
            x: cgBounds.origin.x,
            y: top - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    /// window 为 AppKit 窗口矩形，displayFrame 为当前屏，pixelWidth/Height 为冻结帧像素。
    /// 返回相对图像左上原点的裁剪矩形；不相交时为 nil。
    static func pixelCrop(
        window: NSRect,
        displayFrame: NSRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> NSRect? {
        let intersection = window.intersection(displayFrame)
        guard intersection.width >= 32, intersection.height >= 32 else { return nil }
        let scaleX = CGFloat(pixelWidth) / max(displayFrame.width, 1)
        let scaleY = CGFloat(pixelHeight) / max(displayFrame.height, 1)
        return NSRect(
            x: (intersection.minX - displayFrame.minX) * scaleX,
            y: (displayFrame.maxY - intersection.maxY) * scaleY,
            width: intersection.width * scaleX,
            height: intersection.height * scaleY
        )
    }

    /// displayFrame 为冻结帧所在屏，pixelWidth/Height 为图像像素。
    /// 返回前台普通窗口映射到图像像素的裁剪框；找不到则 nil。
    static func frontmostWindowPixelCrop(displayFrame: NSRect, pixelWidth: Int, pixelHeight: Int) -> NSRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let myPid = getpid()
        for window in info {
            let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if pid == myPid { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.05 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat else { continue }
            let appKit = appKitRect(fromCGWindowBounds: CGRect(x: x, y: y, width: width, height: height))
            if let crop = pixelCrop(
                window: appKit,
                displayFrame: displayFrame,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ) {
                return crop
            }
        }
        return nil
    }
}
