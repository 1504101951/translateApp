import CoreGraphics
import Foundation
import ImageIO

/// 把 App 内的截图像素转换为 MCP 结果（#96 决策 3、「坐标约定」）：
/// 图片等比缩到长边不超过 1568 px；capture_rect 的输出图坐标按同一确定比例换算回原始像素。
/// OCR 在原始像素上识别以保证小字准确，坐标换算到返回图片的像素空间。
enum MCPImageOutput {
    /// 作用：计算原图到返回图的缩放比例与返回图尺寸。
    /// 参数 width、height：原图像素尺寸。
    /// 返回：scale 为 0～1（不放大），width、height 为四舍五入且不小于 1 的返回图像素尺寸。
    static func fitted(width: Int, height: Int) -> (scale: Double, width: Int, height: Int) {
        let scale = min(1, Double(AppConstants.mcpImageMaxEdge) / Double(max(width, height)))
        return (
            scale,
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// 作用：把 capture_screen 输出图上的矩形换算为原图像素矩形。
    /// 参数 x、y、width、height：输出图像素矩形（宽高为正）；sourceWidth、sourceHeight：原图像素尺寸。
    /// 返回：原图上的整数像素矩形，向外取整并限制在原图内；矩形未完全落在输出图内时返回 nil。
    static func sourceRect(x: Int, y: Int, width: Int, height: Int, sourceWidth: Int, sourceHeight: Int) -> CGRect? {
        let output = fitted(width: sourceWidth, height: sourceHeight)
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= output.width, y + height <= output.height else { return nil }
        // 向外取整保证输出图上看到的像素都在裁剪结果内。
        let left = max(0, Int((Double(x) / output.scale).rounded(.down)))
        let top = max(0, Int((Double(y) / output.scale).rounded(.down)))
        let right = min(sourceWidth, Int((Double(x + width) / output.scale).rounded(.up)))
        let bottom = min(sourceHeight, Int((Double(y + height) / output.scale).rounded(.up)))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 作用：生成截图结果。
    /// 参数 source：原始像素图；output：返回图片、文字或两者。
    /// 返回：image 结果；png 为缩放后的 PNG（output 为 text 时为 nil），text 坐标为返回图片像素（output 为 image 时为 nil）。
    static func reply(_ source: CGImage, output: MCPOutput) async throws -> MCPToolReply {
        let size = fitted(width: source.width, height: source.height)
        let png = output == .text ? nil : try ScreenCaptureService.pngData(from: try resize(source, to: size), scale: 1)
        guard output != .image else { return .image(png: png, text: nil) }
        // OCR 跑在原图上，段落坐标按同一比例换算到返回图片。
        let blocks = try await ScreenCaptureService.recognizeParagraphs(image: source)
        let paragraphs = blocks.map { block in
            let value = { (key: String) in Int(((block[key] as! Double) * size.scale).rounded()) }
            return MCPParagraph(
                text: block["text"] as! String,
                x: value("x"), y: value("y"), width: value("width"), height: value("height")
            )
        }
        return .image(png: png, text: MCPRecognizedText(width: size.width, height: size.height, paragraphs: paragraphs))
    }

    /// 作用：解码 PNG。参数 png：PNG 数据。返回：首帧 CGImage；数据不可解码时抛错。
    static func image(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "TranslateApp", code: 14, userInfo: [NSLocalizedDescriptionKey: "无法读取截图像素。"])
        }
        return image
    }

    /// 作用：把图片缩放到指定尺寸。参数 image：原图；size：fitted 的结果，scale 为 1 时原样返回。
    /// 返回：sRGB 位图。
    private static func resize(_ image: CGImage, to size: (scale: Double, width: Int, height: Int)) throws -> CGImage {
        guard size.scale < 1 else { return image }
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "TranslateApp", code: 15, userInfo: [NSLocalizedDescriptionKey: "无法缩放截图。"])
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let resized = context.makeImage() else {
            throw NSError(domain: "TranslateApp", code: 15, userInfo: [NSLocalizedDescriptionKey: "无法缩放截图。"])
        }
        return resized
    }
}
