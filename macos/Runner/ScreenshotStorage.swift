import Foundation

/// 只负责 PNG 导出；固定目录中的重名文件不能被截图保存覆盖。
enum ScreenshotStorage {
    /// data 为 PNG，directory 为用户目录，name 为文件名；返回实际路径，失败抛出文件系统错误。
    static func save(_ data: Data, directory: URL, name: String) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              (name as NSString).pathExtension.lowercased() == "png" else {
            throw NSError(domain: "TranslateApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "截图文件名必须是 PNG 文件名。"])
        }
        let stem = (name as NSString).deletingPathExtension
        var suffix = 1
        while true {
            let filename = suffix == 1 ? name : "\(stem)-\(suffix).png"
            let url = directory.appendingPathComponent(filename)
            do {
                // 排除先检查后写入的竞态；只有文件已存在时才尝试下一个序号。
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                suffix += 1
            }
        }
    }
}
