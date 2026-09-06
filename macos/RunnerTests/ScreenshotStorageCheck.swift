import Foundation

/// 不启动 App 的文件系统回归检查；只在系统临时目录中操作合成数据。
@main
struct ScreenshotStorageCheck {
    /// 无参数；验证重名追加序号、保留旧文件和非法路径拒绝，断言失败即非零退出。
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ScreenshotStorage.save(Data([1, 2, 3]), directory: directory, name: "截图.png")
        let second = try ScreenshotStorage.save(Data([4, 5, 6]), directory: directory, name: "截图.png")
        let third = try ScreenshotStorage.save(Data([7]), directory: directory, name: "截图.png")
        // 同一毫秒内或重复保存同一截图是重名边界，已有文件的字节必须完全保留。
        assert(second.lastPathComponent == "截图-2.png" && third.lastPathComponent == "截图-3.png")
        let original = try Data(contentsOf: first)
        assert(original == Data([1, 2, 3]))
        let exported = try Data(contentsOf: second)
        assert(exported == Data([4, 5, 6]))
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
