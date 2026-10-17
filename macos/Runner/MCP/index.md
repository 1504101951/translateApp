# macos/Runner/MCP目录索引

MCP 截图接口的 JSON-RPC 协议、本地 socket 传输及 App 侧请求处理。

1. [MCPCaptureServer.swift](MCPCaptureServer.swift)：App 侧 socket 服务，校验 MCP 开关、执行工具并在 helper 断开时取消请求。
2. [MCPImageOutput.swift](MCPImageOutput.swift)：把截图缩放到长边 1568 px、换算 capture_rect 坐标并生成带位置的 OCR 段落。
3. [MCPProtocol.swift](MCPProtocol.swift)：helper 与 App 共用的工具请求结果类型、MCP JSON-RPC 最小子集转换及 helper 的 stdio 会话。
4. [MCPSocket.swift](MCPSocket.swift)：helper 与 App 共用的 0600 Unix domain socket 单行 JSON 收发。
5. [MCPToolRunner.swift](MCPToolRunner.swift)：在 App 进程列出显示器与窗口，并按显示器、矩形或窗口截图。
6. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
