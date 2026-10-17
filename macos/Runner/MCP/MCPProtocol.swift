import Darwin
import Foundation

/// helper 转给 App 的工具请求，由 tools/call 参数校验后生成（#96「工具」）。
/// display 为 NSScreen.screens 的 0 起序号；capture_rect 的矩形为该显示器 capture_screen 输出图的像素坐标；
/// windowID 为 list_windows 返回的 window_id。坐标是否落在图内由 App 按实际截图尺寸校验。
enum MCPToolRequest: Codable, Equatable {
    case listDisplays
    case listWindows
    case captureScreen(display: Int, output: MCPOutput)
    case captureRect(display: Int, x: Int, y: Int, width: Int, height: Int, output: MCPOutput)
    case captureWindow(windowID: UInt32, output: MCPOutput)
}

/// 显示器信息；x/y/width/height 为全局点坐标（原点主显示器左上角，y 向下），
/// image_width/image_height 为该显示器 capture_screen 输出图的像素尺寸。
struct MCPDisplayInfo: Codable, Equatable {
    let display: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let scale: Double
    let imageWidth: Int
    let imageHeight: Int

    enum CodingKeys: String, CodingKey {
        case display, x, y, width, height, scale
        case imageWidth = "image_width"
        case imageHeight = "image_height"
    }
}

/// 屏上可见窗口；display 为相交面积最大的显示器序号，x/y/width/height 为全局点坐标。
struct MCPWindowInfo: Codable, Equatable {
    let windowID: UInt32
    let app: String
    let title: String
    let display: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case app, title, display, x, y, width, height
    }
}

