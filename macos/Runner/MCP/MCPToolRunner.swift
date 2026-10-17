import AppKit
import ScreenCaptureKit

/// 在 App 进程执行 MCP 工具（#96「工具」）：列出显示器与窗口，按显示器、矩形或窗口截图并生成结果。
/// 不进入截图编辑或采集会话，不写翻译历史，不保存文件；截图类工具执行期间菜单栏显示采集状态。
@MainActor
enum MCPToolRunner {
    /// 作用：执行一次工具请求。
    /// 参数 request：helper 转来的、已通过参数类型校验的请求。
    /// 返回：清单或截图结果；序号越界、矩形越界、窗口不存在、权限不足与截图失败返回 failed。
    static func run(_ request: MCPToolRequest) async -> MCPToolReply {
        do {
            switch request {
            case .listDisplays:
                return .displays(displays())
            case .listWindows:
                guard await ScreenCaptureService.requestAccess() else {
                    return .failed(message: AppConstants.mcpPermissionMessage)
                }
                return .windows(try await windows())
            case .captureScreen(let display, let output):
                guard let id = displayID(display) else { return displayOutOfRange(display) }
                return try await capture {
                    try await MCPImageOutput.reply(ScreenCaptureService.captureDisplayImage(displayID: id).image, output: output)
                }
            case .captureRect(let display, let x, let y, let width, let height, let output):
                guard let id = displayID(display) else { return displayOutOfRange(display) }
                return try await capture {
                    let image = try await ScreenCaptureService.captureDisplayImage(displayID: id).image
                    // sourceRect 把 capture_screen 输出图坐标按同一缩放比换算回原始像素。
                    guard let rect = MCPImageOutput.sourceRect(
                        x: x, y: y, width: width, height: height,
                        sourceWidth: image.width, sourceHeight: image.height
                    ), let cropped = image.cropping(to: rect) else {
                        let size = MCPImageOutput.fitted(width: image.width, height: image.height)
                        return .failed(message: "矩形超出显示器 \(display) 的 capture_screen 输出图范围（宽 \(size.width)、高 \(size.height) 像素）")
                    }
                    return try await MCPImageOutput.reply(cropped, output: output)
                }
            case .captureWindow(let windowID, let output):
                return try await capture {
                    guard let window = try await ScreenCaptureService.visibleWindows().first(where: { $0.windowID == windowID }) else {
                        return .failed(message: "window_id \(windowID) 不存在或窗口已关闭，请重新调用 list_windows")
                    }
                    return try await MCPImageOutput.reply(ScreenCaptureService.captureWindowImage(window), output: output)
                }
            }
        } catch {
            return .failed(message: "截图失败：\(error.localizedDescription)")
        }
    }

    /// 作用：截图类工具的公共流程：确认屏幕录制授权，执行期间切换菜单栏采集状态。
    /// 参数 body：实际截图与结果生成。返回：body 的结果；未授权时返回权限错误。
    private static func capture(_ body: () async throws -> MCPToolReply) async throws -> MCPToolReply {
        // requestAccess 已授权时直接返回；未授权时请求系统授权并等待结果。
        guard await ScreenCaptureService.requestAccess() else {
            return .failed(message: AppConstants.mcpPermissionMessage)
        }
        // beginMCPCapture 切换菜单栏图标，返回的回调在最短保持时间后恢复。
        let finish = StatusBarController.shared.beginMCPCapture()
        defer { finish() }
        return try await body()
    }

    /// 作用：列出显示器。返回：按 NSScreen.screens 顺序的显示器信息，0 为主显示器。
    private static func displays() -> [MCPDisplayInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = screenNumber(screen) else { return nil }
            let bounds = CGDisplayBounds(id)
            // 与 captureDisplayImage 一致：物理像素为点尺寸乘点到像素比例。
            let scale = screen.backingScaleFactor
            let size = MCPImageOutput.fitted(
                width: Int((bounds.width * scale).rounded()),
                height: Int((bounds.height * scale).rounded())
            )
            return MCPDisplayInfo(
                display: index, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height,
                scale: scale, imageWidth: size.width, imageHeight: size.height
            )
        }
    }

    /// 作用：列出屏上可见窗口。返回：与任一显示器相交的窗口，display 为相交面积最大的显示器序号。
    private static func windows() async throws -> [MCPWindowInfo] {
        let screens = NSScreen.screens.compactMap(screenNumber).map(CGDisplayBounds)
        return try await ScreenCaptureService.visibleWindows().compactMap { window in
            let areas = screens.map { bounds -> CGFloat in
                let overlap = bounds.intersection(window.frame)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
            return MCPWindowInfo(
                windowID: window.windowID,
                app: window.owningApplication?.applicationName ?? "",
                title: window.title ?? "",
                display: best,
                x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: window.frame.height
            )
        }
    }

    /// 作用：把显示器序号转换为 CGDirectDisplayID。参数 index：0 起序号。返回：越界时为 nil。
    private static func displayID(_ index: Int) -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        return screens.indices.contains(index) ? screenNumber(screens[index]) : nil
    }

    /// 作用：读取 NSScreen 的显示器编号。参数 screen：显示器。返回：CGDirectDisplayID。
    private static func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 作用：生成显示器序号越界的参数错误。参数 index：请求的序号。返回：failed 结果。
    private static func displayOutOfRange(_ index: Int) -> MCPToolReply {
        .failed(message: "display \(index) 超出范围：当前有 \(NSScreen.screens.count) 块显示器，序号从 0 开始")
    }
}
