# TranslateApp

macOS 14+ 全局选区翻译 App。Flutter/Dart 负责界面与翻译业务，Swift 负责系统能力；当前交付 macOS，其他平台列入后续规划。

## 安装与启动

```sh
./scripts/package-macos.sh
./scripts/install-macos.sh
open ~/Applications/TranslateApp.app
```

安装位置固定为 `~/Applications/TranslateApp.app`，可直接通过 Finder 或 Spotlight 启动。菜单栏「选区翻译」提供设置、仅使用快捷键开关和退出入口。设置使用独立普通窗口，翻译浮层使用非激活面板。

打包签名、辅助功能授权与旧副本说明见 [macOS 安装](docs/macos.md)。

## 使用

- 在其他应用拖选、双击、三击，或用 ⌘A、Shift 配合方向/Home/End/Page 键选中文字，会出现 84×36pt 的「翻译」按钮。键盘选区暂不能通过 Accessibility 读取时可先显示待确认按钮，点击后才读取文字；明确的文件和安全控件不显示按钮。
- 点击按钮展开左右双栏卡片，左侧译文、右侧原文，可分别复制全文；两列按段落同行对齐，悬停译文时高亮对应原文。默认全局快捷键 **⌃⌥T** 直接翻译当前选区。
- 「仅使用快捷键」默认关闭；开启后不再自动显示选区按钮，只能通过全局快捷键唤醒翻译。
- 浮层使用 status-bar 窗口层级，位于普通及 floating 应用窗口之上，且不取得 key/main 窗口身份。拖动按钮或卡片标题可移动浮层；切应用、清空选区、Escape、关闭或新选区会结束会话并取消当前请求。
- 文本在设备上识别语言；设置次要语言时，主要语言文本译为次要语言，其余或无法识别的文本译为主要语言。次要语言可不设置，此时统一以主要语言为目标，已是主要语言的文本直接展示，不发起外部请求。单次选区上限为 50,000 字符。
- 自动检测只读取辅助功能，不模拟复制按键；未暴露选中文字的应用不会自动弹出按钮。点击翻译或使用全局快捷键时允许一次性复制读取，保留网页段落与换行，并恢复剪贴板。
- 会话跟踪实际提供选中文字的辅助功能节点，焦点容器变化或暂时不可读不单独触发关闭；确认选区清空、外部点击、Escape 或离开来源 App 时关闭。没有可读节点的快捷键会话可通过外部点击、Escape 或切换 App 结束。

## 设置

设置支持主要语言、可选次要语言、仅使用快捷键、按键录制的全局快捷键、翻译服务、排除应用、登录启动和辅助功能授权状态。

快捷键在设置窗口点击录制，记录实际按键组合；Esc 或失焦取消。保存时校验启用的系统快捷键与 Carbon 独占占用，失败保留原组合。macOS 不提供其他 App 内部快捷键的统一枚举；普通非独占 Carbon 注册也不保证可检测。


点击「保存设置」生效。快捷键冲突时保留旧配置并显示错误；菜单更新不会无提示覆盖未保存的表单。偏好通过 UserDefaults 保存。排除应用同时禁止自动捕获和快捷键捕获。登录启动默认关闭，用户开启后通过 macOS 登录项服务管理。

## 翻译服务

在「设置 → 翻译服务 → 添加服务」中填写配置，点击「测试连接」验证，再选为默认服务并「保存设置」。支持多个命名配置；测试仅发送 `Hello world.` 示例文本，不保存设置。

| 服务 | 必填项 | 默认 API Base URL |
|---|---|---|
| Google 免费接口（非官方，初始默认） | 无 | 内置消费端接口 |
| 百度通用翻译 | App ID、密钥 | `https://fanyi-api.baidu.com` |
| Google Cloud Translation Basic v2 | 已启用 Translation API 的项目 API Key | `https://translation.googleapis.com` |
| OpenAI-compatible | API Key、模型 ID | `https://api.openai.com/v1` |
| DeepSeek | API Key、模型 ID，固定关闭思考 | `https://api.deepseek.com` |
| Anthropic 原生 Messages | API Key、模型 ID | `https://api.anthropic.com/v1` |

服务商账户、网络和额度决定实际可用性；消费端 App 的登录会员不等同于 API 凭据。Base URL 不包含具体接口路径或密钥；远程服务需要 HTTPS，本机 `localhost` / `127.0.0.1` / `::1` 可用 HTTP。

