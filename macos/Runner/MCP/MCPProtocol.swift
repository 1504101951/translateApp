import Darwin
import Foundation

/// 截图工具共用选项（#96「工具」）：output 决定返回图片和/或 OCR Markdown，detail 决定图片 token 上限，
/// includePositions 为 Markdown 每块加像素位置行。
struct MCPCaptureOptions: Codable, Equatable {
    let output: MCPOutput
    let detail: MCPDetail
    let includePositions: Bool
}

/// helper 转给 App 的工具请求，由 tools/call 参数校验后生成（#96「工具」）。
/// displayIndex 为 NSScreen.screens 的 0 起序号；captureRect 的矩形为该显示器在 referenceDetail 下
/// capture_screen 输出图的像素坐标；windowID 为 list_windows 返回的 window_id。
/// 坐标是否落在图内由 App 按实际截图尺寸校验。
enum MCPToolRequest: Codable, Equatable {
    case listDisplays
    case listWindows
    case captureScreen(displayIndex: Int, options: MCPCaptureOptions)
    case captureRect(
        displayIndex: Int, x: Int, y: Int, width: Int, height: Int,
        referenceDetail: MCPDetail, options: MCPCaptureOptions
    )
    case captureWindow(windowID: UInt32, options: MCPCaptureOptions)
}

/// 显示器一行：两种清晰度下 capture_screen 输出图的像素尺寸。
struct MCPDisplayInfo: Codable, Equatable {
    let displayIndex: Int
    let standardWidth: Int
    let standardHeight: Int
    let lowWidth: Int
    let lowHeight: Int
}

/// 窗口一行：x/y/width/height 为窗口在所在显示器 standard 输出图中的像素范围，已裁到图内。
struct MCPWindowInfo: Codable, Equatable {
    let windowID: UInt32
    let displayIndex: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let app: String
    let title: String
}

/// App 回给 helper 的工具结果。
/// displays/windows：清单；image：PNG（output 为 text 时为 nil）与 OCR Markdown（output 为 image 时为 nil）；
/// failed：message 为返回给 agent 的错误文案。
enum MCPToolReply: Codable, Equatable {
    case displays([MCPDisplayInfo])
    case windows([MCPWindowInfo])
    case image(png: Data?, markdown: String?)
    case failed(message: String)
}

/// tools/call 参数无法转换为工具请求的原因。
/// unknownTool 按 JSON-RPC 参数错误返回；invalidArgument 作为工具错误结果返回，便于 agent 自行修正。
enum MCPRequestError: Error, Equatable {
    case unknownTool(String)
    case invalidArgument(String)
}

/// 保持对象键顺序的 JSON 值；JSONEncoder 与 JSONSerialization 都不保证键顺序，tools/list 需要按声明顺序输出参数。
indirect enum MCPOrderedJSON: Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([MCPOrderedJSON])
    case object([(String, MCPOrderedJSON)])

    /// 作用：序列化为紧凑 JSON。返回：UTF-8 数据，对象键按构造顺序输出。
    var data: Data {
        switch self {
        case .string(let value):
            // 字符串交给 JSONSerialization 转义，避免手写转义遗漏控制字符；Swift 字符串总是合法 Unicode，片段一定可序列化。
            return MCPProtocol.fragment(value)!
        case .integer(let value):
            return Data(String(value).utf8)
        case .boolean(let value):
            return Data((value ? "true" : "false").utf8)
        case .array(let values):
            return Data("[".utf8) + Data(values.map(\.data).joined(separator: Data(",".utf8))) + Data("]".utf8)
        case .object(let members):
            let pairs = members.map { MCPOrderedJSON.string($0.0).data + Data(":".utf8) + $0.1.data }
            return Data("{".utf8) + Data(pairs.joined(separator: Data(",".utf8))) + Data("}".utf8)
        }
    }

    static func == (lhs: MCPOrderedJSON, rhs: MCPOrderedJSON) -> Bool { lhs.data == rhs.data }
}

/// tools/list 中的一个参数；约束用 schema 关键字表达，description 只写关键字无法表达的约束（#96 决策 6）。
/// 输出顺序为 type、minimum、enum、default、description，缺省项不输出。
struct MCPParameter {
    let name: String
    let type: String
    var minimum: Int?
    var values: [String]?
    var defaultValue: MCPOrderedJSON?
    var description: String?

