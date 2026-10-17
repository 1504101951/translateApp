import Darwin
import Foundation

/// helper 转给 App 的截图请求，由 tools/call 参数校验后生成。
/// display 只用于 capture_screen（NSScreen.screens 序号，nil 为主显示器）；prompt 只用于交互工具。
struct MCPCaptureRequest: Codable, Equatable {
    let tool: MCPTool
    let output: MCPOutput
    let display: Int?
    let prompt: String?
}

/// OCR 段落；坐标为返回图片的像素坐标，原点左上。chunk 仅长截图携带，为所在切块序号。
struct MCPParagraph: Codable, Equatable {
    let text: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let chunk: Int?
}

/// OCR 文本结果；width、height 为返回图片（长截图为切块前整图）的像素尺寸。
struct MCPRecognizedText: Codable, Equatable {
    let width: Int
    let height: Int
    let paragraphs: [MCPParagraph]
}

/// App 回给 helper 的截图结果。
/// completed：images 为按顺序返回的 PNG，text 为 OCR 结果，warning 为附带说明（如长截图提前停止原因）。
/// cancelled：用户取消交互截图。failed：message 为返回给 agent 的错误文案。
enum MCPCaptureReply: Codable, Equatable {
    case completed(images: [Data], text: MCPRecognizedText?, warning: String?)
    case cancelled
    case failed(message: String)
}

/// tools/call 参数无法转换为截图请求的原因。
/// unknownTool 按 JSON-RPC 参数错误返回；invalidArgument 作为工具错误结果返回，便于 agent 自行修正。
enum MCPRequestError: Error, Equatable {
    case unknownTool(String)
    case invalidArgument(String)
}

/// MCP JSON-RPC 最小子集（initialize、tools/list、tools/call、ping）的纯转换函数，不做 IO。
/// 需要 resources、prompts 或 HTTP 传输时按 #96 决策 2 重新评估。
enum MCPProtocol {
    /// 支持的协议版本，按新到旧排列；客户端请求其中之一时原样回应，否则回应第一项。
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602

