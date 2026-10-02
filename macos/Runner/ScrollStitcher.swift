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
    /// 首帧保留顶部固定区域，末帧提供底部固定区域。
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
        var selected: Edges
        if let edges {
            // 固定带采用首顶末底；局部动画不改变正文接缝，可靠性由下面的位移与重叠校验决定。
            selected = edges
        }
        else if requested.automatic {
            // 相邻帧的静止边缘仅作为候选带；可靠位移确定后还须排除随正文移动的空白。
            let limit = image.height / 3
            var top = 0
            var bottom = 0
            while top < limit && rowDifference(old.rows[top], current.rows[top]) < 0.8 { top += 1 }
            while bottom < limit && rowDifference(old.rows[image.height - bottom - 1], current.rows[image.height - bottom - 1]) < 0.8 { bottom += 1 }
            selected = Edges(top: top, bottom: bottom, automatic: true)
        } else { selected = requested }
        var body = image.height - selected.top - selected.bottom
        let overlap = max(32, body / 4)
        guard body > overlap else { throw Failure(message: "正文区域不足以验证重叠，请调整固定边界。") }
        // 先用稀疏样本寻找候选，随后在更密集的正文重叠区校验，拒绝歧义接缝。
        var candidates: [(shift: Int, score: Double)] = []
        for shift in 1...(body - overlap) {
            let score = difference(old, current, oldStart: selected.top + shift,
                                   newStart: selected.top, count: body - shift, samples: 12, rasterization: true)
            if score < 8 { candidates.append((shift, score)) }
        }
        let verified = candidates.sorted { $0.score < $1.score }.prefix(12).map { candidate in
            (shift: candidate.shift, score: difference(old, current, oldStart: selected.top + candidate.shift,
                newStart: selected.top, count: body - candidate.shift, samples: 96, rasterization: true))
        }.sorted { $0.score < $1.score }
        guard let best = verified.first, best.score < 3,
              !verified.dropFirst().contains(where: { abs($0.shift - best.shift) > 1 && $0.score < max(1, best.score * 1.8) }) else {
            throw Failure(message: "相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。")
        }
        if edges == nil && requested.automatic {
            // 固定证据必须同位置稳定且不服从正文位移；连续三个采样点拒绝孤立巧合。
            // 按像素块识别局部悬浮按钮，但合成仍保留完整横带，不推测被按钮遮挡的正文。
            let limit = image.height / 3
            var top = 0
            var bottom = 0
            for row in Array(0..<limit) + Array(image.height - limit..<image.height) {
                let isTop = row < limit
                let shifted = isTop ? row + best.shift : row - best.shift
                guard shifted >= 0, shifted < image.height else { continue }
                var run = 0
                let wholeRowStable = rowDifference(old.rows[row], current.rows[row]) < 0.8
                let minimumRun = wholeRowStable ? 1 : 3
                for column in stride(from: 0, through: old.rows[row].count, by: 3) {
                    let stationary = column < old.rows[row].count &&
                        sampleDifference(old.rows[row], current.rows[row], column: column) < 0.8
                    let moving = column < old.rows[row].count && (isTop
                        ? sampleDifference(old.rows[shifted], current.rows[row], column: column)
                        : sampleDifference(old.rows[row], current.rows[shifted], column: column)) >= 0.8
                    if stationary && moving { run += 1; continue }
                    if run >= minimumRun {
                        if isTop { top = max(top, row + 1) }
                        else { bottom = max(bottom, image.height - row) }
                    }
                    run = 0
                }
            }
            selected = Edges(top: top, bottom: bottom, automatic: true)
            body = image.height - selected.top - selected.bottom
            // 收缩候选带后重新校验全部正文重叠，确保接缝可靠。
            guard body - best.shift >= 32, difference(old, current, oldStart: selected.top + best.shift,
                newStart: selected.top, count: body - best.shift, samples: body, rasterization: true) < 3 else {
                throw Failure(message: "无法可靠区分固定区域与正文，已保留确认部分。")
            }
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

    /// a/b为RGB采样行、column为RGB三元组起始位置；返回该采样点三通道平均绝对误差。
    private func sampleDifference(_ a: [Double], _ b: [Double], column: Int) -> Double {
        (abs(a[column] - b[column]) + abs(a[column + 1] - b[column + 1]) + abs(a[column + 2] - b[column + 2])) / 3
    }

    /// a/b为等宽RGB采样行；返回通道平均绝对差，不分配差分图。
    private func rowDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }

    /// 两帧及对应行范围、样本数；rasterization允许整段一致的亚像素插值，返回最低平均误差。
    private func difference(_ a: Frame, _ b: Frame, oldStart: Int, newStart: Int, count: Int,
                            samples: Int, rasterization: Bool = false) -> Double {
        let step = max(1, count / samples)
        var totals = [Double](repeating: 0, count: rasterization ? 16 : 1)
        var used = 0
        for offset in stride(from: 0, to: count, by: step) {
            let oldRow = a.rows[oldStart + offset]
            let newRow = b.rows[newStart + offset]
            // 原始行差仍承担静止判断；亚像素处理只归一化配准样本，不修改输出图像。
            if rasterization {
                let oldNext = a.rows[min(oldStart + offset + 1, a.rows.count - 1)]
                let newNext = b.rows[min(newStart + offset + 1, b.rows.count - 1)]
                for index in oldRow.indices {
                    let delta = oldRow[index] - newRow[index]
                    for oldQuarter in 0...3 {
                        for newQuarter in 0...3 {
                            // 两帧都可能已经落在亚像素位置；统一比较两侧插值，保留整段相同的相位组合。
                            totals[oldQuarter * 4 + newQuarter] += abs(delta
                                + (oldNext[index] - oldRow[index]) * Double(oldQuarter) / 4
                                - (newNext[index] - newRow[index]) * Double(newQuarter) / 4)
                        }
                    }
                }
            } else { totals[0] += rowDifference(oldRow, newRow) }
            used += 1
        }
        // 同一个插值方向和比例必须解释全部重叠区；不能逐像素挑最小差来掩盖内容变化。
        return totals.min()! / Double(used) / (rasterization ? Double(a.rows[0].count) : 1)
    }
}
