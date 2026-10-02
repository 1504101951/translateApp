# macos/Runner目录索引

macOS应用生命周期、系统能力与窗口控制器。

1. [Assets.xcassets/](Assets.xcassets/index.md)：应用图标等Xcode资源目录。
2. [Base.lproj/](Base.lproj/index.md)：macOS基础语言的窗口和菜单界面资源。
3. [Common/](Common/index.md)：Swift平台协议常量与共享工具。
4. [Configs/](Configs/index.md)：应用标识、编译模式与警告配置。
5. [AccessibilitySelection.swift](AccessibilitySelection.swift)：通过辅助功能及显式复制读取来源应用选中文字。
6. [AppDelegate.swift](AppDelegate.swift)：初始化菜单栏应用、平台桥和辅助窗口并管理生命周期。
7. [AuxiliaryWindowController.swift](AuxiliaryWindowController.swift)：管理历史和权限向导等独立Flutter窗口。
8. [DebugProfile.entitlements](DebugProfile.entitlements)：声明调试与性能分析构建所需的系统授权能力。
9. [Info.plist](Info.plist)：声明应用元数据、入口和系统权限用途说明。
10. [MacPlatformBridge.swift](MacPlatformBridge.swift)：处理Flutter平台请求并发送选区与系统事件。
11. [MainFlutterWindow.swift](MainFlutterWindow.swift)：隐藏XIB主窗口并安装菜单栏入口。
12. [NativeGlass.swift](NativeGlass.swift)：注册原生玻璃平台视图并同步窗口材料与外观。
13. [OverlayPanel.swift](OverlayPanel.swift)：管理不抢来源焦点的翻译浮层及其定位和拖动。
14. [PinOverlayController.swift](PinOverlayController.swift)：管理独立置顶贴图的选择、拖动和关闭。
15. [Release.entitlements](Release.entitlements)：声明发布构建所需的系统授权能力。
16. [ScreenCaptureService.swift](ScreenCaptureService.swift)：通过系统屏幕捕获能力获取图像并执行设备OCR。
17. [ScreenshotStorage.swift](ScreenshotStorage.swift)：统一采集根目录、分类日期路径与PNG/MP4/GIF防覆盖写入。
18. [ScreenshotWindowController.swift](ScreenshotWindowController.swift)：管理截图窗口、捕获会话、键盘路由及原生导出操作。
19. [SelectionGestureDetector.swift](SelectionGestureDetector.swift)：识别鼠标和键盘产生的文本选区手势。
20. [SelectionMonitor.swift](SelectionMonitor.swift)：监听全局选区变化并协调采集、热键和会话失效。
21. [SettingsWindowController.swift](SettingsWindowController.swift)：管理设置Flutter窗口、配置转发和快捷键录制。
22. [StatusBarController.swift](StatusBarController.swift)：管理菜单栏入口、菜单状态和用户操作回调。
23. [TextSelectionContext.swift](TextSelectionContext.swift)：判断辅助功能对象是否属于允许翻译的文本上下文。
24. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
25. [CaptureWindowController.swift](CaptureWindowController.swift)：协调采集选区、实时阴影、统一采集悬浮条、媒体结果和系统保存面板。
26. [MediaCaptureService.swift](MediaCaptureService.swift)：管理屏幕流、录制会话、手动滚动采集及临时资源生命周期。
27. [GIFExporter.swift](GIFExporter.swift)：按设置逐帧解码完整MP4并生成有界、等比缩小的GIF。
28. [ScrollStitcher.swift](ScrollStitcher.swift)：识别垂直位移和上下固定带并生成保持原始像素的长图。
29. [ApplicationRecorder.swift](ApplicationRecorder.swift)：将所选应用在全部显示器上的可见窗口合成为固定黑底画布并编码视频。
