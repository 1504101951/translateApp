# 截图与实时翻译规划

Codex-Thread: 01a0db40-8de9-76f2-91d6-674a344135ee

当前平台为 macOS 26+。区域框选、预览、PNG复制与保存、录屏、GIF导出和手动滚动长截图均有实现；实机效果由用户验收，其他能力状态以各自工单为准。总体规格见 [#1](https://github.com/1504101951/translateApp/issues/1)。

## 原地编辑设计

固定目录位于设置，截图后原地标注与独立贴图的核心路径已实现；设计方案见 [截图原地编辑与贴图设计](screenshot-editor-design.md)，其中跨屏选区策略等仍待确认。

## 术语

1. **采集工具**：直接作用于屏幕上下文的区域截图、录屏和滚动长截图；录屏和滚动长截图归入截图编辑工具栏的“截图”工具组，复用当前选区，是操作入口而非设置页面。
2. **框选**：采集前的选区编辑；长截图入口立即锁定并开始。
3. **活动采集**：录制与长截图的实时选区遮罩及全局悬浮三按钮；暂停／开始可切换，结束交付结果，放弃单击立即执行，清理会话临时资源并保留已保存文件。
4. **长截图固定区域**：自动识别顶部导航与底部悬浮内容，按实际正文位移处理；选区在长截图期间不可调整，边框和阴影不进入输出，被遮挡内容不推测或补全。

## 首版截图与后续顺序

1. 基础截图：系统区域框选、取消、预览、独立快捷键、PNG 复制、分类日期保存、固定根目录、自动命名、复制并保存、Finder 定位。已实现。
2. OCR 与文字入口：从已捕获位图提取本地文字，提供直接复制文字和显式翻译。#20 已完成 OCR 文字复制与翻译；OCR 不阻塞基础截图的交付。
3. 截图置顶、编辑、历史及区域实时OCR翻译按各自工单推进。录屏、GIF与手动滚动长截图的当前范围见下文。

捕获后的操作预览是普通窗口，不具有贴图的置顶能力。复制/保存只消费当前位图，不经过 TranslationRequest，不隐式请求网络服务。

## 录屏、GIF与长截图

1. #21从截图编辑工具栏“截图→录制”的第三行选择区域、窗口、全屏目标，窗口目标在第四行选择应用，使用实时选区阴影与右下角悬浮四气泡控制。暂停结束当前MP4段，开始追加新段，结束合并为连续30fps无声H264视频并验证解码；放弃单击立即执行。
2. #23使用已完成的录制，使用完整视频时长及截图设置中的帧率和最大宽度；逐帧编码，最多1800帧，取消不改变源文件，不发布不完整GIF。
3. #28框选后点击“滚动长截图”立即开始，选区持续可见、固定且不可编辑。全局悬浮按钮为暂停／开始、结束、放弃；暂停保留拼接器，恢复继续追加，放弃单击立即执行。自动识别顶部与底部固定内容，可信正文连续拼接。结束或无法可靠拼接时打开“长截图结果”窗口，可滚动查看已确认长图，并保存、复制或放弃。
4. 采集使用本地资源；结果窗口关闭与放弃使用同一立即清理路径，退出应用仍先确认；清理仅作用于本会话临时目录，已经保存的文件保留。自动化验证与用户界面验收分开记录，智能体不关闭工单。

## 已确认工单

| 功能 | 工单 | 依赖 |
| --- | --- | --- |
| 区域截屏、本地 OCR、直接复制文字与翻译 | [#20](https://github.com/1504101951/translateApp/issues/20) | 无 |
| 屏幕、窗口与区域录制，保存本地视频 | [#21](https://github.com/1504101951/translateApp/issues/21) | 无 |
| 截图置顶预览，切换 App 后保留 | [#22](https://github.com/1504101951/translateApp/issues/22) | #20 的捕获能力 |
| 录制视频导出 GIF | [#23](https://github.com/1504101951/translateApp/issues/23) | #21 |
| 框选区域实时文字翻译 | [#24](https://github.com/1504101951/translateApp/issues/24) | #20，不依赖 #21 |
| 截图保存、自动命名、固定目录与复制并保存 | [#25](https://github.com/1504101951/translateApp/issues/25) | #20、#26 的位图复制能力 |
| 截图复制到系统剪贴板 | [#26](https://github.com/1504101951/translateApp/issues/26) | #20 |
| 裁剪、标注、隐私遮挡与撤销/重做 | [#27](https://github.com/1504101951/translateApp/issues/27) | #20、#25、#26 |
| 滚动长截图 | [#28](https://github.com/1504101951/translateApp/issues/28) | #20；结果接入保存、复制与编辑 |
| 本地截图历史 | [#29](https://github.com/1504101951/translateApp/issues/29) | #20、#25、#26 |

选区文本、截图 OCR 和实时区域 OCR 在入口处提取文字、保留段落并形成统一的 `TranslationRequest`，复用当前翻译层。入口负责采集权限、区域和生命周期，翻译层负责语言方向、提供方协议与结果；录屏、截图保存等媒体动作不隐式调用翻译。仅在实施对应工单时接入入口，不预建空模块。

## 实时文字翻译的行为边界

[#24](https://github.com/1504101951/translateApp/issues/24) 集中维护实时翻译会话的功能、调度、界面边界与验收：用户指定区域，设备 OCR 持续识别，最新文字更新译文；切换 App 后继续，默认不录制视频（同步录制见 #90）、不处理音频、不上传图像。

行为、调度初始值和验收以 #24 为准。译文由原生盖层覆盖在来源画面的原文字位置，控制沿用采集悬浮条；界面效果仍由用户验收。

## 截图扩展工单

以下功能来自开源工具调研，均已登记为待澄清工单，实施顺序见 [#1](https://github.com/1504101951/translateApp/issues/1) 的登记评论。参考项目的平台支持不代表本项目已实现或可直接复用其代码。

| 功能 | 用途 | 参考 | 工单 |
| --- | --- | --- | --- |
| 延时截屏、重复截取上次区域、指定显示器、是否包含鼠标 | 展开菜单与悬停提示、处理固定位置内容、多屏截图 | Flameshot、ksnip | [#105](https://github.com/1504101951/translateApp/issues/105) |
| 键盘微调框选区域、固定比例 | 精确控制边界和尺寸 | Flameshot | [#106](https://github.com/1504101951/translateApp/issues/106) |
| 步骤编号、荧光笔 | 制作教程和反馈截图，扩展 #27 标注工具 | ShareX、Flameshot | [#107](https://github.com/1504101951/translateApp/issues/107) |
| 屏幕二维码与条码识别 | 从画面提取链接或文本 | ShareX | [#108](https://github.com/1504101951/translateApp/issues/108) |
| 图片拼接、拆分与比较 | 合并多张截图、查看差异 | ShareX | [#109](https://github.com/1504101951/translateApp/issues/109) |
| 录制裁剪、点击高亮、APNG/WebM 导出 | 制作演示与问题复现素材，扩展 #21、#23 | Kap | [#110](https://github.com/1504101951/translateApp/issues/110) |
| 取色器、屏幕标尺、上传分享与自动工作流 | 设计辅助与文件分享，偏离文字翻译主线 | ShareX | [#111](https://github.com/1504101951/translateApp/issues/111) |

## 开源参考

- [ShareX](https://github.com/ShareX/ShareX)：Windows，GPL-3.0；功能依据官方 README。
- [Flameshot](https://github.com/flameshot-org/flameshot)：Linux、Windows、macOS，GPL-3.0；功能依据官方 README 的工具、快捷键和 CLI 说明。
- [ksnip](https://github.com/ksnip/ksnip)：Linux、Windows、macOS，GPL-3.0；具体捕获方式有平台差异，依据官方 README。
- [NormCap](https://dynobo.github.io/normcap/) / [源码](https://github.com/dynobo/normcap)：Linux、Windows、macOS，GPLv3；官方描述为 OCR 文字捕获工具，不据此承诺表格或多栏版式还原。
- [Kap](https://getkap.co/) / [源码](https://github.com/wulkano/Kap)：macOS 12+，MIT；官网与 README 列出区域录制、暂停、裁剪、点击高亮及导出格式。
- [MORT](https://github.com/kmonkeyhead/MORT)：Windows 10+，MIT；官方 README 明确列出实时翻译、多 OCR 区域和框选识别区域的操作，可参考区域实时文字翻译的交互。
