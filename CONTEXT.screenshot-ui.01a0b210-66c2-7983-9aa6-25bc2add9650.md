# Screenshot UI Context

Codex-Thread: 01a0b210-66c2-7983-9aa6-25bc2add9650

本文件记录工单 #53、#54、#55 的术语、界面关系与验收边界。

## 用户确认的界面关系

1. **工具栏避让**：工具栏完整位于当前屏幕内，优先贴近选区边缘的外侧空白；外侧空间不足时，允许放到选区内部靠边位置。上、下、左、右根据可用空间选择。画布保持原有位置和显示比例，不为工具栏缩小或移动截图。工具栏不进入复制或保存的图片。
2. **全应用液态玻璃风格**：设置、翻译浮窗、截图工具栏、翻译历史窗口和权限向导采用统一的 Liquid Glass 视觉语言。截图图片、原文和译文等内容本身不附加玻璃效果。
3. **截图确认与文字确认**：非文字输入状态下，回车或小键盘回车表示复制编辑后的截图并结束截图；文字输入状态下，回车只确认文字，Shift+回车表示换行。复制失败不关闭编辑内容。
4. **复制成功反馈**：单击复制图片或复制文字后，在工具栏上方显示独立浮层，一秒后消失，连续成功复制重新计时；屏幕边缘自动避让。提示不拦截点击、不进入导出，关闭或替换截图立即清除。错误提示保持可见。对应工单 #56。

## 用户实机反馈

1. **截图确认路由**：原生截图键盘监听向截图 Flutter 引擎发送带 captureId 的确认事件；Dart 依据文字编辑、输入法组词和导出状态处理确认，拒绝过期捕获。
2. 原生端到端测试覆盖主键盘 Return、小键盘 Enter、真实 Flutter 引擎、剪贴板 PNG 像素和窗口关闭；用户实机的高概率无响应场景仍须作为验收重点，不能只使用 Widget 键盘测试作为证据。
3. 用户补充反馈 Esc 无响应。当前源码的原生冷启动、失焦与引擎复用 Esc 回归通过；反馈发生时标准安装目录仍是旧签名版本，不能据此判断新包同样失效。实际安装版本和实机复验需要一并确认。

## 平台与材料方案的讨论状态

1. 工单 #55 的实施目标为 macOS 26+，工程与交付物使用该部署下限。
2. 原生材料由 `NSGlassEffectView` 提供；各 Flutter 引擎通过共享的 `NativeGlassFactory` 注册平台视图，界面与业务继续由 Flutter 承担。
3. `liquid_glass_widgets` 是 Flutter shader 组件库。其配套 skill 目录本次核查仅包含 `SKILL.md`，没有执行脚本。skill 提供使用规范，运行时组件源码由 package 提供，两者职责不同。

## 调研来源

1. [Apple NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
2. [real_liquid_glass](https://pub.dev/packages/real_liquid_glass)
3. [liquid_glass_widgets 配套 skill](https://github.com/sdegenaar/liquid_glass_widgets/tree/main/skills/liquid-glass-widgets)
