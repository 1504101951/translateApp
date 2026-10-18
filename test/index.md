# test目录索引

Dart业务逻辑和Flutter界面行为回归测试。

1. [api_translation_provider_test.dart](api_translation_provider_test.dart)：验证官方翻译服务和模型适配的请求与响应契约。
2. [flutter_test_config.dart](flutter_test_config.dart)：统一初始化Flutter测试所需的运行配置。
3. [glass_appearance_test.dart](glass_appearance_test.dart)：验证玻璃主题和跨窗口外观设置。
4. [history_app_test.dart](history_app_test.dart)：验证历史卡片内容、分页与记录设置交互。
5. [history_channel_test.dart](history_channel_test.dart)：验证截图翻译与设置提交等待期间，历史分页和记录开关仍可独立完成。
6. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
7. [language_direction_test.dart](language_direction_test.dart)：验证主要语言、次要语言及未知检测结果的翻译方向。
8. [macos_bridge_event_test.dart](macos_bridge_event_test.dart)：验证原生选区事件的解析与字段传递。
9. [native_glass_controls_test.dart](native_glass_controls_test.dart)：验证共享玻璃控件的输入、布局与命中行为。
10. [paragraph_translation_test.dart](paragraph_translation_test.dart)：验证段落结构、翻译配对与失败边界。
11. [permission_wizard_app_test.dart](permission_wizard_app_test.dart)：验证权限向导显示、状态刷新与完成行为。
12. [permission_wizard_test.dart](permission_wizard_test.dart)：验证两项权限齐备后的进入条件。
13. [screenshot_app_test.dart](screenshot_app_test.dart)：验证截图编辑、标注与导出行为。
14. [screenshot_controls_test.dart](screenshot_controls_test.dart)：验证截图工具快捷键、选择、拉伸及确认行为。
15. [screenshot_toolbar_preferences_test.dart](screenshot_toolbar_preferences_test.dart)：验证工具排序、显隐、快捷键录制和配置校验。
16. [screenshot_translation_test.dart](screenshot_translation_test.dart)：验证截图文本翻译、捕获失效与历史写入。
17. [selection_history_test.dart](selection_history_test.dart)：验证选区翻译成功、失败和取消时的历史记录边界。
18. [selection_session_test.dart](selection_session_test.dart)：验证选区翻译生命周期、取消和状态变化。
19. [settings_app_test.dart](settings_app_test.dart)：验证设置页面交互、服务显示和配置更新。
20. [settings_autosave_test.dart](settings_autosave_test.dart)：验证后台自动保存的串行、冲突和失败处理。
21. [settings_spec_test.dart](settings_spec_test.dart)：验证设置界面是否符合数值、密度与交互规格。
22. [settings_test.dart](settings_test.dart)：验证设置数据往返与配置校验。
23. [translation_history_test.dart](translation_history_test.dart)：验证翻译历史存储、分页及记录开关。
24. [translation_overlay_test.dart](translation_overlay_test.dart)：验证翻译按钮、双语结果与失败界面行为。
25. [translation_resume_test.dart](translation_resume_test.dart)：验证分片失败恢复、进度保留及取消边界。
26. [unofficial_google_provider_test.dart](unofficial_google_provider_test.dart)：验证零配置Google翻译的解析与失败处理。

27. [drawing_style_test.dart](drawing_style_test.dart)：验证马赛克像素、样式隔离、撤销及调色盘与粗细的提交边界。
28. [capture_app_test.dart](capture_app_test.dart)：验证录制目标与应用图标动态行、安全区域布局和选择状态、长截图直启选区、四气泡暂停恢复与立即放弃、长图等比预览和原尺寸导出、视频内容区工具布局、直接GIF导出及工具栏外的一秒响应。
29. [settings_controller_test.dart](settings_controller_test.dart)：验证配置快照隔离、设置提交顺序、真实文件存储失败恢复和过期修订拒绝。
30. [live_region_session_test.dart](live_region_session_test.dart)：验证实时翻译的段落块缓存、批次调度、三类失败、暂停恢复和迟到事件。
31. [live_block_cache_test.dart](live_block_cache_test.dart)：验证段落块缓存的预算淘汰、最近使用顺序和失败记录。
32. [numbered_batch_test.dart](numbered_batch_test.dart)：验证批次编号文本与流式输出按编号归属的边界。
33. [mcp_settings_page_test.dart](mcp_settings_page_test.dart)：验证设置 MCP 页的导航分段、开关自动保存、helper 路径与配置复制、平台状态与按钮可用性、安装失败原文及删除二次确认。
34. [mcp_platforms_test.dart](mcp_platforms_test.dart)：用模拟 CLI 与临时主目录验证接入平台的检测、安装、重复安装、路径变化、删除、配置备份与隔离属性清除。
35. [markdown_view_test.dart](markdown_view_test.dart)：验证识别结果 Markdown 的块拆分、表格分隔行与转义竖线、块间距及宽表格横向滚动。
