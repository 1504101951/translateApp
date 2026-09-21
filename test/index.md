# test目录索引

Dart业务逻辑和Flutter界面行为回归测试。

1. [api_translation_provider_test.dart](api_translation_provider_test.dart)：验证官方翻译服务和模型适配的请求与响应契约。
2. [flutter_test_config.dart](flutter_test_config.dart)：统一初始化Flutter测试所需的运行配置。
3. [glass_appearance_test.dart](glass_appearance_test.dart)：验证玻璃主题和跨窗口外观设置。
4. [history_app_test.dart](history_app_test.dart)：验证历史卡片内容、分页与记录设置交互。
5. [history_channel_test.dart](history_channel_test.dart)：验证独立历史窗口和主引擎之间的数据传递。
6. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
7. [language_direction_test.dart](language_direction_test.dart)：验证主要语言、次要语言及未知检测结果的翻译方向。
8. [macos_bridge_event_test.dart](macos_bridge_event_test.dart)：验证原生选区事件的解析与字段传递。
9. [native_glass_controls_test.dart](native_glass_controls_test.dart)：验证共享玻璃控件的输入、布局与命中行为。
10. [overlay_probe_test.dart](overlay_probe_test.dart)：验证浮层点击计数探针的交互反馈。
11. [paragraph_translation_test.dart](paragraph_translation_test.dart)：验证段落结构、翻译配对与失败边界。
12. [permission_wizard_app_test.dart](permission_wizard_app_test.dart)：验证权限向导显示、状态刷新与完成行为。
13. [permission_wizard_test.dart](permission_wizard_test.dart)：验证权限判断及向导进入条件。
14. [screenshot_app_test.dart](screenshot_app_test.dart)：验证截图编辑、标注与导出行为。
15. [screenshot_controls_test.dart](screenshot_controls_test.dart)：验证截图工具快捷键、选择、拉伸及确认行为。
16. [screenshot_toolbar_preferences_test.dart](screenshot_toolbar_preferences_test.dart)：验证工具排序、显隐、快捷键录制和配置校验。
17. [screenshot_translation_test.dart](screenshot_translation_test.dart)：验证截图文本翻译、捕获失效与历史写入。
18. [selection_history_test.dart](selection_history_test.dart)：验证选区翻译成功、失败和取消时的历史记录边界。
19. [selection_session_test.dart](selection_session_test.dart)：验证选区翻译生命周期、取消和状态变化。
20. [settings_app_test.dart](settings_app_test.dart)：验证设置页面交互、服务显示和配置更新。
21. [settings_autosave_test.dart](settings_autosave_test.dart)：验证后台自动保存的串行、冲突和失败处理。
22. [settings_spec_test.dart](settings_spec_test.dart)：验证设置界面是否符合数值、密度与交互规格。
23. [settings_test.dart](settings_test.dart)：验证设置数据往返与配置校验。
24. [translation_history_test.dart](translation_history_test.dart)：验证翻译历史存储、分页及记录开关。
25. [translation_overlay_test.dart](translation_overlay_test.dart)：验证翻译按钮、双语结果与失败界面行为。
26. [translation_resume_test.dart](translation_resume_test.dart)：验证分片失败恢复、进度保留及取消边界。
27. [unofficial_google_provider_test.dart](unofficial_google_provider_test.dart)：验证零配置Google翻译的解析与失败处理。
