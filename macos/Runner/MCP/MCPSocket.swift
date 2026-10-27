import Darwin
import Foundation

/// MCP 本地传输失败原因；notRunning 表示没有 App 在 socket 上监听。
enum MCPSocketError: Error, Equatable {
    case notRunning
    case alreadyServing
    case pathTooLong
    case system(Int32)
}

/// helper 与 App 之间的 Unix domain socket 传输（#68「MCP 接口边界」）。
/// 一条连接承载一次请求：helper 写一行 JSON 请求，App 写一行 JSON 结果，均以 \n 结尾。
/// 只负责字节收发与 socket 文件权限，不理解请求语义。
enum MCPSocket {
    /// 作用：返回当前用户的默认 socket 文件 URL。
    /// 返回：~/Library/Application Support/TranslateApp/mcp.sock。
    static var defaultURL: URL {
        AppConstants.applicationSupportURL
            .appendingPathComponent(AppConstants.mcpSocketFileName)
    }

    /// 作用：作为 helper 连接 App 的监听 socket。
    /// 参数 path：socket 文件路径。
    /// 返回：已连接的文件描述符，调用方负责 close；无人监听时抛 notRunning。
    static func connect(path: String) throws -> Int32 {
        let fd = try makeSocket()
        var address = try address(path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let code = errno
            close(fd)
            // socket 文件不存在或残留文件无人监听，都表示 App 没有运行。
            if code == ENOENT || code == ECONNREFUSED { throw MCPSocketError.notRunning }
            throw MCPSocketError.system(code)
        }
        return fd
    }

    /// 作用：作为 App 在 path 上监听，socket 文件权限为 0600。
    /// 参数 path：socket 文件路径，父目录必须已存在。
    /// 返回：监听中的文件描述符；已有另一个 App 实例在该路径服务时抛 alreadyServing。
    static func listen(path: String) throws -> Int32 {
        // 能连上说明另一个实例仍在服务；只清理无人监听的残留文件，避免抢走对方的 socket。
        if let existing = try? connect(path: path) {
            close(existing)
            throw MCPSocketError.alreadyServing
        }
        unlink(path)
        let fd = try makeSocket()
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // 先收紧权限再 listen，任何连接都只能发生在 0600 之后。
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            throw MCPSocketError.system(code)
        }
        return fd
    }

    /// 作用：把 data 加换行后完整写入 fd。
    /// 参数 data：不含换行的单行 JSON；fd：已连接的 socket。
    static func writeLine(_ data: Data, to fd: Int32) throws {
        var bytes = data
        bytes.append(0x0A)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MCPSocketError.system(errno)
                }
                offset += written
            }
        }
    }

    /// 作用：从 fd 读取一行，直到换行符。
    /// 参数 fd：已连接的 socket。
    /// 返回：不含换行的行内容；对端在换行前关闭或被 shutdown 时返回 nil。
    static func readLine(from fd: Int32) throws -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw MCPSocketError.system(errno)
            }
            if count == 0 { return nil }
            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[0..<newline])
                return line
            }
            line.append(contentsOf: chunk[0..<count])
        }
    }

    /// 作用：创建关闭 SIGPIPE 的流式 Unix socket，避免对端断开时写入终止进程。
    /// 返回：新文件描述符。
    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// 作用：把文件路径转换为 sockaddr_un。
    /// 参数 path：socket 文件路径；超过 sun_path 容量（104 字节）时抛 pathTooLong。
    /// 返回：填好族与路径的地址结构。
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw MCPSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
