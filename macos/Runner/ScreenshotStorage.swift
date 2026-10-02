import Foundation

/// 截图目录内的采集文件存储；统一分类日期目录与防覆盖发布，不持有采集状态。
enum ScreenshotStorage {
    /// path为保存的根目录偏好；空值返回系统Pictures下的截图目录，不创建文件。
    static func rootDirectory(_ path: String?) -> URL {
        guard let path, !path.isEmpty else {
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("截图", isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// basePath为根目录偏好，extension为png/mp4/gif，date为发起保存的本地日期；创建并返回分类日期目录。
    static func datedDirectory(basePath: String?, extension fileExtension: String, date: Date = Date()) throws -> URL {
        let category: String
        switch fileExtension {
        case "png": category = "截图"
        case "mp4": category = "视频"
        case "gif": category = "gif"
        default: throw NSError(domain: "TranslateApp", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "不支持此采集文件类型。"])
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // 日期只在操作发起时冻结，跨午夜的后台导出仍写入同一次操作的目录。
        let directory = rootDirectory(basePath).appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// source为已校验的临时媒体，target为默认完整路径；原子发布，重名追加序号，返回实际保存路径。
    static func publish(source: URL, target: URL) throws -> URL {
        let directory = target.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".TranslateApp-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: staging)
        let stem = target.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            // 大文件暂存期间仍可取消；原子移动之前检查，取消不得把临时内容发布为已保存文件。
            try Task.checkCancellation()
            let destination = suffix == 1 ? target : directory
                .appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(target.pathExtension)
            do {
                // 同目录移动负责发布；不先检查存在状态，也不覆盖其他进程刚写入的文件。
                try FileManager.default.moveItem(at: staging, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                suffix += 1
            }
        }
    }

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
