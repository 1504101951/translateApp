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
        /// 原始行，用于检查参数顺序等序列化细节。
        private(set) var raw: [String] = []
        var expectation: XCTestExpectation?
        var expectedCount = 0

        /// 参数 data：会话写出的一行 JSON。
        func append(_ data: Data) {
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            lock.lock()
            messages.append(object)
            raw.append(String(decoding: data, as: UTF8.self))
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
        await exchangeOutput(lines, count: count).all
    }

    /// 作用：同 exchange，返回收集器以便读取原始行。参数 lines、count：同 exchange。返回：输出收集器。
    private func exchangeOutput(_ lines: [String], count: Int) async -> Output {
        let output = Output()
        let done = expectation(description: "收到 \(count) 条输出")
        output.expectation = done
        output.expectedCount = count
        let session = MCPHelperSession(socketPath: socketPath, version: "test") { output.append($0) }
        lines.forEach { session.receive(Data($0.utf8)) }
        await fulfillment(of: [done], timeout: 10)
        return output
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


    /// tools/list 声明五个工具与英文说明；截图工具参数按声明顺序输出，output 默认 image，约束由 schema 关键字表达。
    /// 边界依据：#96 决策 6 与「工具」参数表。
    func testToolsListDeclaresOrderedEnglishSchemas() async throws {
        let output = await exchangeOutput([#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#], count: 1)
        let tools = (output.all[0]["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.map { $0["name"] as? String },
                       ["list_displays", "list_windows", "capture_screen", "capture_rect", "capture_window"])
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as! String, $0) })
        XCTAssertTrue((byName["list_displays"]!["description"] as! String).contains("Use when you need screen information"))
        XCTAssertTrue((byName["list_windows"]!["description"] as! String).contains("Use when you need screen information"))

        let rect = byName["capture_rect"]!["inputSchema"] as! [String: Any]
        XCTAssertEqual(rect["required"] as? [String], ["display_index", "x", "y", "width", "height"])
        XCTAssertEqual(rect["additionalProperties"] as? Bool, false)
        let properties = rect["properties"] as! [String: [String: Any]]
        XCTAssertEqual(properties["output"]?["default"] as? String, "image")
        XCTAssertEqual(properties["output"]?["enum"] as? [String], ["image", "text", "both"])
        XCTAssertEqual(properties["detail"]?["enum"] as? [String], ["low", "standard"])
        XCTAssertEqual(properties["include_positions"]?["default"] as? Bool, false)
        XCTAssertEqual(properties["width"]?["minimum"] as? Int, 1)
        XCTAssertNil(properties["width"]?["description"])

        // 参数在原始 JSON 中按声明顺序出现。
        let raw = output.raw[0]
        let section = raw[raw.range(of: #""name":"capture_rect""#)!.lowerBound...]
        let order = ["display_index", "x", "y", "width", "height", "reference_detail", "output", "detail", "include_positions"]
        let positions = order.map { section.range(of: "\"\($0)\":{")!.lowerBound }
        XCTAssertEqual(positions, positions.sorted())
    }

    /// 参数转换：缺省值、必填、取值范围与未声明参数。
    /// 边界依据：display_index 与 x、y 下界为 0，width、height、window_id 下界为 1；布尔与小数不得被当作整数；
    /// window_id 上界为 CGWindowID（UInt32）最大值；schema 声明 additionalProperties: false。
    func testToolRequestConversionAndArgumentBounds() throws {
        let defaults = MCPCaptureOptions(output: .image, detail: .standard, includePositions: false)
        XCTAssertEqual(try MCPProtocol.toolRequest(params: ["name": "capture_screen"]), .captureScreen(displayIndex: 0, options: defaults))
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": [
                "display_index": 1, "x": 0, "y": 0, "width": 1, "height": 1,
                "reference_detail": "low", "output": "text", "detail": "low", "include_positions": true,
            ]]),
            .captureRect(
                displayIndex: 1, x: 0, y: 0, width: 1, height: 1, referenceDetail: .low,
                options: MCPCaptureOptions(output: .text, detail: .low, includePositions: true)
            )
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "capture_window", "arguments": ["window_id": Int(UInt32.max)]]),
            .captureWindow(windowID: UInt32.max, options: defaults)
        )
        let invalid: [([String: Any], String)] = [
            (["display_index": -1], "display_index must be an integer ≥ 0"),
            (["display_index": true], "display_index must be an integer ≥ 0"),
            (["display_index": 1.5], "display_index must be an integer ≥ 0"),
            (["output": "pdf"], "output must be one of image, text, both"),
            (["detail": "high"], "detail must be one of low, standard"),
            (["include_positions": 1], "include_positions must be a boolean"),
            (["display": 0], "Unknown argument: display"),
        ]
        for (arguments, message) in invalid {
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_screen", "arguments": arguments])) {
                XCTAssertEqual($0 as? MCPRequestError, .invalidArgument(message))
            }
        }
        let rectBase: [String: Any] = ["display_index": 0, "x": 0, "y": 0, "width": 10, "height": 10]
        for (key, value) in [("width", 0), ("height", 0), ("x", -1)] as [(String, Any)] {
            var arguments = rectBase
            arguments[key] = value
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": arguments]), key)
        }
        var missing = rectBase
        missing["height"] = nil
        XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": missing])) {
            XCTAssertEqual($0 as? MCPRequestError, .invalidArgument("Missing required argument: height"))
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
        XCTAssertEqual(toolResult(messages[1]).content.first?["text"] as? String, "output must be one of image, text, both")
    }

    /// 没有 socket 文件与残留 socket 文件都返回「TranslateApp is not running.」。
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

    /// 开关关闭时 App 返回开关关闭错误，不执行工具。
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

    /// 请求经真实 socket 到达 App；清单为制表符分隔的表格文本，截图结果为图片在前、Markdown 在后。
    /// 边界依据：标题中的制表符与换行会打乱表格，须替换为空格。
    @MainActor
    func testRequestsReachAppAndRepliesBecomeContent() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        var received: [MCPToolRequest] = []
        startServer { request in
            received.append(request)
            switch request {
            case .listDisplays:
                return .displays([MCPDisplayInfo(displayIndex: 0, standardWidth: 1372, standardHeight: 891, lowWidth: 784, lowHeight: 509)])
            case .listWindows:
                return .windows([MCPWindowInfo(windowID: 42, displayIndex: 0, x: 0, y: 17, width: 686, height: 400, app: "Safari", title: "A\tB\nC")])
            default:
                return .image(png: png, markdown: "# Title")
            }
        }
        let displays = await exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#], count: 1)
        let windows = await exchange([#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_windows"}}"#], count: 1)
        let capture = await exchange([
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capture_rect","arguments":{"display_index":0,"x":10,"y":20,"width":30,"height":40,"output":"both"}}}"#,
        ], count: 1)

        XCTAssertEqual(received.last, .captureRect(
            displayIndex: 0, x: 10, y: 20, width: 30, height: 40, referenceDetail: .standard,
            options: MCPCaptureOptions(output: .both, detail: .standard, includePositions: false)
        ))
        XCTAssertEqual(
            toolResult(displays[0]).content.first?["text"] as? String,
            "display_index\tstandard_image_width\tstandard_image_height\tlow_image_width\tlow_image_height\n0\t1372\t891\t784\t509"
        )
        XCTAssertEqual(
            toolResult(windows[0]).content.first?["text"] as? String,
            "window_id\tdisplay_index\tx\ty\twidth\theight\tapp\ttitle\n42\t0\t0\t17\t686\t400\tSafari\tA B C"
        )
        let result = toolResult(capture[0])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 2)
        XCTAssertEqual(result.content[0]["type"] as? String, "image")
        XCTAssertEqual(result.content[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(result.content[0]["data"] as? String, png.base64EncodedString())
        XCTAssertEqual(result.content[1]["text"] as? String, "# Title")
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

    /// 作用：计算 Claude 视觉 token 数。参数 size：像素尺寸。返回：⌈宽/28⌉×⌈高/28⌉。
    private func tokens(_ size: (width: Int, height: Int)) -> Int {
        Int((Double(size.width) / 28).rounded(.up)) * Int((Double(size.height) / 28).rounded(.up))
    }

    /// 返回图尺寸同时满足 token 上限与 1568 长边，且不放大；缩放接近上限而不过度缩小。
    /// 边界依据：#96 决策 3；3024×1964 为 14 英寸 MacBook Pro 默认缩放的物理像素，按长边缩到 1568×1018 会有 2072 token。
    func testFittedSizeRespectsTokenBudgetAndLongEdge() {
        for detail in MCPDetail.allCases {
            for (width, height) in [(3024, 1964), (5120, 2880), (1000, 3136), (1568, 10)] {
                let size = MCPImageOutput.fitted(width: width, height: height, detail: detail)
                XCTAssertLessThanOrEqual(tokens(size), detail.tokenBudget, "\(width)×\(height) \(detail)")
                XCTAssertLessThanOrEqual(max(size.width, size.height), AppConstants.mcpImageMaxEdge)
                XCTAssertEqual(Double(size.width) / Double(size.height), Double(width) / Double(height), accuracy: 0.02 * Double(width) / Double(height))
            }
        }
        let retina = MCPImageOutput.fitted(width: 3024, height: 1964, detail: .standard)
        XCTAssertGreaterThan(tokens(retina), Int(Double(MCPDetail.standard.tokenBudget) * 0.95))
        let small = MCPImageOutput.fitted(width: 800, height: 600, detail: .standard)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 600)
    }

    /// capture_rect 坐标按参考清晰度的输出图换算回原始像素并向外取整；超出参考图或宽高为 0 时拒绝。
    /// 边界依据：整张参考图必须换算为整张原图；右下边缘多 1 像素即越界；low 与 standard 参考图尺寸不同。
    func testSourceRectMapsReferenceCoordinatesToSourcePixels() {
        for detail in MCPDetail.allCases {
            let reference = MCPImageOutput.fitted(width: 3024, height: 1964, detail: detail)
            XCTAssertEqual(
                MCPImageOutput.sourceRect(
                    x: 0, y: 0, width: reference.width, height: reference.height, detail: detail,
                    sourceWidth: 3024, sourceHeight: 1964
                ),
                CGRect(x: 0, y: 0, width: 3024, height: 1964)
            )
            XCTAssertNil(MCPImageOutput.sourceRect(
                x: 1, y: 0, width: reference.width, height: 1, detail: detail, sourceWidth: 3024, sourceHeight: 1964
            ))
        }
        let standard = MCPImageOutput.fitted(width: 3024, height: 1964, detail: .standard)
        let rect = MCPImageOutput.sourceRect(x: 100, y: 100, width: 10, height: 10, detail: .standard, sourceWidth: 3024, sourceHeight: 1964)!
        XCTAssertEqual(rect.minX, (100 * 3024 / Double(standard.width)).rounded(.down))
        XCTAssertEqual(rect.maxX, (110 * 3024 / Double(standard.width)).rounded(.up))
        XCTAssertNil(MCPImageOutput.sourceRect(x: 0, y: 0, width: 0, height: 5, detail: .standard, sourceWidth: 3024, sourceHeight: 1964))
        // 原图未超限时尺寸不变，坐标原样对应。
        XCTAssertEqual(
            MCPImageOutput.sourceRect(x: 5, y: 6, width: 7, height: 8, detail: .standard, sourceWidth: 800, sourceHeight: 600),
            CGRect(x: 5, y: 6, width: 7, height: 8)
        )
    }

    /// OCR Markdown：标题、段落、列表、表格按阅读顺序输出；表格或列表内的段落与重复标题不重复；
    /// 合并单元格只写起始格；单元格 | 转义、换行替换为空格；段落内连续空白合并、空段落去除。
    func testMarkdownBlocksOrganizeDocumentStructure() {
        var layout = ScreenCaptureService.OCRLayout()
        layout.title = ("Report", CGRect(x: 10, y: 0, width: 200, height: 30))
        layout.paragraphs = [
            ("Report", CGRect(x: 10, y: 0, width: 200, height: 30)),
            ("Intro   text\n  second line ", CGRect(x: 10, y: 40, width: 300, height: 40)),
            ("   ", CGRect(x: 10, y: 90, width: 10, height: 10)),
            ("Name", CGRect(x: 20, y: 210, width: 40, height: 20)),
            ("first item", CGRect(x: 20, y: 110, width: 80, height: 20)),
        ]
        layout.lists = [(["first item", " second\nitem "], CGRect(x: 10, y: 100, width: 300, height: 60))]
        layout.tables = [([
            .init(row: 0, column: 0, text: "Name"),
            .init(row: 0, column: 1, text: "Value"),
            .init(row: 1, column: 0, text: "a|b"),
            .init(row: 1, column: 1, text: "line\nbreak"),
            .init(row: 2, column: 0, text: "merged"),
            .init(row: 2, column: 0, text: "merged"),
        ], CGRect(x: 10, y: 200, width: 300, height: 90))]

        let blocks = ScreenCaptureService.markdownBlocks(layout)
        XCTAssertEqual(blocks.map(\.markdown), [
            "# Report",
            "Intro text\nsecond line",
            "- first item\n- second item",
            "| Name | Value |\n| --- | --- |\n| a\\|b | line break |\n| merged |  |",
        ])
    }

    /// 返回文本：默认只有 Markdown 块；include_positions 时首行为返回图尺寸，每块前为换算后的像素位置；无块时为提示文本。
    func testMarkdownTextWithPositionsAndEmptyResult() {
        let blocks = [
            ScreenCaptureService.OCRBlock(markdown: "# T", rect: CGRect(x: 100, y: 40, width: 200, height: 20)),
            ScreenCaptureService.OCRBlock(markdown: "Body", rect: CGRect(x: 100, y: 80, width: 400, height: 60)),
        ]
        let size = (width: 1000, height: 500)
        XCTAssertEqual(MCPImageOutput.text(blocks, scaleX: 0.5, scaleY: 0.5, size: size, includePositions: false), "# T\n\nBody")
        XCTAssertEqual(
            MCPImageOutput.text(blocks, scaleX: 0.5, scaleY: 0.5, size: size, includePositions: true),
            "[image 1000×500]\n\n[50,20,100,10]\n# T\n\n[50,40,200,30]\nBody"
        )
        XCTAssertEqual(MCPImageOutput.text([], scaleX: 1, scaleY: 1, size: size, includePositions: true), AppConstants.mcpNoTextMessage)
    }

    /// 截图结果：PNG 按 token 上限缩放；OCR 在原图识别并以 Markdown 返回；output 控制返回内容。
    func testImageReplyScalesPngAndReturnsMarkdown() async throws {
        let png = try textImage(width: 3136, height: 400, text: "TranslateApp", x: 400, baseline: 140)
        let source = try MCPImageOutput.image(png)

        let both = MCPCaptureOptions(output: .both, detail: .standard, includePositions: false)
        guard case .image(let image, let markdown) = try await MCPImageOutput.reply(source, options: both) else {
            return XCTFail("应返回截图结果")
        }
        let returned = try MCPImageOutput.image(try XCTUnwrap(image))
        let expected = MCPImageOutput.fitted(width: 3136, height: 400, detail: .standard)
        XCTAssertEqual(returned.width, expected.width)
        XCTAssertEqual(returned.height, expected.height)
        XCTAssertTrue(try XCTUnwrap(markdown).contains("TranslateApp"), markdown ?? "")

        guard case .image(let imageOnly, let noText) = try await MCPImageOutput.reply(
            source, options: MCPCaptureOptions(output: .image, detail: .low, includePositions: false)
        ) else { return XCTFail("应返回截图结果") }
        XCTAssertLessThanOrEqual(tokens(try MCPImageOutput.image(try XCTUnwrap(imageOnly)).size), MCPDetail.low.tokenBudget)
        XCTAssertNil(noText)
        guard case .image(let noImage, let textOnly) = try await MCPImageOutput.reply(
            source, options: MCPCaptureOptions(output: .text, detail: .standard, includePositions: true)
        ) else { return XCTFail("应返回截图结果") }
        XCTAssertNil(noImage)
        XCTAssertTrue(try XCTUnwrap(textOnly).hasPrefix("[image \(expected.width)×\(expected.height)]"))
    }
}

private extension CGImage {
    /// 像素尺寸元组，便于计算 token。
    var size: (width: Int, height: Int) { (width, height) }
}