API Key 和百度 App ID 仅保存于 macOS Keychain。编辑配置时不显示已保存密钥，留空保留；删除服务并保存会删除对应凭据。打开设置、保存语言和开关等普通偏好不读取密钥或弹出钥匙串授权；翻译、测试连接和实际凭据修改才访问密钥。端点、模型、独立提示词等普通配置存入 UserDefaults。保存失败时恢复凭据和系统配置；翻译失败不会自动发送到其他服务。

新建模型配置使用中文默认提示词，每个配置可独立编辑。启用「按段落双语对照」后，模型接收带连续编号的全部原文段落，结合全文语义返回 `segments: [{id, translation}]`。应用要求编号完整、有序且每段译文非空，按编号配对本地原文并保留分隔空白；缺段、乱序和损坏结构均报告失败。段落边界采用原文非空行，不按鼠标选择的字符范围对齐，也不把单个未换行长段自动细分。编号校验不能证明译文的语义完全准确。

Google、百度及未开启语义对照的模型按原文段落顺序翻译并建立配对，不根据译文句数推断对应关系。原始换行、空行和末尾空白保留在两列及全文复制内容中。关闭会话会取消当前请求，某段失败后不继续请求后续段落。

DeepSeek 类型及域名为 `api.deepseek.com` 的 OpenAI-compatible 配置发送 `thinking: {type: "disabled"}`，段落模式同时启用 JSON 输出。关闭思考使用协议参数，提示词中的 `no_think` 不承担这一控制；其他兼容接口不接收 DeepSeek 专属参数。段落模式在整份结果校验完成后显示，实际耗时仍取决于模型、文本长度和网络。

接口参考：[百度通用翻译](https://fanyi-api.baidu.com/doc/21)、[Google Cloud v2](https://cloud.google.com/translate/docs/reference/rest/v2/translate)、[OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[DeepSeek 思考模式](https://api-docs.deepseek.com/guides/thinking_mode)、[Anthropic Messages](https://platform.claude.com/docs/en/api/messages)。

## 开发与验证

```sh
flutter test
flutter analyze
flutter run -d macos
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=arm64'
```

架构见 [架构说明](docs/architecture.md)，规格和验收以 [GitHub Issues](https://github.com/1504101951/translateApp/issues) 为准。

## 交付路线

| 工作 | 状态 / 工单 |
|---|---|
| 核心选区、非激活浮层、生命周期与平台桥 | 已完成，#2、#9–#11、#13 |
| 语言、仅使用快捷键与按键录制 | 已完成，#4、#14、#15 |
| 官方 Google、百度、模型配置、Keychain 与双语对照 | 已完成，#5、#6、#17、#18 |
| 独立 App、固定安装与签名脚本 | 已完成，#16 |
| Chrome 键盘自动按钮 | 已实现，实机验收保留在 #31 |
| 左右段落编号对照与悬停高亮 | 已实现，实机验收保留在 #33 |
| 次要语言可选 | 已实现并获用户确认，#34 |
| DeepSeek 关闭思考与普通设置免密钥读取 | 已实现，实机验收保留在 #35、#36 |
| 排除应用、登录启动、拖动与文本控件过滤 | 已实现，指定实机验收保留在 #3、#12 |
| Warp 等浮动来源窗口的叠放 | 层级修复及原生回归通过；真实 Warp 验收保留在 #19 |
| 长文本分段与失败片恢复 | 待实现，#7 |
| SQLite 翻译历史 | 待实现，#8 |
| 区域截屏 OCR、录屏、图片置顶、GIF、保存、复制与编辑 | 待实现，#20–#23、#25–#27 |
| 框选区域实时文字翻译 | 待实现，#24；持续 OCR，文字变化后更新译文 |
| 滚动长截图与本地截图历史 | 待实现，#28、#29 |
| OCR 文字复制、自动命名、固定保存目录与复制并保存 | 待实现，#20、#25、#26 |

总体规格 #1 保持开启。GitHub 使用 `spec`（总体规格）、`planned`（待实现）、`needs-verification`（待指定实机验收）标签；工单类型使用 `bug` / `enhancement`。

初始翻译源为非官方 Google；保存默认服务后，下次翻译立即使用该服务。各工单的最终验收状态以 Issue 中的证据为准。

截图与录屏的已确认范围、工单依赖和开源工具候选功能见 [截图与实时翻译规划](docs/capture-roadmap.md)。
