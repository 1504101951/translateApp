import Darwin
import Foundation
import OSLog

/// App 侧 MCP 请求入口（#68「MCP 接口边界」）：在 0600 Unix socket 上接受 helper 连接，
/// 校验开关后交给工具执行方，并把结果写回同一连接。
/// helper 断开表示 agent 放弃，执行中的 Task 被取消，结果不再写回。
/// 不持有截图状态；截图与权限由注入的执行方完成。
@MainActor
final class MCPCaptureServer {
    /// 执行一次工具请求并生成结果。
    typealias Run = @MainActor (MCPToolRequest) async -> MCPToolReply

    private static let log = Logger(subsystem: "TranslateApp", category: "MCP")
    private let isEnabled: () -> Bool
    private let run: Run
    private var listener: DispatchSourceRead?

    /// 参数 isEnabled：读取设置中「允许 agent 截图」开关；run：按工具执行并生成结果。
    init(isEnabled: @escaping () -> Bool, run: @escaping Run) {
        self.isEnabled = isEnabled
        self.run = run
    }

    /// 作用：在 path 上开始监听；失败只记录日志，App 其他功能照常可用，helper 会得到「未运行」。
    /// 参数 path：socket 文件路径，父目录不存在时创建。
    func start(path: String) {
        do {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = try MCPSocket.listen(path: path)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            // 可读即有待接受的连接；每个连接在后台读请求，结果回到主线程执行。
            source.setEventHandler { [self] in
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .userInitiated).async { Self.serve(connection, server: self) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            listener = source
        } catch {
            Self.log.error("MCP socket 监听失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 作用：停止接受新连接并关闭监听 socket；进行中的请求不受影响。
    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// 作用：按开关受理一次请求。
    /// 参数 request：helper 转来的工具请求。
    /// 返回：开关关闭为「MCP 未开启」，否则为执行结果。
    func handle(_ request: MCPToolRequest) async -> MCPToolReply {
        guard isEnabled() else { return .failed(message: AppConstants.mcpDisabledMessage) }
        return await run(request)
    }

    /// 作用：处理一条连接，在后台线程调用：读请求、执行、写结果后关闭。
    /// 参数 connection：已接受的连接；server：受理请求的服务。
    nonisolated private static func serve(_ connection: Int32, server: MCPCaptureServer) {
        guard let line = try? MCPSocket.readLine(from: connection) else {
            close(connection)
            return
        }
        guard let request = try? JSONDecoder().decode(MCPToolRequest.self, from: line) else {
            // helper 与 App 版本不一致时请求结构可能不同，明确报错而不是静默断开。
            let reply = MCPToolReply.failed(message: "TranslateApp 无法识别该请求，请确认 helper 与 App 来自同一版本")
            try? MCPSocket.writeLine(JSONEncoder().encode(reply), to: connection)
            close(connection)
            return
        }

        let task = Task { await server.handle(request) }
        // 等待期间监视对端：读到 EOF 表示 helper 已取消或退出，取消执行任务。
        let monitor = DispatchSource.makeReadSource(fileDescriptor: connection, queue: .global(qos: .userInitiated))
        let monitorCancelled = DispatchSemaphore(value: 0)
        monitor.setEventHandler {
            var byte: UInt8 = 0
            guard recv(connection, &byte, 1, MSG_PEEK) <= 0 else { return }
            task.cancel()
            monitor.cancel()
        }
        monitor.setCancelHandler { monitorCancelled.signal() }
        monitor.resume()

        Task.detached {
            let reply = await task.value
            // 阻塞等待放到 GCD 线程，不占用 Swift 并发线程池。
            DispatchQueue.global(qos: .userInitiated).async {
                monitor.cancel()
                // 监视源的取消处理执行后才能关闭 fd，避免源仍在观察一个已被复用的描述符。
                monitorCancelled.wait()
                try? MCPSocket.writeLine(JSONEncoder().encode(reply), to: connection)
                close(connection)
            }
        }
    }
}