    /// 作用：生成 initialize 结果。
    /// 参数 params：客户端 initialize 参数，读取 protocolVersion；version：serverInfo.version。
    /// 返回：含 protocolVersion、capabilities.tools 与 serverInfo 的结果对象。
    static func initializeResult(params: [String: Any], version: String) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let negotiated = requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? supportedVersions[0]
        return [
            "protocolVersion": negotiated,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": AppConstants.mcpServerName, "version": version],
        ]
    }

    /// 作用：生成 tools/list 结果。
    /// 返回：{tools: [{name, description, inputSchema}]}，顺序与 MCPTool.allCases 一致。
    static func toolsListResult() -> [String: Any] {
        let output: [String: Any] = [
            "type": "string",
            "enum": MCPOutput.allCases.map(\.rawValue),
            "default": MCPOutput.both.rawValue,
            "description": "image 只返回 PNG；text 只返回 OCR 段落 JSON（文字及其在图中的像素位置，原点左上）；both 两者都返回。",
        ]
        let prompt: [String: Any] = ["type": "string", "description": "展示给用户的提示语，说明需要截取什么。"]
        let tools: [[String: Any]] = MCPTool.allCases.map { tool in
            switch tool {
            case .captureScreen:
                return schema(tool, "截取整块显示器，不需要用户操作。图片长边不超过 1568 像素。", [
                    "display": ["type": "integer", "minimum": 0, "description": "显示器序号，0 为主显示器；缺省为主显示器。"],
                    "output": output,
                ])
            case .captureRegion:
                return schema(tool, "请用户在 TranslateApp 中框选屏幕区域（可标注），Return 确认、Esc 取消；返回框选结果或取消结果。图片长边不超过 1568 像素。", [
                    "prompt": prompt,
                    "output": output,
                ])
            case .captureScrolling:
                return schema(tool, "请用户框选区域后手动滚动内容，点击结束确认，生成滚动长截图；放弃即返回取消结果。长图按 1568 像素高度切块依次返回。", [
                    "prompt": prompt,
                    "output": output,
                ])
            }
        }
        return ["tools": tools]
    }

    /// 作用：把 tools/call 参数转换为截图请求。
    /// 参数 params：{name, arguments?}；arguments 缺省视为空对象，未知字段忽略。
    /// 返回：校验后的请求；工具不存在抛 unknownTool，参数类型或取值不合法抛 invalidArgument。
    static func captureRequest(params: [String: Any]) throws(MCPRequestError) -> MCPCaptureRequest {
        let name = params["name"] as? String ?? ""
        guard let tool = MCPTool(rawValue: name) else { throw MCPRequestError.unknownTool(name) }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        var output = MCPOutput.both
        if let raw = arguments["output"] {
            guard let value = (raw as? String).flatMap(MCPOutput.init(rawValue:)) else {
                throw MCPRequestError.invalidArgument("output 只能是 image、text 或 both")
            }
            output = value
        }

        var display: Int?
        if tool == .captureScreen, let raw = arguments["display"] {
            // JSON 布尔值同样桥接为 NSNumber，需要排除；只接受非负整数。
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == number.doubleValue.rounded(), number.intValue >= 0 else {
                throw MCPRequestError.invalidArgument("display 必须是从 0 开始的显示器序号")
            }
            display = number.intValue
        }

        var prompt: String?
        if tool != .captureScreen, let raw = arguments["prompt"] {
            guard let value = raw as? String else { throw MCPRequestError.invalidArgument("prompt 必须是字符串") }
            prompt = value.isEmpty ? nil : value
        }
        return MCPCaptureRequest(tool: tool, output: output, display: display, prompt: prompt)
    }

    /// 作用：把 App 结果转换为 MCP CallToolResult。
    /// 参数 reply：App 返回的截图结果。
    /// 返回：{content: [...], isError}；图片在前、OCR JSON 与说明文字在后。
    static func toolResult(_ reply: MCPCaptureReply) -> [String: Any] {
        switch reply {
        case .failed(let message):
            return toolError(message)
        case .cancelled:
            return ["content": [textContent(AppConstants.mcpCancelledMessage)], "isError": false]
        case .completed(let images, let text, let warning):
            var content: [[String: Any]] = images.map {
                ["type": "image", "data": $0.base64EncodedString(), "mimeType": "image/png"]
            }
            if let text {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                // 结构体只含字符串与整数，编码不会失败。
                let json = String(decoding: try! encoder.encode(text), as: UTF8.self)
                content.append(textContent(json))
            }
            if let warning { content.append(textContent(warning)) }
            return ["content": content, "isError": false]
        }
    }

    /// 作用：生成工具执行错误结果。
    /// 参数 message：返回给 agent 的错误文案。
    /// 返回：{content: [text], isError: true}。
    static func toolError(_ message: String) -> [String: Any] {
        ["content": [textContent(message)], "isError": true]
    }

    /// 作用：生成 JSON-RPC 成功响应。参数 id：请求 id；result：结果对象。返回：响应对象。
    static func response(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    /// 作用：生成 JSON-RPC 错误响应。参数 id：请求 id，无法解析时为 NSNull；code、message：错误码与说明。
    /// 返回：响应对象。
    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// 作用：生成单个工具定义。参数 tool：工具；description：说明；properties：参数 JSON Schema。
    /// 返回：{name, description, inputSchema}。
    private static func schema(_ tool: MCPTool, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        [
            "name": tool.rawValue,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false],
        ]
    }

    /// 作用：生成文本内容块。参数 text：文本。返回：{type: text, text}。
    private static func textContent(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }
}

/// 一次 tools/call 到 App 的转发；持有连接以便 notifications/cancelled 中断等待。
/// App 通过连接断开得知 agent 已放弃，并关闭对应的截图会话。
final class MCPForwardCall {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    /// 作用：同步发送请求并等待 App 结果，在后台线程调用。
    /// 参数 request：截图请求；path：App socket 路径。
    /// 返回：App 结果；连不上 App 为「TranslateApp 未运行」，被取消时返回 nil。
    func run(_ request: MCPCaptureRequest, path: String) -> MCPCaptureReply? {
        let connected: Int32
        do {
            connected = try MCPSocket.connect(path: path)
        } catch MCPSocketError.notRunning {
            return .failed(message: AppConstants.mcpNotRunningMessage)
        } catch {
            return .failed(message: "无法连接 TranslateApp：\(error)")
        }
        guard attach(connected) else { return nil }
        defer { detachAndClose(connected) }
        do {
            try MCPSocket.writeLine(JSONEncoder().encode(request), to: connected)
            guard let line = try MCPSocket.readLine(from: connected) else {
                return isCancelled ? nil : .failed(message: "TranslateApp 未返回结果")
            }
            return try JSONDecoder().decode(MCPCaptureReply.self, from: line)
        } catch {
            return isCancelled ? nil : .failed(message: "与 TranslateApp 通信失败：\(error)")
        }
    }

    /// 作用：取消等待；关闭连接的读写两端，使 run 立即返回 nil。
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 作用：登记连接以便取消。参数 connected：已连接 fd。返回：已被取消时关闭连接并返回 false。
    private func attach(_ connected: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            close(connected)
            return false
        }
        fd = connected
        return true
    }

    /// 作用：先注销再关闭连接，避免 cancel 对已复用的 fd 调用 shutdown。参数 connected：登记过的 fd。
    private func detachAndClose(_ connected: Int32) {
        lock.lock()
        fd = -1
        lock.unlock()
        close(connected)
    }
}

