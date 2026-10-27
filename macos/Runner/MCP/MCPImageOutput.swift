import CoreGraphics
import Foundation
import ImageIO

/// 把 App 内的截图像素转换为 MCP 结果（#96 决策 3、「坐标约定」「工具」返回）：
/// 图片按清晰度的视觉 token 上限（⌈宽/28⌉×⌈高/28⌉）与 1568 px 长边等比缩放，客户端不再二次缩放；
/// capture_rect 与窗口坐标按同一确定尺寸换算；OCR 在原始像素上识别后输出 Markdown。
enum MCPImageOutput {
    /// 作用：计算返回图尺寸。
    /// 参数 width、height：原图像素尺寸；detail：清晰度。
    /// 返回：不放大、长边不超过 1568 且切块数不超过该清晰度 token 上限的像素尺寸，宽高均不小于 1。
    static func fitted(width: Int, height: Int, detail: MCPDetail) -> (width: Int, height: Int) {
        let patch = Double(AppConstants.mcpTokenPatch)
        let budget = detail.tokenBudget
        let size = { (scale: Double) in
            (width: max(1, Int((Double(width) * scale).rounded())), height: max(1, Int((Double(height) * scale).rounded())))
        }
        let patches = { (size: (width: Int, height: Int)) in
            Int((Double(size.width) / patch).rounded(.up)) * Int((Double(size.height) / patch).rounded(.up))
        }
        // 面积估算给出起点；切块向上取整可能仍超预算，逐步缩小到满足为止。
        var scale = min(
            1,
            Double(AppConstants.mcpImageMaxEdge) / Double(max(width, height)),
            (Double(budget) * patch * patch / (Double(width) * Double(height))).squareRoot()
        )
        while patches(size(scale)) > budget { scale *= 0.999 }
        return size(scale)
    }

    /// 作用：把某清晰度下 capture_screen 输出图上的矩形换算为原图像素矩形。
    /// 参数 x、y、width、height：输出图像素矩形；detail：输出图的清晰度；sourceWidth、sourceHeight：原图像素尺寸。
    /// 返回：原图上的整数像素矩形，向外取整并限制在原图内；矩形未完全落在输出图内或宽高不为正时返回 nil。
    static func sourceRect(
        x: Int, y: Int, width: Int, height: Int, detail: MCPDetail, sourceWidth: Int, sourceHeight: Int
    ) -> CGRect? {
        let output = fitted(width: sourceWidth, height: sourceHeight, detail: detail)
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= output.width, y + height <= output.height else { return nil }
        let scaleX = Double(sourceWidth) / Double(output.width)
        let scaleY = Double(sourceHeight) / Double(output.height)
        // 向外取整保证输出图上看到的像素都在裁剪结果内。
        let left = max(0, Int((Double(x) * scaleX).rounded(.down)))
        let top = max(0, Int((Double(y) * scaleY).rounded(.down)))
        let right = min(sourceWidth, Int((Double(x + width) * scaleX).rounded(.up)))
        let bottom = min(sourceHeight, Int((Double(y + height) * scaleY).rounded(.up)))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 作用：生成截图结果。
    /// 参数 source：原始像素图；options：output、detail 与 includePositions。
    /// 返回：image 结果；png 为缩放后的 PNG（output 为 text 时为 nil），markdown 为 OCR 文本（output 为 image 时为 nil）。
    static func reply(_ source: CGImage, options: MCPCaptureOptions) async throws -> MCPToolReply {
        let size = fitted(width: source.width, height: source.height, detail: options.detail)
        let png = options.output == .text
            ? nil
            : try PNGEncoding.data(try resize(source, to: size), scale: 1)
        guard options.output != .image else { return .image(png: png, markdown: nil) }
        // recognizeDocument 在原图上识别，块位置按返回图尺寸换算。
        let blocks = try await ScreenCaptureService.recognizeDocument(image: source)
        let markdown = text(
            blocks,
            scaleX: Double(size.width) / Double(source.width),
            scaleY: Double(size.height) / Double(source.height),
            size: size,
            includePositions: options.includePositions
        )
        return .image(png: png, markdown: markdown)
    }

    /// 作用：把 OCR 块组织为返回文本。
    /// 参数 blocks：原图坐标的 Markdown 块；scaleX、scaleY：原图到返回图的比例；size：返回图尺寸；
    /// includePositions：为 true 时首行为 `[image W×H]`，每块前加一行返回图像素坐标 `[x,y,w,h]`。
    /// 返回：块之间空一行的 Markdown；没有块时为「No text recognized.」。
    static func text(
        _ blocks: [ScreenCaptureService.OCRBlock], scaleX: Double, scaleY: Double,
        size: (width: Int, height: Int), includePositions: Bool
    ) -> String {
        guard !blocks.isEmpty else { return AppConstants.mcpNoTextMessage }
        guard includePositions else { return blocks.map(\.markdown).joined(separator: "\n\n") }
        let positioned = blocks.map { block in
            let x = Int((block.rect.minX * scaleX).rounded())
            let y = Int((block.rect.minY * scaleY).rounded())
            let width = Int((block.rect.width * scaleX).rounded())
            let height = Int((block.rect.height * scaleY).rounded())
            return "[\(x),\(y),\(width),\(height)]\n\(block.markdown)"
        }
        return (["[image \(size.width)×\(size.height)]"] + positioned).joined(separator: "\n\n")
    }

    /// 作用：解码 PNG。参数 png：PNG 数据。返回：首帧 CGImage；数据不可解码时抛错。
    static func image(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: AppConstants.errorDomain, code: 14, userInfo: [NSLocalizedDescriptionKey: AppConstants.mcpPixelReadFailedMessage])
        }
        return image
    }

    /// 作用：把图片缩放到指定尺寸。参数 image：原图；size：fitted 的结果，与原图相同时原样返回。
    /// 返回：sRGB 位图。
    private static func resize(_ image: CGImage, to size: (width: Int, height: Int)) throws -> CGImage {
        guard size.width != image.width || size.height != image.height else { return image }
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: AppConstants.errorDomain, code: 15, userInfo: [NSLocalizedDescriptionKey: AppConstants.mcpScaleFailedMessage])
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let resized = context.makeImage() else {
            throw NSError(domain: AppConstants.errorDomain, code: 15, userInfo: [NSLocalizedDescriptionKey: AppConstants.mcpScaleFailedMessage])
        }
        return resized
    }
}
