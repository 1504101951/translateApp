# TranslateApp

macOS 14+ 全局选区翻译工具。当前只实现 macOS，不实现 Android、iOS 和 Windows。

## 架构

Flutter/Dart 负责应用界面与全部翻译业务；Swift 只负责 macOS 启动壳和系统桥接。

详见 [Flutter macOS 重构架构](docs/architecture.md)。工作项以 [GitHub Issues](https://github.com/1504101951/translateApp/issues) 为准，从 #13 开始。

## 仓库状态

当前 Swift Package 是原型参考。重构后不保留 Swift 与 Dart 两套翻译业务实现。

## 开发

当前基线是 Issue #13：Flutter macOS 壳 + Swift 非激活 Overlay。

```text
flutter test
flutter run -d macos
```

运行后菜单栏会出现「选区翻译」。选「探测 Overlay」可验证 Flutter 内容嵌在非激活 NSPanel 中：顶部条可拖动，「点击」可点，不应抢走源应用焦点。
