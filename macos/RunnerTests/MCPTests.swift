import Darwin
import XCTest

@testable import translate_app

/// 验证 MCP helper 的 JSON-RPC 编解码、参数到截图请求的转换、App 结果到工具结果的转换，
/// 以及 App 未运行与取消时的输出（#96 验收 1）。socket 均为临时目录中的真实 Unix socket。
final class MCPTests: XCTestCase {
    /// 收集会话写出的消息；达到期望条数时完成 expectation。
    private final class Output {
        private let lock = NSLock()
        private var messages: [[String: Any]] = []
        var expectation: XCTestExpectation?
        var expectedCount = 0

        /// 参数 data：会话写出的一行 JSON。
        func append(_ data: Data) {
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            lock.lock()
            messages.append(object)
            let reached = messages.count == expectedCount
            lock.unlock()
            if reached { expectation?.fulfill() }
        }

        var all: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    /// 模拟运行中 App 的一次连接：读取请求后由 respond 决定回复；respond 返回 nil 时等待对端关闭。
    private final class FakeApp {
        private let lock = NSLock()
        private(set) var request: MCPCaptureRequest?
        let fd: Int32
        let closed = XCTestExpectation(description: "helper 关闭连接")

        /// 参数 path：socket 路径；respond：收到请求后的结果，nil 表示不回复。
        init(path: String, respond: @escaping (MCPCaptureRequest) -> MCPCaptureReply?) throws {
            fd = try MCPSocket.listen(path: path)
            let listener = fd
            Thread.detachNewThread { [self] in
                let connection = accept(listener, nil, nil)
                defer { close(connection) }
                let line = try! MCPSocket.readLine(from: connection)!
                let received = try! JSONDecoder().decode(MCPCaptureRequest.self, from: line)
                lock.lock()
                request = received
                lock.unlock()
                if let reply = respond(received) {
                    try! MCPSocket.writeLine(JSONEncoder().encode(reply), to: connection)
                    return
                }
                // 对端 shutdown 或进程退出后 readLine 返回 nil，代表 App 观察到 agent 放弃。
                if try! MCPSocket.readLine(from: connection) == nil { closed.fulfill() }
            }
        }

        var received: MCPCaptureRequest? {
            lock.lock()
            defer { lock.unlock() }
            return request
        }
    }

    private var socketPath = ""

    override func setUp() {
        // sun_path 上限 104 字节，使用短文件名。
        socketPath = NSTemporaryDirectory() + "mcp-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        unlink(socketPath)
    }

    /// 作用：把多行消息交给新会话并等待指定条数的输出。
    /// 参数 lines：JSON-RPC 文本；count：期望输出条数，0 表示等待 300ms 确认没有输出。
    /// 返回：按写出顺序排列的消息对象。
    private func exchange(_ lines: [String], count: Int) -> [[String: Any]] {
        let output = Output()
        let done = expectation(description: "收到 \(count) 条输出")
        done.isInverted = count == 0
        output.expectation = done
        output.expectedCount = max(count, 1)
        let session = MCPHelperSession(socketPath: socketPath, version: "test") { output.append($0) }
        lines.forEach { session.receive(Data($0.utf8)) }
        wait(for: [done], timeout: count == 0 ? 0.3 : 5)
        return output.all
    }

    /// 作用：取出 tools/call 结果的内容块与 isError。参数 message：响应对象。返回：(content, isError)。
    private func toolResult(_ message: [String: Any]) -> (content: [[String: Any]], isError: Bool) {
        let result = message["result"] as! [String: Any]
        return (result["content"] as! [[String: Any]], result["isError"] as! Bool)
    }

