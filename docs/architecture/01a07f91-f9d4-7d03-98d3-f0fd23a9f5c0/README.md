# TranslateApp 项目架构

1. `translate-app.architecture.html` 是可直接打开的独立架构图；`translate-app.architecture.json` 是生成源规格。图中 18 处源码引用绑定提交 `05b5cd8b9ef49e06ace50d11a74c89af4a14d01a`。
2. 主链路为 macOS 原生选区捕获、Dart 会话编排、翻译 Provider 和外部 HTTP API。图例中的“后端”表示本机业务与系统组件，不代表独立服务端进程。
3. 原生层聚合 `AppDelegate`、`SelectionMonitor`、`AccessibilitySelection`、`MacPlatformBridge` 与 `OverlayPanelController`，以突出 Dart/Swift 职责边界。`translateapp/macos/events` 传入选区事件；Dart 经 `translateapp/macos` 回传浮层控制、语言检测和配置命令。图中主箭头表示请求方向，结果由 Provider 流返回会话。
4. 设置窗口经 `translateapp/settings` 和原生桥转交主 Dart 请求队列；主 Dart 调用 `applySettings` 完成原生持久化和系统配置。普通配置保存在 UserDefaults，服务凭据保存在 Keychain。
5. 翻译浮层由 Flutter 渲染、非激活 NSPanel 承载。`sessionId`、`generation` 与订阅取消共同阻止旧会话结果覆盖当前状态。
6. 截图窗口使用独立 Flutter 引擎、`translateapp/screenshot` 与 `captureId`。系统 `screencapture` 生成 PNG，经内存与临时文件流转，提供预览、复制和保存。
7. `receipt.json` 记录规格与 HTML 的 SHA-256、字节数及独立验收状态。`translate-app.architecture.visual-check.json` 保存四种桌面尺寸的浏览器测量；同名前缀 PNG 与 HTML 联系表保存明暗主题截图。
8. 校验范围包括 9 项 showcase 检查、源码引用、桌面无溢出、文字可读性及静态截图目视检查。交互操作、导出和真实 macOS 翻译业务未执行运行测试。