    /// 作用：生成该参数的 schema 对象。返回：保序 JSON 对象。
    var schema: MCPOrderedJSON {
        var members: [(String, MCPOrderedJSON)] = [("type", .string(type))]
        if let minimum { members.append(("minimum", .integer(minimum))) }
        if let values { members.append(("enum", .array(values.map(MCPOrderedJSON.string)))) }
        if let defaultValue { members.append(("default", defaultValue)) }
        if let description { members.append(("description", .string(description))) }
        return .object(members)
    }
}

/// tools/list 中的一个工具；参数按 parameters 的顺序输出。
struct MCPToolDefinition {
    let name: String
    let description: String
    let parameters: [MCPParameter]
    let required: [String]

    /// 作用：生成工具定义对象。返回：{name, description, inputSchema} 的保序 JSON。
    var json: MCPOrderedJSON {
        var schema: [(String, MCPOrderedJSON)] = [
            ("type", .string("object")),
            ("properties", .object(parameters.map { ($0.name, $0.schema) })),
        ]
        if !required.isEmpty { schema.append(("required", .array(required.map(MCPOrderedJSON.string)))) }
        schema.append(("additionalProperties", .boolean(false)))
        return .object([("name", .string(name)), ("description", .string(description)), ("inputSchema", .object(schema))])
    }
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
    static let internalError = -32603

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