    /// 解析失败、缺少 method、未知方法分别返回 -32700、-32600、-32601；通知不产生输出。
    /// 边界依据：JSON-RPC 2.0 规范的标准错误码，以及“通知不得响应”的约定。
    func testEnvelopeErrorsAndNotificationsFollowJsonRpc() {
        let messages = exchange([
            "not json",
            #"{"jsonrpc":"2.0","id":1}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#,
        ], count: 3)
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages[0]["id"] is NSNull)
        XCTAssertEqual((messages[0]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.parseError)
        XCTAssertEqual(messages[1]["id"] as? Int, 1)
        XCTAssertEqual((messages[1]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.invalidRequest)
        XCTAssertEqual(messages[2]["id"] as? Int, 2)
        XCTAssertEqual((messages[2]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.methodNotFound)
    }

    /// initialize 原样回应支持的版本，不支持的版本回应最新版本；ping 返回空结果。
    /// 边界依据：MCP 生命周期规范的版本协商规则。
    func testInitializeNegotiatesVersionAndPingAnswersEmpty() {
        let messages = exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
            #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#,
        ], count: 3)
        let accepted = messages[0]["result"] as! [String: Any]
        XCTAssertEqual(accepted["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((accepted["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((accepted["serverInfo"] as? [String: Any])?["name"] as? String, AppConstants.mcpServerName)
        XCTAssertEqual((messages[1]["result"] as? [String: Any])?["protocolVersion"] as? String, MCPProtocol.supportedVersions[0])
        XCTAssertEqual(messages[2]["id"] as? String, "p")
        XCTAssertEqual((messages[2]["result"] as? [String: Any])?.count, 0)
    }

    /// tools/list 声明三个工具，output 参数取值为 image、text、both，默认 both；只有 capture_screen 带 display。
    func testToolsListDeclaresThreeCaptureTools() {
        let messages = exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#], count: 1)
        let tools = (messages[0]["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["capture_screen", "capture_region", "capture_scrolling"])
        for tool in tools {
            let properties = (tool["inputSchema"] as! [String: Any])["properties"] as! [String: Any]
            let output = properties["output"] as! [String: Any]
            XCTAssertEqual(output["enum"] as? [String], ["image", "text", "both"])
            XCTAssertEqual(output["default"] as? String, "both")
            XCTAssertEqual(properties["display"] != nil, tool["name"] as? String == "capture_screen")
        }
    }

    /// 未知工具返回 JSON-RPC 参数错误；output 取值、display 负数、布尔与小数都返回 isError 工具结果。
    /// 边界依据：display 为从 0 开始的整数序号，-1、true、1.5 分别覆盖下界、类型桥接与非整数。
    func testInvalidToolArgumentsAreRejectedBeforeContactingApp() {
        let messages = exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture_window"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_screen","arguments":{"output":"pdf"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capture_screen","arguments":{"display":-1}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"capture_screen","arguments":{"display":true}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"capture_screen","arguments":{"display":1.5}}}"#,
        ], count: 5)
        XCTAssertEqual((messages[0]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.invalidParams)
        for message in messages.dropFirst() {
            XCTAssertTrue(toolResult(message).isError)
        }
        XCTAssertEqual(toolResult(messages[1]).content.first?["text"] as? String, "output 只能是 image、text 或 both")
    }

    /// 没有 socket 文件与残留 socket 文件都返回「TranslateApp 未运行」。
    /// 边界依据：App 退出后 socket 文件可能残留，连接被拒绝同样代表未运行。
    func testAppNotRunningReturnsToolError() throws {
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture_screen"}}"#
        let missing = exchange([call], count: 1)
        XCTAssertEqual(toolResult(missing[0]).content.first?["text"] as? String, AppConstants.mcpNotRunningMessage)
        XCTAssertTrue(toolResult(missing[0]).isError)

        close(try MCPSocket.listen(path: socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let stale = exchange([call], count: 1)
        XCTAssertEqual(toolResult(stale[0]).content.first?["text"] as? String, AppConstants.mcpNotRunningMessage)
    }

    /// 缺省参数转换为 output=both 且无 display；结果按图片、OCR JSON、说明文字的顺序返回。
    func testCaptureRequestReachesAppAndCompletedReplyBecomesContent() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let text = MCPRecognizedText(width: 100, height: 40, paragraphs: [
            MCPParagraph(text: "你好", x: 1, y: 2, width: 30, height: 12, chunk: nil),
        ])
        let app = try FakeApp(path: socketPath) { _ in .completed(images: [png], text: text, warning: "提示") }
        defer { close(app.fd) }
        let messages = exchange([#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"capture_screen"}}"#], count: 1)

        XCTAssertEqual(app.received, MCPCaptureRequest(tool: .captureScreen, output: .both, display: nil, prompt: nil))
        let result = toolResult(messages[0])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 3)
        XCTAssertEqual(result.content[0]["type"] as? String, "image")
        XCTAssertEqual(result.content[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(result.content[0]["data"] as? String, png.base64EncodedString())
        let json = try XCTUnwrap((result.content[1]["text"] as? String)?.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(MCPRecognizedText.self, from: json), text)
        XCTAssertEqual(result.content[2]["text"] as? String, "提示")
    }

    /// 交互工具忽略 display；空 prompt 视为未提供；用户取消返回非错误的取消结果。
    func testInteractiveRequestCarriesPromptAndCancelledReplyIsNotError() throws {
        let app = try FakeApp(path: socketPath) { _ in .cancelled }
        defer { close(app.fd) }
        let messages = exchange([
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capture_region","arguments":{"prompt":"框选报错","output":"text","display":2}}}"#,
        ], count: 1)
        XCTAssertEqual(app.received, MCPCaptureRequest(tool: .captureRegion, output: .text, display: nil, prompt: "框选报错"))
        let result = toolResult(messages[0])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.first?["text"] as? String, AppConstants.mcpCancelledMessage)
        XCTAssertNil(try MCPProtocol.captureRequest(params: ["name": "capture_scrolling", "arguments": ["prompt": ""]]).prompt)
    }

    /// notifications/cancelled 关闭对应连接，App 侧读到连接结束，helper 不再响应该请求。
    func testCancelNotificationClosesConnectionWithoutResponse() throws {
        let app = try FakeApp(path: socketPath) { _ in nil }
        defer { close(app.fd) }
        let output = Output()
        let session = MCPHelperSession(socketPath: socketPath, version: "test") { output.append($0) }
        session.receive(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"capture_scrolling"}}"#.utf8))
        // 等 App 收到请求后再取消，覆盖“等待用户操作期间放弃”的路径。
        let received = expectation(for: NSPredicate { _, _ in app.received != nil }, evaluatedWith: nil)
        wait(for: [received], timeout: 5)
        session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#.utf8))
        wait(for: [app.closed], timeout: 5)

        let silent = expectation(description: "取消后不响应")
        silent.isInverted = true
        output.expectation = silent
        output.expectedCount = 1
        wait(for: [silent], timeout: 0.3)
        XCTAssertTrue(output.all.isEmpty)
    }

    /// socket 文件权限为 0600；同一路径已有实例服务时拒绝再次监听，避免抢走对方连接。
    func testListenUsesOwnerOnlyPermissionAndRefusesSecondServer() throws {
        let fd = try MCPSocket.listen(path: socketPath)
        defer { close(fd) }
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try MCPSocket.listen(path: socketPath)) {
            XCTAssertEqual($0 as? MCPSocketError, .alreadyServing)
        }
    }
}
