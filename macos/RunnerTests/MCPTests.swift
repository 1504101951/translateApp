import AppKit
import Darwin
import XCTest

@testable import translate_app

/// 验证 MCP 接口（#96 验收 1）：JSON-RPC 编解码与错误响应、参数到工具请求的转换、结果到工具内容的转换、
/// 图片缩放尺寸与 capture_rect 坐标换算、取消、App 未运行与开关关闭的错误输出。
/// helper 与 App 之间使用临时目录中的真实 Unix socket 与真实 MCPCaptureServer。
final class MCPTests: XCTestCase {
    /// 收集 helper 会话写出的消息；达到期望条数时完成 expectation。
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

    private var socketPath = ""
    private var server: MCPCaptureServer?

    override func setUp() {
        // sun_path 上限 104 字节，使用短文件名。
        socketPath = NSTemporaryDirectory() + "mcp-\(UUID().uuidString.prefix(8)).sock"
    }

    @MainActor
    override func tearDown() {
        server?.stop()
        server = nil
        unlink(socketPath)
    }

    /// 作用：在临时 socket 上启动真实 App 侧服务。
    /// 参数 enabled：MCP 开关；run：工具执行方，替代需要真实屏幕的 MCPToolRunner。
    @MainActor
    private func startServer(enabled: Bool = true, run: @escaping MCPCaptureServer.Run) {
        let server = MCPCaptureServer(isEnabled: { enabled }, run: run)
        server.start(path: socketPath)
        self.server = server
    }

    /// 作用：把多行消息交给新的 helper 会话并等待指定条数的输出。
    /// 参数 lines：JSON-RPC 文本；count：期望输出条数。
    /// 返回：按写出顺序排列的消息对象。
    private func exchange(_ lines: [String], count: Int) async -> [[String: Any]] {
        let output = Output()
        let done = expectation(description: "收到 \(count) 条输出")
        output.expectation = done
        output.expectedCount = count
        let session = MCPHelperSession(socketPath: socketPath, version: "test") { output.append($0) }
        lines.forEach { session.receive(Data($0.utf8)) }
        await fulfillment(of: [done], timeout: 10)
        return output.all
    }

    /// 作用：取出 tools/call 结果的内容块与 isError。参数 message：响应对象。返回：(content, isError)。
    private func toolResult(_ message: [String: Any]) -> (content: [[String: Any]], isError: Bool) {
        let result = message["result"] as! [String: Any]
        return (result["content"] as! [[String: Any]], result["isError"] as! Bool)
    }

