import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 垂直滚动图像拼接器；只消费本地位图，不读取屏幕或控制其他应用。
final class ScrollStitcher {
    /// 自动检测或用户指定的固定边缘，单位均为原图像素。
    struct Edges {
        let top: Int
        let bottom: Int
        let automatic: Bool
    }

    /// 可展示的拼接失败；不把推测的接缝作为成功结果。
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 图像、逐行采样与有效纹理；采样只用于配准，输出始终使用原始像素。
    private struct Frame {
        let image: CGImage
        let rows: [[Double]]

        /// image 为同尺寸截图；返回统一RGB采样，失败抛出可读错误。
        init(_ image: CGImage) throws {
            self.image = image
            let width = image.width
            let height = image.height
            guard width >= 32, height >= 64,
                  width <= 32768, height <= 32768,
                  width * height <= 33_554_432 else {
                throw Failure(message: "选区尺寸不支持，请缩小区域；最长边32768像素、总像素33554432。")
            }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { throw Failure(message: "无法读取截图像素。") }
            // 左右窄边不用于配准，避免滚动条拖偏；合成仍保留完整图宽。
            let inset = max(1, width / 20)
            let columns = stride(from: inset, to: width - inset, by: max(1, (width - inset * 2) / 32))
            rows = (0..<height).map { y in
                columns.flatMap { x -> [Double] in
                    let offset = (y * width + x) * 4
                    return [Double(rgba[offset]), Double(rgba[offset + 1]), Double(rgba[offset + 2])]
                }
            }
        }
    }

    private let requested: Edges
    private var edges: Edges?
    private var first: Frame?
    private var previous: Frame?
    private var strips: [CGImage] = []
    private var bodyHeight = 0
    private(set) var acceptedFrames = 0
    private(set) var height = 0

    /// edges 为手动像素边界或自动检测意图；创建空会话，不分配图像缓冲。
    init(edges: Edges) { requested = edges }

    /// frame 为新的同倍率截图；返回是否追加正文，静止帧返回false，失配抛错并保留已确认结果。
    @discardableResult
    func append(_ image: CGImage) throws -> Bool {
        // Frame只为本次候选创建采样；校验完成之前不修改已接受的像素。
        let current = try Frame(image)
        guard let old = previous else {
            guard requested.top >= 0, requested.bottom >= 0,
                  requested.top + requested.bottom <= image.height - 64 else {
                throw Failure(message: "顶部和底部固定区之间至少保留64像素正文。")
            }
            first = current
            previous = current
            acceptedFrames = 1
            height = image.height
            return false
        }
        guard old.image.width == image.width, old.image.height == image.height else {
            throw Failure(message: "捕获尺寸或显示倍率发生变化，请重新框选。")
        }
        // 差值是各RGB通道的平均误差；完全静止不触发底部判断。
        if difference(old, current, oldStart: 0, newStart: 0, count: image.height, samples: 64) < 0.8 {
            return false
        }
        let selected: Edges
        if let edges {
            // 已确认的自动固定带变化表示导航折叠或页面布局切换，不能继续套用旧边界。
            let topChanged = edges.top > 0 && difference(old, current, oldStart: 0, newStart: 0, count: edges.top, samples: 32) >= 0.8
            let bottomStart = image.height - edges.bottom
            let bottomChanged = edges.bottom > 0 && difference(old, current, oldStart: bottomStart, newStart: bottomStart, count: edges.bottom, samples: 32) >= 0.8
            guard !edges.automatic || (!topChanged && !bottomChanged) else {
                throw Failure(message: "已识别的固定区域发生变化，请重新框选。已保留确认部分。")
            }
            selected = edges
        }
        else if requested.automatic {
            // 固定边缘只从画面边界连续检测，并限制在视口的三分之一。
            let limit = image.height / 3
            var top = 0
            var bottom = 0
            while top < limit && rowDifference(old.rows[top], current.rows[top]) < 0.8 { top += 1 }
            while bottom < limit && rowDifference(old.rows[image.height - bottom - 1], current.rows[image.height - bottom - 1]) < 0.8 { bottom += 1 }
            selected = Edges(top: top, bottom: bottom, automatic: true)
        } else { selected = requested }
        let body = image.height - selected.top - selected.bottom
        let overlap = max(32, body / 4)
        guard body > overlap else { throw Failure(message: "正文区域不足以验证重叠，请调整固定边界。") }
        // 先用稀疏样本寻找候选，随后在更密集的正文重叠区校验，拒绝歧义接缝。
        var candidates: [(shift: Int, score: Double)] = []
        for shift in 1...(body - overlap) {
            let score = difference(old, current, oldStart: selected.top + shift,
                                   newStart: selected.top, count: body - shift, samples: 12)
            if score < 8 { candidates.append((shift, score)) }
        }
        let verified = candidates.sorted { $0.score < $1.score }.prefix(12).map { candidate in
            (shift: candidate.shift, score: difference(old, current, oldStart: selected.top + candidate.shift,
                newStart: selected.top, count: body - candidate.shift, samples: 96))
        }.sorted { $0.score < $1.score }
        guard let best = verified.first, best.score < 3,
              !verified.dropFirst().contains(where: { abs($0.shift - best.shift) > 1 && $0.score < max(1, best.score * 1.8) }) else {
            throw Failure(message: "无法可靠拼接：请慢速向下滚动，避开动态内容，并检查上下固定边界。已保留确认部分。")
        }
        // 纹理不足的空白/重复色块不能凭低误差证明滚动；保留等待下一张可识别画面。
        let texture = old.rows[selected.top..<(image.height - selected.bottom)].map { row in
            (row.max() ?? 0) - (row.min() ?? 0)
        }.reduce(0, +) / Double(body)
        guard texture >= 3 else { throw Failure(message: "正文缺少可识别细节，无法确认接缝。请调整选区。") }
        let nextHeight = height + best.shift
        guard nextHeight <= 32768, image.width * nextHeight <= 33_554_432 else {
            throw Failure(message: "长图达到资源上限：最长边32768像素、总像素33554432。已保留确认部分。")
        }
        // 首次可靠位移之后才提交自动边界；顶部只使用首帧，正文条带不携带固定区。
        if edges == nil, let first {
            strips.append(try copyStrip(first.image, y: selected.top, height: body))
            bodyHeight = body
            edges = selected
        }
        strips.append(try copyStrip(image, y: image.height - selected.bottom - best.shift, height: best.shift))
        bodyHeight += best.shift
        previous = current
        acceptedFrames += 1
        height = nextHeight
        return true
    }

