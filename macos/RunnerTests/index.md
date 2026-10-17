# macos/RunnerTests目录索引

原生平台桥、窗口、输入与截图存储回归测试。

1. [RunnerTests.swift](RunnerTests.swift)：验证原生权限、窗口、事件路由、存储与平台桥行为。
2. [ScreenshotStorageCheck.swift](ScreenshotStorageCheck.swift)：在临时目录验证分类日期保存、媒体重名保护、旧文件保留及真实路径错误。
3. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
4. [CaptureMediaTests.swift](CaptureMediaTests.swift)：验证屏幕采集身份边界、采集面板首击与焦点、系统视频结果窗的层级和内容边界、系统关闭立即结束会话、实时录制与应用窗口并集遮罩、应用图标栅格化、长图固定区域与接缝像素、保存后重复放弃与过期交付、应用联合画布像素与H264解码、GIF时序及取消清理。
5. [MCPTests.swift](MCPTests.swift)：验证 MCP JSON-RPC 编解码、参数与结果转换、图片缩放与 capture_rect 坐标换算、OCR 坐标、取消、App 未运行与开关关闭时的输出。
