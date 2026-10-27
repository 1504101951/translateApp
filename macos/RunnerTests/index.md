# macos/RunnerTests目录索引

原生平台桥、窗口、输入与截图存储回归测试。

1. [RunnerTests.swift](RunnerTests.swift)：验证原生权限、五个附属窗口入口确认与失败/取消/重开生命周期、窗口、事件路由（含附属窗口请求本地优先、未实现再转主引擎）、存储与平台桥行为。
2. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
3. [CaptureMediaTests.swift](CaptureMediaTests.swift)：验证截图存储的分类日期（含 APNG、WebM 分类）、重名保护、取消发布与路径错误，屏幕采集身份边界、采集面板首击与焦点、系统视频结果窗的层级和内容边界、系统关闭立即结束会话、实时录制与应用窗口并集遮罩、应用图标栅格化、长图固定区域与接缝像素、保存后重复放弃与过期交付、应用联合画布像素、H264解码、零起点递增时间戳及快停/延迟/无帧录制到GIF/APNG的真实解码、GIF时序及取消清理、APNG按裁剪区间导出与循环、裁剪后MP4时长与内容、WebM按裁剪区间保留源帧时间与取消清理、WebM写出器的Cluster切分、索引回填与丢帧报错、长截图自动滚动步进的停稳、校准、到底与退回判定。
4. [MCPTests.swift](MCPTests.swift)：验证 MCP JSON-RPC 编解码、保序参数 schema、参数与结果转换、按 token 上限的图片缩放、capture_rect 坐标换算、列表表格文本、OCR Markdown 组织与位置行、取消、App 未运行与开关关闭时的输出。
