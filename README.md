# TranslateApp

macOS 14+ 全局选区翻译工具。当前只实现 macOS，不实现 Android、iOS 和 Windows。

## 架构

Flutter/Dart 负责应用界面与全部翻译业务；Swift 只负责 macOS 启动壳和系统桥接。

详见 [Flutter macOS 重构架构](docs/architecture.md)。工作项以 [GitHub Issues](https://github.com/1504101951/translateApp/issues) 为准，从 #13 开始。

## 仓库状态

产品实现是 Flutter/Dart + `macos/Runner` 桥。旧的 Swift Package 原型已删除。

## 开发

当前基线：#13 壳 + #2 选区翻译最小闭环。

```text
flutter test
flutter run -d macos
```

运行后菜单栏会出现「选区翻译」。首次需授予辅助功能权限。在其他应用里用鼠标拖选文字，点浮层「翻译」。
