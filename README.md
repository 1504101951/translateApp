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

- 在其他应用拖选、双击、三击，或用 ⌘A、Shift 配合方向/Home/End/Page 键选中文字，会出现 84×36pt 的「翻译」按钮。
- 点击按钮展开双语卡片，原文在上、译文在下，可分别复制；默认全局快捷键 **⌃⌥T** 直接翻译当前选区。
- 「仅使用快捷键」默认关闭；开启后不再自动显示选区按钮，只能通过全局快捷键唤醒翻译。
- 浮层使用 status-bar 窗口层级，位于普通及 floating 应用窗口之上，且不取得 key/main 窗口身份。拖动按钮或卡片标题可移动浮层；切应用、清空选区、Escape、关闭或新选区会结束会话并取消当前请求。
- 文本在设备上识别语言；主要语言文本译为次要语言，其余或无法识别的文本译为主要语言。单次选区上限为 50,000 字符。

## 设置

设置支持主要/次要语言、仅使用快捷键、按键录制的全局快捷键、翻译服务、排除应用、登录启动和辅助功能授权状态。

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
| Anthropic 原生 Messages | API Key、模型 ID | `https://api.anthropic.com/v1` |

服务商账户、网络和额度决定实际可用性；消费端 App 的登录会员不等同于 API 凭据。Base URL 不包含具体接口路径或密钥；远程服务需要 HTTPS，本机 `localhost` / `127.0.0.1` / `::1` 可用 HTTP。

API Key 和百度 App ID 仅保存于 macOS Keychain。编辑配置时不显示已保存密钥，留空保留；删除服务并保存会删除对应凭据。端点、模型、独立提示词等普通配置存入 UserDefaults。保存失败时恢复凭据和系统配置；翻译失败不会自动发送到其他服务。

新建模型配置使用中文默认提示词，每个配置可独立编辑。语义模式会追加中文 JSON 格式约束，要求完整译文及逐字原文片段配对。模型普通模式逐步显示译文。启用「按语义分段双语对照」后，模型一次生成完整译文与配对段落，完成后显示；应用验证源段落按顺序覆盖全部原文，界面使用本地原文。无效分段退回完整原文/译文；截断或损坏的结构报告失败。覆盖校验不能证明模型的语义对应完全准确，该功能不执行长文本请求分批。

接口参考：[百度通用翻译](https://fanyi-api.baidu.com/doc/21)、[Google Cloud v2](https://cloud.google.com/translate/docs/reference/rest/v2/translate)、[OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[Anthropic Messages](https://platform.claude.com/docs/en/api/messages)。

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
| 非激活单按钮、鼠标/键盘选区、失效与请求取消 | 已实现，#2、#9–#13 保留真实 App 验收 |
| 设置、语言、排除应用、登录启动 | 已实现，#3、#4 |
| 自动按钮开关、全局快捷键 | 已实现，#14、#15 |
| 独立 App、固定安装及签名脚本 | #16 |
| 官方 Google、模型配置与 Keychain 凭据 | 已实现，#5、#6；真实账号接入在 App 中测试 |
| 百度通用翻译 | 已实现，#17 |
| 双语卡片与模型语义对照 | 已实现，#18 |
| 长文本分段与失败片恢复 | 待实现，#7 |
| SQLite 翻译历史 | 待实现，#8 |

初始翻译源为非官方 Google；保存默认服务后，下次翻译立即使用该服务。各工单的最终验收状态以 Issue 中的证据为准。
