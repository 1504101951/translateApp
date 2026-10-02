import Foundation

/// 不启动 App 的文件系统回归检查；只在系统临时目录中操作合成数据。
@main
struct ScreenshotStorageCheck {
    /// 无参数；验证分类日期路径、重名保护和真实文件系统错误，断言失败即非零退出。
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 同一本地日期的三种输出必须进入不同分类；日期不受用户的日历区域设置影响。
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        for (ext, category) in [("png", "截图"), ("mp4", "视频"), ("gif", "gif")] {
            let folder = try ScreenshotStorage.datedDirectory(basePath: directory.path, extension: ext, date: date)
            assert(folder.path == directory.appendingPathComponent("\(category)/2026-10-01").path)
            let target = folder.appendingPathComponent("采集.\(ext)")
            let source = directory.appendingPathComponent("source.\(ext)")
            try Data([1, 2, 3]).write(to: source)
            try Data([9]).write(to: target)
            // 同名媒体只新增序号文件；临时源与已保存内容均保持不变。
            let output = try ScreenshotStorage.publish(source: source, target: target)
            assert(output.lastPathComponent == "采集-2.\(ext)")
            let saved = try Data(contentsOf: output)
            let existing = try Data(contentsOf: target)
            let original = try Data(contentsOf: source)
            assert(saved == original && existing == Data([9]))
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            assert(!names.contains { $0.hasSuffix(".partial") })
        }
        // 根路径被真实文件占用时必须失败，不能报告保存成功或污染该文件。
        let blockedRoot = directory.appendingPathComponent("blocked")
        try Data([7]).write(to: blockedRoot)
        do {
            _ = try ScreenshotStorage.datedDirectory(basePath: blockedRoot.path, extension: "png", date: date)
            fatalError("must reject a root that is a file")
        } catch { }
        let first = try ScreenshotStorage.save(Data([1, 2, 3]), directory: directory, name: "截图.png")
        let second = try ScreenshotStorage.save(Data([4, 5, 6]), directory: directory, name: "截图.png")
        let third = try ScreenshotStorage.save(Data([7]), directory: directory, name: "截图.png")
        // 同一毫秒内或重复保存同一截图是重名边界，已有文件的字节必须完全保留。
        assert(second.lastPathComponent == "截图-2.png" && third.lastPathComponent == "截图-3.png")
        let original = try Data(contentsOf: first)
        assert(original == Data([1, 2, 3]))
        let exported = try Data(contentsOf: second)
        assert(exported == Data([4, 5, 6]))
        // 取消是真实任务状态；发布不得创建目标，也不能删除仍可预览的来源或遗留暂存文件。
        let cancelledTarget = directory.appendingPathComponent("cancelled.gif")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScreenshotStorage.publish(source: first, target: cancelledTarget)
        }
        do { _ = try await cancelled.value; fatalError("must not publish a cancelled export") }
        catch is CancellationError { }
        assert(!FileManager.default.fileExists(atPath: cancelledTarget.path))
        let retained = try Data(contentsOf: first)
        assert(retained == original)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        assert(!remaining.contains { $0.hasSuffix(".partial") })
        do {
            _ = try ScreenshotStorage.save(Data([8]), directory: directory, name: "../outside.png")
            fatalError("must reject paths outside the selected directory")
        } catch { }
        do {
            _ = try ScreenshotStorage.save(Data([8]), directory: directory.appendingPathComponent("removed"), name: "截图.png")
            fatalError("must report a removed save directory")
        } catch { }
        print("ScreenshotStorage checks passed")
    }
}