/// helper 的 stdio MCP 会话：每行一条 JSON-RPC 消息。
/// initialize、tools/list、ping 在本地应答；tools/call 在后台转发给 App，期间仍处理 ping 与取消通知。
final class MCPHelperSession {
    private let socketPath: String
    private let version: String
    private let write: (Data) -> Void
    private let lock = NSLock()
    /// 进行中的 tools/call，键为类型前缀加 id 文本，区分数字 1 与字符串 "1"。
    private var calls: [String: MCPForwardCall] = [:]

    /// 参数 socketPath：App socket 路径；version：serverInfo.version；
    /// write：接收一条不含换行的 JSON 消息并写到 stdout，由会话串行调用。
    init(socketPath: String, version: String, write: @escaping (Data) -> Void) {
        self.socketPath = socketPath
        self.version = version
        self.write = write
    }

    /// 作用：处理客户端发来的一行消息，需要时写出响应。
    /// 参数 line：不含换行的 JSON-RPC 消息。
    func receive(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) else {
            return emit(MCPProtocol.error(id: NSNull(), code: MCPProtocol.parseError, message: "Parse error"))
        }
        guard let object = message as? [String: Any], object["jsonrpc"] as? String == "2.0",
              let method = object["method"] as? String else {
            let id = (message as? [String: Any])?["id"] ?? NSNull()
            return emit(MCPProtocol.error(id: id, code: MCPProtocol.invalidRequest, message: "Invalid Request"))
        }
        let params = object["params"] as? [String: Any] ?? [:]
        guard let id = object["id"] else { return notify(method, params: params) }
        guard let key = Self.key(id) else {
            return emit(MCPProtocol.error(id: NSNull(), code: MCPProtocol.invalidRequest, message: "Invalid Request"))
        }

        switch method {
        case "initialize":
            emit(MCPProtocol.response(id: id, result: MCPProtocol.initializeResult(params: params, version: version)))
        case "ping":
            emit(MCPProtocol.response(id: id, result: [:]))
        case "tools/list":
            emit(MCPProtocol.response(id: id, result: MCPProtocol.toolsListResult()))
        case "tools/call":
            call(id: id, key: key, params: params)
        default:
            emit(MCPProtocol.error(id: id, code: MCPProtocol.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    /// 作用：校验 tools/call 参数并在后台转发给 App，完成后写出结果；被取消的请求不写响应。
    /// 参数 id：原始请求 id；key：取消用的规范化 id；params：tools/call 参数。
    private func call(id: Any, key: String, params: [String: Any]) {
        let request: MCPCaptureRequest
        do {
            request = try MCPProtocol.captureRequest(params: params)
        } catch {
            switch error {
            case .unknownTool(let name):
                return emit(MCPProtocol.error(id: id, code: MCPProtocol.invalidParams, message: "Unknown tool: \(name)"))
            case .invalidArgument(let message):
                return emit(MCPProtocol.response(id: id, result: MCPProtocol.toolError(message)))
            }
        }

        let forward = MCPForwardCall()
        lock.lock()
        calls[key] = forward
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let reply = forward.run(request, path: socketPath)
            lock.lock()
            calls[key] = nil
            lock.unlock()
            // 按 MCP 取消约定，已取消的请求不再响应。
            guard let reply else { return }
            emit(MCPProtocol.response(id: id, result: MCPProtocol.toolResult(reply)))
        }
    }

    /// 作用：处理通知；只响应 notifications/cancelled，其余通知无需动作。
    /// 参数 method：通知名；params：通知参数，取消时读取 requestId。
    private func notify(_ method: String, params: [String: Any]) {
        guard method == "notifications/cancelled", let id = params["requestId"], let key = Self.key(id) else { return }
        lock.lock()
        let forward = calls[key]
        lock.unlock()
        forward?.cancel()
    }

    /// 作用：串行化并写出一条消息。参数 object：JSON-RPC 消息对象。
    private func emit(_ object: [String: Any]) {
        // 消息由本文件构造，只含 JSON 可表示的值，序列化不会失败。
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        lock.lock()
        defer { lock.unlock() }
        write(data)
    }

    /// 作用：把 JSON-RPC id 规范化为字典键。参数 id：解析后的 id。返回：字符串或数字 id 的键，其他类型为 nil。
    private static func key(_ id: Any) -> String? {
        if let text = id as? String { return "s:\(text)" }
        if let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return "n:\(number.stringValue)" }
        return nil
    }
}