    /// 作用：返回五个工具的定义，说明与参数原文见 #96「工具」。
    /// 返回：按 MCPTool.allCases 顺序排列的定义。
    static func toolDefinitions() -> [MCPToolDefinition] {
        let displayIndex = { (defaultValue: MCPOrderedJSON?) in
            MCPParameter(
                name: "display_index", type: "integer", minimum: 0,
                defaultValue: defaultValue, description: "From list_displays"
            )
        }
        let capture = [
            MCPParameter(
                name: "output", type: "string", values: MCPOutput.allCases.map(\.rawValue),
                defaultValue: .string(MCPOutput.image.rawValue), description: "text: OCR as Markdown, no image"
            ),
            MCPParameter(
                name: "detail", type: "string", values: MCPDetail.allCases.map(\.rawValue),
                defaultValue: .string(MCPDetail.standard.rawValue),
                description: "Image tokens: low ≤ \(MCPDetail.low.tokenBudget), standard ≤ \(MCPDetail.standard.tokenBudget)"
            ),
            MCPParameter(
                name: "include_positions", type: "boolean", defaultValue: .boolean(false),
                description: "Applies when output includes text. Adds an [x,y,w,h] line before each block, in returned image pixels"
            ),
        ]
        return MCPTool.allCases.map { tool in
            switch tool {
            case .listDisplays:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "List connected displays. Use when you need screen information, or first to get display_index and the image sizes capture_screen returns.",
                    parameters: [], required: []
                )
            case .listWindows:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "List visible app windows. Use when you need screen information, to find a window_id for capture_window, or a window's rectangle for capture_rect.",
                    parameters: [], required: []
                )
            case .captureScreen:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Capture a whole display. Use for an overview of what is on screen; zoom into details with capture_rect.",
                    parameters: [displayIndex(.integer(0))] + capture, required: []
                )
            case .captureRect:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Capture part of a display at native resolution. Use to read small text or inspect details seen in capture_screen, or to OCR one area only.",
                    parameters: [
                        displayIndex(nil),
                        MCPParameter(name: "x", type: "integer", minimum: 0, description: "x + width ≤ image width of reference_detail in list_displays"),
                        MCPParameter(name: "y", type: "integer", minimum: 0, description: "y + height ≤ image height of reference_detail in list_displays"),
                        MCPParameter(name: "width", type: "integer", minimum: 1),
                        MCPParameter(name: "height", type: "integer", minimum: 1),
                        MCPParameter(
                            name: "reference_detail", type: "string", values: MCPDetail.allCases.map(\.rawValue),
                            defaultValue: .string(MCPDetail.standard.rawValue),
                            description: "Detail of the capture_screen image the coordinates come from"
                        ),
                    ] + capture,
                    required: ["display_index", "x", "y", "width", "height"]
                )
            case .captureWindow:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Capture one app window, even when covered by other windows. Use when the target is a specific window.",
                    parameters: [MCPParameter(name: "window_id", type: "integer", minimum: 1, description: "From list_windows")] + capture,
                    required: ["window_id"]
                )
            }
        }
    }

    /// 作用：生成 tools/list 结果的 JSON。
    /// 返回：{"tools": [...]} 的 UTF-8 数据，参数按声明顺序排列。
    static func toolsListResult() -> Data {
        MCPOrderedJSON.object([("tools", .array(toolDefinitions().map(\.json)))]).data
    }

    /// 作用：把 tools/call 参数转换为工具请求。
    /// 参数 params：{name, arguments?}；arguments 缺省视为空对象。
    /// 返回：校验后的请求；工具不存在抛 unknownTool，参数未声明、缺失、类型或取值不合法抛 invalidArgument。
    static func toolRequest(params: [String: Any]) throws(MCPRequestError) -> MCPToolRequest {
        let name = params["name"] as? String ?? ""
        guard let tool = MCPTool(rawValue: name) else { throw .unknownTool(name) }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        // 与 schema 的 additionalProperties: false 一致，未声明的参数明确报错，便于模型修正参数名。
        let declared = Set(toolDefinitions().first { $0.name == name }!.parameters.map(\.name))
        if let unknown = arguments.keys.sorted().first(where: { !declared.contains($0) }) {
            throw .invalidArgument("Unknown argument: \(unknown)")
        }

        switch tool {
        case .listDisplays:
            return .listDisplays
        case .listWindows:
            return .listWindows
        case .captureScreen:
            return .captureScreen(
                displayIndex: try integer(arguments, "display_index", minimum: 0) ?? 0,
                options: try options(arguments)
            )
        case .captureRect:
            return .captureRect(
                displayIndex: try required(arguments, "display_index", minimum: 0),
                x: try required(arguments, "x", minimum: 0),
                y: try required(arguments, "y", minimum: 0),
                width: try required(arguments, "width", minimum: 1),
                height: try required(arguments, "height", minimum: 1),
                referenceDetail: try choice(arguments, "reference_detail", default: MCPDetail.standard),
                options: try options(arguments)
            )
        case .captureWindow:
            let id = try required(arguments, "window_id", minimum: 1)
            guard id <= Int(UInt32.max) else { throw .invalidArgument("window_id \(id) not found; call list_windows again.") }
            return .captureWindow(windowID: UInt32(id), options: try options(arguments))
        }
    }

    /// 作用：把 App 结果转换为 MCP CallToolResult。
    /// 参数 reply：App 返回的工具结果。
    /// 返回：{content: [...], isError}；清单为制表符分隔的表格文本，截图为图片在前、Markdown 在后。
    static func toolResult(_ reply: MCPToolReply) -> [String: Any] {
        switch reply {
        case .failed(let message):
            return toolError(message)
        case .displays(let displays):
            let rows = displays.map {
                "\($0.displayIndex)\t\($0.standardWidth)\t\($0.standardHeight)\t\($0.lowWidth)\t\($0.lowHeight)"
            }
            let table = (["display_index\tstandard_image_width\tstandard_image_height\tlow_image_width\tlow_image_height"] + rows)
            return ["content": [textContent(table.joined(separator: "\n"))], "isError": false]
        case .windows(let windows):
            let rows = windows.map {
                "\($0.windowID)\t\($0.displayIndex)\t\($0.x)\t\($0.y)\t\($0.width)\t\($0.height)\t\(cell($0.app))\t\(cell($0.title))"
            }
            let table = ["window_id\tdisplay_index\tx\ty\twidth\theight\tapp\ttitle"] + rows
            return ["content": [textContent(table.joined(separator: "\n"))], "isError": false]
        case .image(let png, let markdown):
            var content: [[String: Any]] = []
            if let png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            if let markdown { content.append(textContent(markdown)) }
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

    /// 作用：序列化 JSON 片段（字符串、数字等）。参数 value：片段值。
    /// 返回：JSON 数据；值不能表示为 JSON（如 NaN、Infinity）时为 nil（#121）。
    /// JSONSerialization 遇到这类值抛出的是 Objective-C 异常而非 Swift 错误，必须先用 isValidJSONObject 校验；片段包成数组校验。
    static func fragment(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    /// 作用：序列化一条 JSON-RPC 消息（#121）。参数 object：消息对象。
    /// 返回：消息的 JSON 数据；含不可表示的值时改为同一 id 的内部错误响应，进程不崩溃。
    static func encode(_ object: [String: Any]) -> Data {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
            return data
        }
        return internalErrorData(id: object["id"])
    }

    /// 作用：生成内部错误响应的 JSON 数据。参数 id：原消息 id，缺省或不可表示时输出 null。
    /// 返回：JSON 数据；手工拼接，不再经过可能失败的序列化。
    static func internalErrorData(id: Any?) -> Data {
        let idJSON = id.flatMap(fragment) ?? Data("null".utf8)
        return Data(#"{"jsonrpc":"2.0","id":"#.utf8) + idJSON
            + Data(#","error":{"code":\#(internalError),"message":"Internal error: response is not JSON-serializable."}}"#.utf8)
    }

    /// 作用：生成 JSON-RPC 错误响应。参数 id：请求 id，无法解析时为 NSNull；code、message：错误码与说明。
    /// 返回：响应对象。
    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// 作用：读取截图共用选项。参数 arguments：工具参数。返回：缺省为 output=image、detail=standard、不带位置。
    private static func options(_ arguments: [String: Any]) throws(MCPRequestError) -> MCPCaptureOptions {
        MCPCaptureOptions(
            output: try choice(arguments, "output", default: MCPOutput.image),
            detail: try choice(arguments, "detail", default: MCPDetail.standard),
            includePositions: try boolean(arguments, "include_positions") ?? false
        )
    }

    /// 作用：读取枚举参数。参数 arguments：工具参数；key：字段名；defaultValue：缺省值。
    /// 返回：取值；不是声明的字符串取值时抛 invalidArgument。
    private static func choice<T: RawRepresentable & CaseIterable>(
        _ arguments: [String: Any], _ key: String, default defaultValue: T
    ) throws(MCPRequestError) -> T where T.RawValue == String {
        guard let raw = arguments[key] else { return defaultValue }
        guard let value = (raw as? String).flatMap(T.init(rawValue:)) else {
            throw .invalidArgument("\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }

    /// 作用：读取布尔参数。参数 arguments：工具参数；key：字段名。返回：缺失为 nil；不是 JSON 布尔值时抛 invalidArgument。
    private static func boolean(_ arguments: [String: Any], _ key: String) throws(MCPRequestError) -> Bool? {
        guard let raw = arguments[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw .invalidArgument("\(key) must be a boolean")
        }
        return number.boolValue
    }

    /// 作用：读取必填整数参数。参数 arguments：工具参数；key：字段名；minimum：允许的最小值。
    /// 返回：参数值；缺失或不合法时抛 invalidArgument。
    private static func required(_ arguments: [String: Any], _ key: String, minimum: Int) throws(MCPRequestError) -> Int {
        guard let value = try integer(arguments, key, minimum: minimum) else {
            throw .invalidArgument("Missing required argument: \(key)")
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
            throw .invalidArgument("\(key) must be an integer ≥ \(minimum)")
        }
        return number.intValue
    }

    /// 作用：清理表格单元格文字。参数 text：应用名或窗口标题。返回：制表符与换行替换为空格后的文字。
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
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
            return .failed(message: "Cannot connect to TranslateApp: \(error)")
        }
        guard attach(connected) else { return nil }
        defer { detachAndClose(connected) }
        do {
            try MCPSocket.writeLine(JSONEncoder().encode(request), to: connected)
            guard let line = try MCPSocket.readLine(from: connected) else {
                return isCancelled ? nil : .failed(message: "TranslateApp closed the connection without a result.")
            }
            return try JSONDecoder().decode(MCPToolReply.self, from: line)
        } catch is DecodingError {
            // 运行中的 App 与 helper 来自不同版本时结果结构不同。
            return isCancelled ? nil : .failed(message: AppConstants.mcpVersionMismatchMessage)
        } catch {
            return isCancelled ? nil : .failed(message: "Communication with TranslateApp failed: \(error)")
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
            emitRaw(id: id, result: MCPProtocol.toolsListResult())
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

    /// 作用：写出结果已编码为 JSON 的成功响应，保留结果内的键顺序。
    /// 参数 id：请求 id；result：结果对象的 JSON 数据。
    private func emitRaw(id: Any, result: Data) {
        // fragment 校验 id；不可表示时改为内部错误响应。
        guard let idJSON = MCPProtocol.fragment(id) else {
            lock.lock()
            defer { lock.unlock() }
            write(MCPProtocol.internalErrorData(id: nil))
            return
        }
        var data = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        data.append(idJSON)
        data.append(Data(#","result":"#.utf8))
        data.append(result)
        data.append(Data("}".utf8))
        lock.lock()
        defer { lock.unlock() }
        write(data)
    }

    /// 作用：串行化并写出一条消息。参数 object：JSON-RPC 消息对象。
    private func emit(_ object: [String: Any]) {
        // encode 校验后序列化；结果含 NaN 等不可表示的值时改为同一 id 的内部错误响应。
        let data = MCPProtocol.encode(object)
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
