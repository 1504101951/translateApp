import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 截图历史的拼接、拆分与比较（#109）；全部按原始像素处理，不缩放、不重采样。
enum ScreenshotComposer {
    /// 处理失败；message 为展示给用户的原因。
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 差异高亮色 #FF3B30，60% 不透明度；按内存顺序排列的预乘 RGBA 字节读成一个像素值。
    private static let highlight = [UInt8]([153, 35, 29, 153]).withUnsafeBytes { $0.load(as: UInt32.self) }

    /// paths 为按截图时间先后排列的 PNG 路径（至少 2 张），vertical 为 true 时纵向拼接。
    /// 返回拼接后的 PNG：不缩放、无间距，短边方向居中，空白透明。
    static func stitch(paths: [String], vertical: Bool) throws -> Data {
        guard paths.count >= 2 else { throw Failure(message: "拼接至少需要 2 张截图。") }
        let images = try paths.map(load)
        let width = vertical ? images.map(\.width).max()! : images.map(\.width).reduce(0, +)
        let height = vertical ? images.map(\.height).reduce(0, +) : images.map(\.height).max()!
        let context = try canvas(width: width, height: height, like: images[0])
        var offset = 0
        for image in images {
            // CG 原点在左下：纵向从顶部往下排，横向从左往右排，另一方向居中。
            let x = vertical ? (width - image.width) / 2 : offset
            let y = vertical ? height - offset - image.height : (height - image.height) / 2
            context.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
            offset += vertical ? image.height : image.width
        }
        return try png(context.makeImage())
    }

    /// path 为 PNG 路径，parts 为段数（2–10 且不超过像素高度）；返回自上而下的各段 PNG，余数并入最后一段。
    static func split(path: String, parts: Int) throws -> [Data] {
        let image = try load(path)
        guard (2...10).contains(parts), parts <= image.height else {
            throw Failure(message: "段数需在 2–10 之间且不超过图片高度。")
        }
        let piece = image.height / parts
        return try (0..<parts).map { index in
            // cropping 的坐标原点在左上；最后一段取到底部。
            let top = index * piece
            let height = index == parts - 1 ? image.height - top : piece
            return try png(image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height)))
        }
    }

    /// first/second 为两张 PNG 路径；两图左上角对齐到宽高各取较大者的画布后逐像素比较 RGBA。
    /// 返回差异蒙版 PNG（不同处为 60% 红色，其余透明）、不同像素数与画布总像素数；超出任一图范围的像素计为不同。
    static func compare(first: String, second: String) throws -> (mask: Data, different: Int, total: Int) {
        let a = try load(first), b = try load(second)
        let width = max(a.width, b.width), height = max(a.height, b.height)
        let left = try pixels(a, width: width, height: height)
        let right = try pixels(b, width: width, height: height)
        let inside = { (image: CGImage, x: Int, y: Int) in x < image.width && y < image.height }
        let context = try canvas(width: width, height: height, like: nil)
        // 以 data: nil 创建的位图上下文由系统分配像素内存，data 总是存在。
        let mask = context.data!.bindMemory(to: UInt32.self, capacity: width * height)
        var different = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if inside(a, x, y) && inside(b, x, y) && left[index] == right[index] { continue }
                different += 1
                mask[index] = highlight
            }
        }
        return (try png(context.makeImage()), different, width * height)
    }

    /// path 为 PNG 路径；返回解码后的位图，文件缺失或不可读时抛出。
    private static func load(_ path: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure(message: "图片文件不可读。") }
        return image
    }

    /// width/height 为像素尺寸，like 为沿用色彩空间的源图（nil 用 sRGB）；返回透明背景、关闭插值的 RGBA 画布。
    /// 沿用源图色彩空间，绘制时不做颜色转换。
    private static func canvas(width: Int, height: Int, like image: CGImage?) throws -> CGContext {
        let space = image?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure(message: "图片过大，无法处理。") }
        context.interpolationQuality = .none
        return context
    }

    /// image 为源图，width/height 为比较画布；返回左上角对齐绘制后的逐像素 RGBA（每像素一个值，行序自上而下）。
    private static func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt32] {
        let context = try canvas(width: width, height: height, like: image)
        // CG 原点在左下，把图片放在画布顶部即左上角对齐；位图内存首行对应画面顶部。
        context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        return [UInt32](UnsafeBufferPointer(
            start: context.data!.bindMemory(to: UInt32.self, capacity: width * height),
            count: width * height
        ))
    }

    /// image 为待编码位图（nil 表示上一步失败）；返回 PNG 字节。
    private static func png(_ image: CGImage?) throws -> Data {
        let data = NSMutableData()
        guard let image,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(message: "无法编码图片。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "无法编码图片。") }
        return data as Data
    }
}
