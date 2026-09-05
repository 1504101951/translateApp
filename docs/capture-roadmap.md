# 截图与实时翻译规划

Codex-Thread: 01a06fe3-df48-7fb0-983b-443d579db93e

当前平台为 macOS 14+。以下能力均为待实现规划，当前安装版本不具备这些能力。总体规格见 [#1](https://github.com/1504101951/translateApp/issues/1)。

## 已确认工单

| 功能 | 工单 | 依赖 |
| --- | --- | --- |
| 区域截屏、本地 OCR 与文字翻译 | [#20](https://github.com/1504101951/translateApp/issues/20) | 无 |
| 屏幕、窗口与区域录制，保存本地视频 | [#21](https://github.com/1504101951/translateApp/issues/21) | 无 |
| 截图置顶预览，切换 App 后保留 | [#22](https://github.com/1504101951/translateApp/issues/22) | #20 的捕获能力 |
| 录制视频导出 GIF | [#23](https://github.com/1504101951/translateApp/issues/23) | #21 |
| 框选区域实时文字翻译 | [#24](https://github.com/1504101951/translateApp/issues/24) | #20，不依赖 #21 |
| 截图保存至本地文件 | [#25](https://github.com/1504101951/translateApp/issues/25) | #20 |
| 截图复制到系统剪贴板 | [#26](https://github.com/1504101951/translateApp/issues/26) | #20 |
| 裁剪、标注、隐私遮挡与撤销/重做 | [#27](https://github.com/1504101951/translateApp/issues/27) | #20、#25、#26 |

## 实时文字翻译的行为边界

用户框选屏幕区域并启动后，应用持续在设备上识别框内文字，内容变化时调用当前默认翻译服务，在独立、可移动且不抢焦点的窗口显示双语结果。语言方向、服务配置和 Keychain 凭据复用现有翻译能力。

- 相同文本去重，变化文本节流并限制并发；旧请求返回时不能覆盖较新的内容。
- 显示识别区域和运行状态，支持取消框选、重新框选、暂停、继续和停止。暂停期间不捕获、不请求；停止后释放资源。
- 排除自身区域边框与译文窗口，避免反复识别译文。区域没有文字时清空结果或明确标记旧结果，避免显示成当前译文。
- 区域会话独立于文本 Selection Session；切换 App 后持续运行，锁屏、权限撤销或目标显示器移除时安全结束。
- 开始实时翻译即授权该区域的后续文字更新请求；图片和视频不自动上传，只向选定服务发送识别出的文字。
- 此功能处理屏幕文字，不生成录像文件，也不处理音频。更新速度取决于 OCR、网络与服务商响应，持续变化的文字会增加接口调用量。

macOS 捕获、设备 OCR 和权限经 Swift 桥接入；Flutter/Dart 负责会话、请求调度和展示。建议先完成 #20，再推进 #24；录屏与 GIF 可独立安排。

## 候选功能，待用户选择

以下是开源工具已有能力的调研结果，尚未纳入 TranslateApp 工单。参考项目的平台支持不代表本项目已实现或可直接复用其代码。

| 候选 | 用途 | 参考 | 建议 |
| --- | --- | --- | --- |
| OCR 直接复制文字 | 从图片、视频画面提取文字，不必翻译 | NormCap、ShareX | 优先，复用 #20 |
| 延时截屏 | 留出时间展开菜单、悬停提示 | Flameshot、ksnip | 优先 |
| 重复截取上次区域 | 连续处理固定位置的内容 | ksnip | 优先 |
| 指定显示器、是否包含鼠标 | 多屏截图与操作说明 | Flameshot、ksnip | 优先，完善捕获选项 |
| 键盘微调框选区域、固定比例 | 精确控制边界和尺寸 | Flameshot | 优先，完善 #20 交互 |
| 自动命名、固定保存目录、复制并保存 | 减少重复保存操作 | ksnip、Flameshot | 优先，完善 #25、#26 |
| 滚动长截图 | 捕获超出一屏的网页或聊天内容 | ShareX | 后续，需验证不同 App 的滚动行为 |
| 截图历史 | 找回与复用近期图片 | Flameshot | 后续，与 #8 文本翻译历史分开 |
| 步骤编号、荧光笔 | 制作教程和反馈截图 | ShareX、Flameshot | 作为 #27 的可选工具 |
| 屏幕二维码识别 | 从画面提取链接或文本 | ShareX | 按需 |
| 图片拼接、拆分与比较 | 合并多张截图、查看差异 | ShareX | 按需 |
| 录制暂停、裁剪、点击高亮、APNG/WebM 导出 | 制作演示与问题复现素材 | Kap | 作为 #21、#23 的可选扩展 |
| 取色器、屏幕标尺、上传分享与自动工作流 | 设计辅助与文件分享 | ShareX | 较低优先级，偏离文字翻译主线 |

## 开源参考

- [ShareX](https://github.com/ShareX/ShareX)：Windows，GPL-3.0；功能依据官方 README。
- [Flameshot](https://github.com/flameshot-org/flameshot)：Linux、Windows、macOS，GPL-3.0；功能依据官方 README 的工具、快捷键和 CLI 说明。
- [ksnip](https://github.com/ksnip/ksnip)：Linux、Windows、macOS，GPL-3.0；具体捕获方式有平台差异，依据官方 README。
- [NormCap](https://dynobo.github.io/normcap/) / [源码](https://github.com/dynobo/normcap)：Linux、Windows、macOS，GPLv3；官方描述为 OCR 文字捕获工具，不据此承诺表格或多栏版式还原。
- [Kap](https://getkap.co/) / [源码](https://github.com/wulkano/Kap)：macOS 12+，MIT；官网与 README 列出区域录制、暂停、裁剪、点击高亮及导出格式。
- [MORT](https://github.com/kmonkeyhead/MORT)：Windows 10+，MIT；官方 README 明确列出实时翻译、多 OCR 区域和框选识别区域的操作，可参考区域实时文字翻译的交互。