/// OCR 段落；坐标为返回图片的像素坐标，原点左上。
struct MCPParagraph: Codable, Equatable {
    let text: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// OCR 文本结果；width、height 为返回图片的像素尺寸。
struct MCPRecognizedText: Codable, Equatable {
    let width: Int
    let height: Int
    let paragraphs: [MCPParagraph]
}

/// App 回给 helper 的工具结果。
/// displays/windows：清单；image：PNG（output 为 text 时为 nil）与 OCR 结果（output 为 image 时为 nil）；
/// failed：message 为返回给 agent 的错误文案。
enum MCPToolReply: Codable, Equatable {
    case displays([MCPDisplayInfo])
    case windows([MCPWindowInfo])
    case image(png: Data?, text: MCPRecognizedText?)
    case failed(message: String)
}

/// tools/call 参数无法转换为工具请求的原因。
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
            "description": "image 只返回 PNG；text 只返回 OCR 段落 JSON {width, height, paragraphs: [{text, x, y, width, height}]}，坐标为返回图片的像素坐标、原点左上；both 两者都返回。",
        ]
        let display: [String: Any] = [
            "type": "integer", "minimum": 0,
            "description": "显示器序号，取 list_displays 的 display；0 为主显示器。",
        ]
        let pixel = { (description: String, minimum: Int) -> [String: Any] in
            ["type": "integer", "minimum": minimum, "description": description]
        }
        let tools: [[String: Any]] = MCPTool.allCases.map { tool in
            switch tool {
            case .listDisplays:
                return schema(tool, "列出显示器：序号、全局点坐标范围（原点主显示器左上角，y 向下）、缩放倍率，以及该显示器 capture_screen 输出图的像素宽高 image_width、image_height。", [:])
            case .listWindows:
                return schema(tool, "列出屏上可见的普通窗口：window_id、应用名、标题、所在显示器序号与全局点坐标范围。", [:])
            case .captureScreen:
                return schema(tool, "截取整块显示器。图片长边不超过 1568 像素。", ["display": display, "output": output])
            case .captureRect:
                return schema(tool, "截取显示器内的矩形区域：坐标取该显示器 capture_screen 输出图的像素坐标（原点左上），App 从原始分辨率裁剪，适合放大查看局部小字。矩形须完全落在输出图内。图片长边不超过 1568 像素。", [
                    "display": display,
                    "x": pixel("左边缘，capture_screen 输出图像素。", 0),
                    "y": pixel("上边缘，capture_screen 输出图像素。", 0),
                    "width": pixel("宽度，capture_screen 输出图像素。", 1),
                    "height": pixel("高度，capture_screen 输出图像素。", 1),
                    "output": output,
                ], required: ["display", "x", "y", "width", "height"])
            case .captureWindow:
                return schema(tool, "截取单个窗口，窗口被遮挡也能截到窗口自身内容。图片长边不超过 1568 像素。", [
                    "window_id": pixel("取 list_windows 返回的 window_id。", 1),
                    "output": output,
                ], required: ["window_id"])
            }
        }
        return ["tools": tools]
    }

    /// 作用：把 tools/call 参数转换为工具请求。
    /// 参数 params：{name, arguments?}；arguments 缺省视为空对象，未知字段忽略。
    /// 返回：校验后的请求；工具不存在抛 unknownTool，参数缺失、类型或取值不合法抛 invalidArgument。
    static func toolRequest(params: [String: Any]) throws(MCPRequestError) -> MCPToolRequest {
        let name = params["name"] as? String ?? ""
        guard let tool = MCPTool(rawValue: name) else { throw .unknownTool(name) }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        var output = MCPOutput.both
        if let raw = arguments["output"] {
            guard let value = (raw as? String).flatMap(MCPOutput.init(rawValue:)) else {
                throw .invalidArgument("output 只能是 image、text 或 both")
            }
            output = value
        }

        switch tool {
        case .listDisplays:
            return .listDisplays
        case .listWindows:
            return .listWindows
        case .captureScreen:
            let display = try integer(arguments, "display", minimum: 0) ?? 0
            return .captureScreen(display: display, output: output)
        case .captureRect:
            return .captureRect(
                display: try required(arguments, "display", minimum: 0),
                x: try required(arguments, "x", minimum: 0),
                y: try required(arguments, "y", minimum: 0),
                width: try required(arguments, "width", minimum: 1),
                height: try required(arguments, "height", minimum: 1),
                output: output
            )
        case .captureWindow:
            let id = try required(arguments, "window_id", minimum: 1)
            guard id <= Int(UInt32.max) else { throw .invalidArgument("window_id 不存在") }
            return .captureWindow(windowID: UInt32(id), output: output)
        }
    }

    /// 作用：把 App 结果转换为 MCP CallToolResult。
    /// 参数 reply：App 返回的工具结果。
    /// 返回：{content: [...], isError}；清单为一段 JSON 文本，截图为图片在前、OCR JSON 在后。
    static func toolResult(_ reply: MCPToolReply) -> [String: Any] {
        switch reply {
        case .failed(let message):
            return toolError(message)
        case .displays(let displays):
            return ["content": [textContent(json(["displays": displays]))], "isError": false]
        case .windows(let windows):
            return ["content": [textContent(json(["windows": windows]))], "isError": false]
        case .image(let png, let text):
            var content: [[String: Any]] = []
            if let png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            if let text { content.append(textContent(json(text))) }
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

    /// 作用：读取必填整数参数。参数 arguments：工具参数；key：字段名；minimum：允许的最小值。
    /// 返回：参数值；缺失或不合法时抛 invalidArgument。
    private static func required(_ arguments: [String: Any], _ key: String, minimum: Int) throws(MCPRequestError) -> Int {
        guard let value = try integer(arguments, key, minimum: minimum) else {
            throw .invalidArgument("缺少参数 \(key)")
        }
        return value
    }

    /// 作用：读取可选整数参数。参数 arguments：工具参数；key：字段名；minimum：允许的最小值。
    /// 返回：参数值，缺失为 nil；布尔、小数、字符串或小于 minimum 时抛 invalidArgument。
    private static func integer(_ arguments: [String: Any], _ key: String, minimum: Int) throws(MCPRequestError) -> Int? {
        guard let raw = arguments[key] else { return nil }
        // JSON 布尔值同样桥接为 NSNumber，需要排除；小数不能静默截断。
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), number.doubleValue >= Double(minimum),
              number.doubleValue <= Double(Int.max) else {
            throw .invalidArgument("\(key) 必须是不小于 \(minimum) 的整数")
        }
        return number.intValue
    }

    /// 作用：生成单个工具定义。参数 tool：工具；description：说明；properties：参数 JSON Schema；required：必填字段。
    /// 返回：{name, description, inputSchema}。
    private static func schema(
        _ tool: MCPTool, _ description: String, _ properties: [String: Any], required: [String] = []
    ) -> [String: Any] {
        var input: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { input["required"] = required }
        return ["name": tool.rawValue, "description": description, "inputSchema": input]
    }

    /// 作用：把清单或 OCR 结构编码为 JSON 文本。参数 value：只含字符串与数字的结构。返回：JSON 字符串。
    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // 结构只含字符串与有限数字，编码不会失败。
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
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
    /// 参数 request：工具请求；path：App socket 路径。
    /// 返回：App 结果；连不上 App 为「TranslateApp 未运行」，被取消时返回 nil。
    func run(_ request: MCPToolRequest, path: String) -> MCPToolReply? {
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
            return try JSONDecoder().decode(MCPToolReply.self, from: line)
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
        let request: MCPToolRequest
        do {
            request = try MCPProtocol.toolRequest(params: params)
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
