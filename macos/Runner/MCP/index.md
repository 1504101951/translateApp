# macos/Runner/MCP目录索引

MCP 截图接口的 JSON-RPC 协议、本地 socket 传输及 App 侧请求处理。

1. [MCPProtocol.swift](MCPProtocol.swift)：helper 与 App 共用的请求结果类型、MCP JSON-RPC 最小子集转换及 helper 的 stdio 会话。
2. [MCPSocket.swift](MCPSocket.swift)：helper 与 App 共用的 0600 Unix domain socket 单行 JSON 收发。
3. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
