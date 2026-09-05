# TranslateApp

macOS 14+ 全局选区翻译 App。Flutter/Dart 负责界面与翻译业务，Swift 负责系统能力；当前交付 macOS，其他平台列入后续规划。

## 安装与启动

```sh
./scripts/package-macos.sh
./scripts/install-macos.sh
open ~/Applications/TranslateApp.app
```

安装位置固定为 `~/Applications/TranslateApp.app`，可直接通过 Finder 或 Spotlight 启动。菜单栏「选区翻译」提供设置、自动按钮开关和退出入口。设置使用独立普通窗口，翻译浮层使用非激活面板。

打包签名、辅助功能授权与旧副本说明见 [macOS 安装](docs/macos.md)。

## 使用

- 在其他应用拖选、双击、三击，或用 ⌘A、Shift 配合方向/Home/End/Page 键选中文字，会出现 84×36pt 的「翻译」按钮。
- 点击按钮展开译文卡片；默认全局快捷键 **⌃⌥T** 直接翻译当前选区。
- 自动按钮开关仅控制选区后的自动提示；关闭后全局快捷键仍可显示译文卡片。
- 浮层不取得 key/main 窗口身份。拖动按钮或卡片标题可移动浮层；切应用、清空选区、Escape、关闭或新选区会结束会话并取消当前请求。
- 文本在设备上识别语言；主要语言文本译为次要语言，其余或无法识别的文本译为主要语言。单次选区上限为 50,000 字符。

## 设置

设置支持主要/次要语言、自动显示按钮、修饰键与字母组成的全局快捷键、排除应用、登录启动和辅助功能授权状态。

点击「保存设置」生效。快捷键冲突时保留旧配置并显示错误；菜单更新不会无提示覆盖未保存的表单。偏好通过 UserDefaults 保存。排除应用同时禁止自动捕获和快捷键捕获。登录启动默认关闭，用户开启后通过 macOS 登录项服务管理。

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
| 官方 Google、模型配置与 Keychain 凭据 | 待实现，#5、#6 |
| 长文本分段与失败片恢复 | 待实现，#7 |
| SQLite 翻译历史 | 待实现，#8 |

当前翻译源为非官方 Google，网络可用性由该服务决定。各工单的最终验收状态以 Issue 中的证据为准。