    /// 作用：生成白底黑字的测试 PNG。参数 width、height：像素尺寸；text、x、baseline：文字及其左下角像素位置（CG 左下原点）。
    /// 返回：PNG 数据。
    private func textImage(width: Int, height: Int, text: String, x: CGFloat, baseline: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: [
            .font: NSFont.systemFont(ofSize: 96), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(context.makeImage())
        return try ScreenCaptureService.pngData(from: image, scale: 1)
    }

    /// 解析失败、缺少 method、未知方法分别返回 -32700、-32600、-32601；通知不产生输出。
    /// 边界依据：JSON-RPC 2.0 规范的标准错误码，以及“通知不得响应”的约定。
    func testEnvelopeErrorsAndNotificationsFollowJsonRpc() async {
        let messages = await exchange([
            "not json",
            #"{"jsonrpc":"2.0","id":1}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#,
        ], count: 3)
        XCTAssertTrue(messages[0]["id"] is NSNull)
        XCTAssertEqual((messages[0]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.parseError)
        XCTAssertEqual(messages[1]["id"] as? Int, 1)
        XCTAssertEqual((messages[1]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.invalidRequest)
        XCTAssertEqual(messages[2]["id"] as? Int, 2)
        XCTAssertEqual((messages[2]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.methodNotFound)
    }

    /// initialize 原样回应支持的版本，不支持的版本回应最新版本；ping 返回空结果。
    /// 边界依据：MCP 生命周期规范的版本协商规则。
    func testInitializeNegotiatesVersionAndPingAnswersEmpty() async {
        let messages = await exchange([
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

    /// tools/list 声明五个工具；只有截图类工具带 output，capture_rect 与 capture_window 声明必填参数。
    func testToolsListDeclaresFiveAutomaticTools() async {
        let messages = await exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#], count: 1)
        let tools = (messages[0]["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.map { $0["name"] as? String },
                       ["list_displays", "list_windows", "capture_screen", "capture_rect", "capture_window"])
        let schemas = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as! String, $0["inputSchema"] as! [String: Any]) })
        for name in ["capture_screen", "capture_rect", "capture_window"] {
            let output = (schemas[name]!["properties"] as! [String: Any])["output"] as! [String: Any]
            XCTAssertEqual(output["enum"] as? [String], ["image", "text", "both"])
            XCTAssertEqual(output["default"] as? String, "both")
        }
        XCTAssertTrue((schemas["list_displays"]!["properties"] as! [String: Any]).isEmpty)
        XCTAssertEqual(schemas["capture_rect"]!["required"] as? [String], ["display", "x", "y", "width", "height"])
        XCTAssertEqual(schemas["capture_window"]!["required"] as? [String], ["window_id"])
    }

    /// 参数转换：缺省值、必填与取值范围。
    /// 边界依据：display 与 x、y 下界为 0，width、height、window_id 下界为 1；布尔与小数不得被当作整数；
    /// window_id 上界为 CGWindowID（UInt32）最大值。
    func testToolRequestConversionAndArgumentBounds() throws {
        XCTAssertEqual(try MCPProtocol.toolRequest(params: ["name": "capture_screen"]), .captureScreen(display: 0, output: .both))
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": [
                "display": 1, "x": 0, "y": 0, "width": 1, "height": 1, "output": "text",
            ]]),
            .captureRect(display: 1, x: 0, y: 0, width: 1, height: 1, output: .text)
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "capture_window", "arguments": ["window_id": Int(UInt32.max)]]),
            .captureWindow(windowID: UInt32.max, output: .both)
        )
        let invalid: [[String: Any]] = [
            ["display": -1],
            ["display": true],
            ["display": 1.5],
            ["output": "pdf"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_screen", "arguments": arguments]))
        }
        let rectBase: [String: Any] = ["display": 0, "x": 0, "y": 0, "width": 10, "height": 10]
        for (key, value) in [("width", 0), ("height", 0), ("x", -1)] as [(String, Any)] {
            var arguments = rectBase
            arguments[key] = value
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": arguments]), key)
        }
        var missing = rectBase
        missing["height"] = nil
        XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": missing])) {
            XCTAssertEqual($0 as? MCPRequestError, .invalidArgument("缺少参数 height"))
        }
        for id in [0, Int(UInt32.max) + 1] {
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_window", "arguments": ["window_id": id]]))
        }
    }

    /// 未知工具返回 JSON-RPC 参数错误；参数错误返回 isError 工具结果且不连接 App。
    func testInvalidToolCallsReturnErrorsWithoutApp() async {
        let messages = await exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture_region"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_screen","arguments":{"output":"pdf"}}}"#,
        ], count: 2)
        XCTAssertEqual((messages[0]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.invalidParams)
        XCTAssertTrue(toolResult(messages[1]).isError)
        XCTAssertEqual(toolResult(messages[1]).content.first?["text"] as? String, "output 只能是 image、text 或 both")
    }

    /// 没有 socket 文件与残留 socket 文件都返回「TranslateApp 未运行」。
    /// 边界依据：App 退出后 socket 文件可能残留，连接被拒绝同样代表未运行。
    func testAppNotRunningReturnsToolError() async throws {
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#
        let missing = await exchange([call], count: 1)
        XCTAssertEqual(toolResult(missing[0]).content.first?["text"] as? String, AppConstants.mcpNotRunningMessage)
        XCTAssertTrue(toolResult(missing[0]).isError)

        close(try MCPSocket.listen(path: socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let stale = await exchange([call], count: 1)
        XCTAssertEqual(toolResult(stale[0]).content.first?["text"] as? String, AppConstants.mcpNotRunningMessage)
    }

    /// 开关关闭时 App 返回「MCP 未开启」，不执行工具。
    @MainActor
    func testDisabledSwitchReturnsNotEnabled() async {
        var executed = false
        startServer(enabled: false) { _ in
            executed = true
            return .displays([])
        }
        let messages = await exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#], count: 1)
        XCTAssertTrue(toolResult(messages[0]).isError)
        XCTAssertEqual(toolResult(messages[0]).content.first?["text"] as? String, AppConstants.mcpDisabledMessage)
        XCTAssertFalse(executed)
    }

    /// 请求经真实 socket 到达 App；清单结果为一段 JSON，截图结果为图片在前、OCR JSON 在后。
    @MainActor
    func testRequestsReachAppAndRepliesBecomeContent() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let text = MCPRecognizedText(width: 100, height: 40, paragraphs: [
            MCPParagraph(text: "你好", x: 1, y: 2, width: 30, height: 12),
        ])
        let display = MCPDisplayInfo(display: 0, x: 0, y: 0, width: 1512, height: 982, scale: 2, imageWidth: 1568, imageHeight: 1018)
        var received: [MCPToolRequest] = []
        startServer { request in
            received.append(request)
            if case .listDisplays = request { return .displays([display]) }
            return .image(png: png, text: text)
        }
        let listing = await exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#], count: 1)
        let capture = await exchange([
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_rect","arguments":{"display":0,"x":10,"y":20,"width":30,"height":40}}}"#,
        ], count: 1)

        XCTAssertEqual(received, [.listDisplays, .captureRect(display: 0, x: 10, y: 20, width: 30, height: 40, output: .both)])
        let listJSON = try XCTUnwrap((toolResult(listing[0]).content.first?["text"] as? String)?.data(using: .utf8))
        let listObject = try XCTUnwrap(JSONSerialization.jsonObject(with: listJSON) as? [String: Any])
        let first = try XCTUnwrap((listObject["displays"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["image_width"] as? Int, 1568)
        XCTAssertEqual(first["image_height"] as? Int, 1018)

        let result = toolResult(capture[0])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 2)
        XCTAssertEqual(result.content[0]["type"] as? String, "image")
        XCTAssertEqual(result.content[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(result.content[0]["data"] as? String, png.base64EncodedString())
        let json = try XCTUnwrap((result.content[1]["text"] as? String)?.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(MCPRecognizedText.self, from: json), text)
    }

    /// notifications/cancelled 关闭对应连接，App 侧执行任务被取消，helper 不再响应该请求。
    @MainActor
    func testCancelNotificationCancelsAppTaskWithoutResponse() async {
        let started = expectation(description: "App 开始执行")
        let cancelled = expectation(description: "App 任务被取消")
        startServer { _ in
            started.fulfill()
            // 挂起直到任务取消，代表执行中的截图。
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }; continuation.resume() }
                }
            } onCancel: {
                cancelled.fulfill()
            }
            return .displays([])
        }
        let output = Output()
        let session = MCPHelperSession(socketPath: socketPath, version: "test") { output.append($0) }
        session.receive(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_windows"}}"#.utf8))
        await fulfillment(of: [started], timeout: 5)
        session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#.utf8))
        await fulfillment(of: [cancelled], timeout: 5)

        let silent = expectation(description: "取消后不响应")
        silent.isInverted = true
        output.expectation = silent
        output.expectedCount = 1
        await fulfillment(of: [silent], timeout: 0.5)
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

    /// 长边超过 1568 时等比缩到 1568，不足时保持原尺寸。
    /// 边界依据：#96 决策 3 的长边上限 1568 px；3024×1964 为 14 英寸 MacBook Pro 默认缩放的物理像素。
    func testFittedSizeCapsLongEdgeWithoutUpscaling() {
        let retina = MCPImageOutput.fitted(width: 3024, height: 1964)
        XCTAssertEqual(retina.width, 1568)
        XCTAssertEqual(retina.height, 1018)
        let portrait = MCPImageOutput.fitted(width: 1000, height: 3136)
        XCTAssertEqual(portrait.width, 500)
        XCTAssertEqual(portrait.height, 1568)
        let exact = MCPImageOutput.fitted(width: 1568, height: 10)
        XCTAssertEqual(exact.scale, 1)
        XCTAssertEqual(exact.width, 1568)
        let small = MCPImageOutput.fitted(width: 800, height: 600)
        XCTAssertEqual(small.scale, 1)
        XCTAssertEqual(small.width, 800)
    }

    /// capture_rect 坐标按输出图比例换算回原始像素并向外取整；超出输出图或宽高为 0 时拒绝。
    /// 边界依据：3024×1964 原图输出为 1568×1018；整图矩形必须换算为整张原图，右下边缘多 1 像素即越界。
    func testSourceRectMapsOutputCoordinatesToSourcePixels() {
        XCTAssertEqual(
            MCPImageOutput.sourceRect(x: 0, y: 0, width: 1568, height: 1018, sourceWidth: 3024, sourceHeight: 1964),
            CGRect(x: 0, y: 0, width: 3024, height: 1964)
        )
        // 100/(1568/3024) = 192.86 向下取 192；110/(1568/3024) = 212.14 向上取 213。
        XCTAssertEqual(
            MCPImageOutput.sourceRect(x: 100, y: 100, width: 10, height: 10, sourceWidth: 3024, sourceHeight: 1964),
            CGRect(x: 192, y: 192, width: 21, height: 21)
        )
        XCTAssertNil(MCPImageOutput.sourceRect(x: 1568, y: 0, width: 1, height: 1, sourceWidth: 3024, sourceHeight: 1964))
        XCTAssertNil(MCPImageOutput.sourceRect(x: 0, y: 1, width: 1, height: 1018, sourceWidth: 3024, sourceHeight: 1964))
        XCTAssertNil(MCPImageOutput.sourceRect(x: 0, y: 0, width: 0, height: 5, sourceWidth: 3024, sourceHeight: 1964))
        // 原图未超限时比例为 1，坐标原样对应。
        XCTAssertEqual(
            MCPImageOutput.sourceRect(x: 5, y: 6, width: 7, height: 8, sourceWidth: 800, sourceHeight: 600),
            CGRect(x: 5, y: 6, width: 7, height: 8)
        )
    }

    /// 截图结果：PNG 缩到长边 1568；OCR 在原图识别，段落坐标换算到返回图片；output 控制返回内容。
    /// 边界依据：3136 宽原图恰好缩放 0.5，文字左边缘 400 px 应换算为约 200 px。
    func testImageReplyScalesPngAndParagraphCoordinates() async throws {
        let png = try textImage(width: 3136, height: 400, text: "TranslateApp", x: 400, baseline: 140)
        let source = try MCPImageOutput.image(png)

        guard case .image(let both, let text) = try await MCPImageOutput.reply(source, output: .both) else {
            return XCTFail("应返回截图结果")
        }
        let returned = try MCPImageOutput.image(try XCTUnwrap(both))
        XCTAssertEqual(returned.width, 1568)
        XCTAssertEqual(returned.height, 200)
        let recognized = try XCTUnwrap(text)
        XCTAssertEqual(recognized.width, 1568)
        XCTAssertEqual(recognized.height, 200)
        let paragraph = try XCTUnwrap(recognized.paragraphs.first { $0.text.contains("TranslateApp") }, String(describing: recognized))
        XCTAssertEqual(Double(paragraph.x), 200, accuracy: 20)
        XCTAssertLessThanOrEqual(paragraph.x + paragraph.width, 1568)

        guard case .image(let imageOnly, let noText) = try await MCPImageOutput.reply(source, output: .image) else {
            return XCTFail("应返回截图结果")
        }
        XCTAssertNotNil(imageOnly)
        XCTAssertNil(noText)
        guard case .image(let noImage, let textOnly) = try await MCPImageOutput.reply(source, output: .text) else {
            return XCTFail("应返回截图结果")
        }
        XCTAssertNil(noImage)
        XCTAssertNotNil(textOnly)
    }
}
