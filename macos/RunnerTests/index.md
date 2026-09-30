# macos/RunnerTests目录索引

原生平台桥、窗口、输入与截图存储回归测试。

1. [RunnerTests.swift](RunnerTests.swift)：验证原生权限、窗口、事件路由、存储与平台桥行为。
2. [ScreenshotStorageCheck.swift](ScreenshotStorageCheck.swift)：在临时目录验证截图重名保存、旧文件保留和非法路径拒绝。
3. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
4. [CaptureMediaTests.swift](CaptureMediaTests.swift)：验证屏幕采集身份边界、采集面板首击与焦点、系统视频结果窗的层级和内容边界、系统关闭的保留与放弃、保存面板可见和取消、独立放弃确认窗的屏幕边界与保留按键、实时录制与应用窗口并集遮罩、应用图标栅格化、长图固定区域动画与快速滚动接缝像素、应用联合画布像素与H264解码、GIF时序及取消清理。
