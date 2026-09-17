import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// 系统截图模块的权限与冻结帧；本进程捕获才会把 TranslateApp 写入屏幕录制 TCC。
enum ScreenCaptureService {
    struct FreezeFrame {
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
        /// AppKit 屏幕坐标下的显示器矩形，编辑窗与冻结帧对齐。
        let displayFrame: NSRect
    }

    /// 无参数；返回本进程当前是否已获屏幕录制授权。
    static func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 无参数；已授权则直接复用，不再弹系统框。
    /// 不写 TCC.db；ad-hoc 重签后系统会当成新身份，那时仍需再授权一次。
    @MainActor
    static func requestAccess() async -> Bool {
        if isAuthorized() { return true }
        // 菜单栏 App 默认不出现在 Dock；申请期间改成普通激活，系统提示才进前台。
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 只在尚未授权时申请；已授权不得再次 CGRequest。
        _ = CGRequestScreenCaptureAccess()
        // 只打开设置页不会把本进程写入列表；ScreenCaptureKit 枚举才会登记 TranslateApp。
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0..<20 {
            if isAuthorized() {
                restoreActivationPolicy(previousPolicy)
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        restoreActivationPolicy(previousPolicy)
        return isAuthorized()
    }

    /// previous 为申请前的激活策略；申请结束后恢复菜单栏形态。
    @MainActor
    private static func restoreActivationPolicy(_ previous: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != previous {
            _ = NSApp.setActivationPolicy(previous)
        }
    }

    /// 无参数；打开系统「屏幕录制」设置页，不修改 TCC 数据库。
    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 无参数；捕获指针所在屏的冻结帧。失败抛出可展示错误，不改剪贴板或文件。
    static func captureActiveDisplay() async throws -> FreezeFrame {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            throw NSError(
                domain: "TranslateApp",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "找不到可用显示器。"]
            )
        }
        let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays.first { screenNumber != nil && $0.displayID == screenNumber }
            ?? content.displays.first
        guard let display else {
            throw NSError(
                domain: "TranslateApp",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "无法读取显示器内容，请检查屏幕录制权限。"]
            )
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        // contentRect 是点，必须乘 pointPixelScale 才是物理像素；用 1x 缓冲再拉伸会整屏发糊。
        let scale = CGFloat(filter.pointPixelScale)
        let pixelWidth = max(display.width, Int((filter.contentRect.width * scale).rounded()))
        let pixelHeight = max(display.height, Int((filter.contentRect.height * scale).rounded()))
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.2, *) {
            configuration.scalesToFit = false
        }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let png = try pngData(from: image, scale: scale)
        return FreezeFrame(
            png: png,
            pixelWidth: image.width,
            pixelHeight: image.height,
            displayFrame: screen.frame
        )
    }

    /// png 为截图像素；按阅读顺序返回识别文本，无字返回空字符串。
    static func recognizeText(png: Data) throws -> String {
        try recognizeBlocks(png: png).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// png 为截图像素；返回带像素框的 OCR 块，坐标原点在左上。
    static func recognizeBlocks(png: Data) throws -> [[String: Any]] {
        guard let image = NSBitmapImageRep(data: png)?.cgImage else {
            throw NSError(
                domain: "TranslateApp",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "无法读取截图以识别文字。"]
            )
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = Double(image.width)
        let height = Double(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
                return nil
            }
            let box = observation.boundingBox
            return [
                "text": text,
                "x": box.minX * width,
                "y": (1 - box.maxY) * height,
                "width": box.width * width,
                "height": box.height * height,
            ]
        }
    }

    /// image 为冻结帧，scale 为点到物理像素比；按像素编码 PNG，并写入 DPI 以免贴图按 72DPI 放大发糊。
    private static func pngData(from image: CGImage, scale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(
                domain: "TranslateApp",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "无法编码冻结帧。"]
            )
        }
        let dpi = 72.0 * Double(max(scale, 1))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "TranslateApp",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "无法编码冻结帧。"]
            )
        }
        return data as Data
    }
}
