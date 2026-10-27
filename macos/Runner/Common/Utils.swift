import AppKit
import CoreGraphics
import Darwin
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

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

/// 实时翻译的排查日志。只写数量与耗时，不写屏幕文字或译文。
enum LiveRegionLog {
    private static let logger = Logger(subsystem: "TranslateApp", category: "LiveRegion")

    /// message 为“键=值”形式的一行数值字段；写入系统日志，无返回值。
    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

extension NSScreen {
    /// 无参数；返回该屏幕对应的 CoreGraphics 显示器编号，系统未提供编号时为 nil。
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// 偏好字典的只读入口；写入由 MacPlatformBridge 负责。
enum AppPreferences {
    /// 无参数；返回 Flutter 侧保存的偏好字典，尚未保存时为空字典。
    static var current: [String: Any] {
        UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) ?? [:]
    }
}

/// PNG 编码的统一入口；录制冻结帧、长截图、拼接与 MCP 图片共用。
enum PNGEncoding {
    /// 编码失败时抛出的用户可读错误。
    static let failure = GIFExporter.ExportError(message: "无法编码图片。")

    /// image 为待编码位图；scale 非空时为点到物理像素比，按 72×max(scale,1) 写入 DPI 以免贴图按 72DPI 放大发糊，
    /// 为空时不写 DPI。返回 PNG 字节，编码失败时抛出 `failure`。
    static func data(_ image: CGImage, scale: CGFloat? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw failure
        }
        // 只有调用方给出倍率时才写 DPI。
        let properties = scale.map { scale -> CFDictionary in
            let dpi = 72.0 * Double(max(scale, 1))
            return [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw failure }
        return data as Data
    }
}

/// 显示器采集共用的来源解析与校验（#125）：录制、长截图与实时翻译使用同一套规则与错误文案。
enum DisplayCapture {
    /// 无参数；屏幕录制未授权时抛出用户可读错误，无返回值。
    static func requireAuthorization() throws {
        guard ScreenCaptureService.isAuthorized() else { throw GIFExporter.ExportError(message: AppConstants.screenRecordingRequiredMessage) }
    }

    /// displayID 为目标显示器（区域取选区所在屏，可为空），content 为当前可共享内容；返回该显示器，不可用时抛错。
    static func display(_ displayID: CGDirectDisplayID?, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw GIFExporter.ExportError(message: "捕获目标已不可用，请重新选择。")
        }
        return display
    }

    /// content 为当前可共享内容；返回本应用，供显示器采集排除控制、译文与编辑窗口，找不到时抛错。
    static func ownApplications(in content: SCShareableContent) throws -> [SCRunningApplication] {
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !own.isEmpty else { throw GIFExporter.ExportError(message: "无法排除采集控制窗口，请重新开始。") }
        return own
    }

    /// region 为已确认的像素选区，filter 为所在显示器的过滤器；倍率未变时返回点坐标裁剪框，
    /// 倍率改变或越出显示器时抛错。
    static func crop(_ region: MediaCaptureService.Region, in filter: SCContentFilter) throws -> CGRect {
        guard abs(CGFloat(filter.pointPixelScale) - region.scale) < 0.01 else {
            throw GIFExporter.ExportError(message: "显示器缩放已改变，请重新框选。")
        }
        let crop = CGRect(x: region.rect.minX / region.scale, y: region.rect.minY / region.scale,
                          width: region.rect.width / region.scale, height: region.rect.height / region.scale)
        guard CGRect(origin: .zero, size: filter.contentRect.size).contains(crop) else {
            throw GIFExporter.ExportError(message: "选区超出当前显示器，请重新框选。")
        }
        return crop
    }

    /// width/height 为输出像素；小于 32×64 时抛错，无返回值。
    static func requireMinimumSize(width: Int, height: Int) throws {
        guard width >= 32, height >= 64 else { throw GIFExporter.ExportError(message: "选区至少需要32×64像素。") }
    }
}

/// 窗口列表与显示器坐标换算；截图默认选区用。
enum CaptureGeometry {
    /// 无参数；返回坐标原点在 (0,0) 的主显示器，找不到时退回 NSScreen.main，坐标换算以其高度为基准。
    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    /// cgBounds 为 CGWindow 顶左原点矩形；返回 AppKit 底左原点矩形。
    static func appKitRect(fromCGWindowBounds cgBounds: CGRect) -> NSRect {
        let top = primaryScreen?.frame.maxY ?? cgBounds.maxY
        return NSRect(
            x: cgBounds.origin.x,
            y: top - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    /// point 为 AppKit 底左原点的屏幕点；返回 CG 顶左原点的全局点，辅助功能命中测试使用（#112）。
    static func cgPoint(fromAppKitPoint point: NSPoint) -> CGPoint {
        return CGPoint(x: point.x, y: (primaryScreen?.frame.maxY ?? point.y) - point.y)
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