    /// 无参数；返回已确认图像的PNG及尺寸，首帧顶区和末帧底区各一次；没有帧时抛错。
    func finish() throws -> (png: Data, width: Int, height: Int, frames: Int) {
        guard let first, let last = previous else { throw Failure(message: "还没有捕获到图像。") }
        let image: CGImage
        if let edges {
            let width = first.image.width
            let outputHeight = edges.top + bodyHeight + edges.bottom
            guard let context = CGContext(data: nil, width: width, height: outputHeight,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(message: "无法分配长图内存，请缩短捕获范围。")
            }
            var pieces: [CGImage] = []
            if edges.top > 0 { pieces.append(try copyStrip(first.image, y: 0, height: edges.top)) }
            pieces.append(contentsOf: strips)
            if edges.bottom > 0 { pieces.append(try copyStrip(last.image, y: last.image.height - edges.bottom, height: edges.bottom)) }
            var y = 0
            context.interpolationQuality = .none
            for piece in pieces {
                context.draw(piece, in: CGRect(x: 0, y: outputHeight - y - piece.height, width: width, height: piece.height))
                y += piece.height
            }
            guard let result = context.makeImage() else { throw Failure(message: "无法合成长图。") }
            image = result
        } else { image = first.image }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "无法创建长图PNG。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "长图PNG编码失败。") }
        return (data as Data, image.width, image.height, acceptedFrames)
    }

    /// image/y/height描述顶部原点的完整宽度条带；复制像素以免裁剪对象长期持有整帧内存。
    private func copyStrip(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        guard let crop = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)),
              let context = CGContext(data: nil, width: image.width, height: height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "无法保存长图条带。")
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        guard let result = context.makeImage() else { throw Failure(message: "无法保存长图条带。") }
        return result
    }

    /// a/b为等宽RGB采样行；返回通道平均绝对差，不分配差分图。
    private func rowDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }

    /// 两帧及对应起始行、重叠行数、样本数；返回整段平均差，供位移与静止验证。
    private func difference(_ a: Frame, _ b: Frame, oldStart: Int, newStart: Int, count: Int, samples: Int) -> Double {
        let step = max(1, count / samples)
        var total = 0.0
        var used = 0
        for offset in stride(from: 0, to: count, by: step) {
            // 单行差使用相同列采样，不能把纯色行错当文字特征。
            total += rowDifference(a.rows[oldStart + offset], b.rows[newStart + offset])
            used += 1
        }
        return total / Double(used)
    }
}
