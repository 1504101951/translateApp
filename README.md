# TranslateApp

macOS 14+ 全局选区翻译工具。当前只实现 macOS，不实现 Android、iOS 和 Windows。

## 架构

Flutter/Dart 负责应用界面与全部翻译业务；Swift 只负责 macOS 启动壳和系统桥接。

详见 [Flutter macOS 重构架构](docs/architecture.md)。工作项以 [GitHub Issues](https://github.com/1504101951/translateApp/issues) 为准，从 #13 开始。

## 仓库状态

产品实现是 Flutter/Dart + `macos/Runner` 桥。旧的 Swift Package 原型已删除。

## 开发

当前实现：鼠标及键盘选区翻译、单按钮触发态、非激活浮层、来源应用切换与选区失效关闭。翻译源为非官方 Google。

```text
flutter test
flutter analyze
flutter run -d macos
```

运行后菜单栏会出现「选区翻译」。首次需授予辅助功能权限。在其他应用中拖选、双击、三击文字，或用 ⌘A、Shift 配合方向/Home/End/Page 键选中文字，会出现 84×36pt 的圆角「翻译」按钮。点击后展开译文卡片，键盘焦点保留在来源应用。

拖动按钮或译文卡片标题可移动浮层。切换应用、清空选区、按 Escape 或关闭译文卡片会结束会话，并取消尚未完成的翻译请求。
