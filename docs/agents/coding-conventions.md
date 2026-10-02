# 代码约定

Source-Spec: #1。Codex-Thread: 01a0a9f5-d737-7871-a14f-c80c1fb51332。

改 Dart / Swift 生产代码时遵守本节。测试里指向真实通道或方法的字面量同样引用常量；仅测试夹具使用的通道名（如 `test/screenshot-pin`）可就地书写。

## 常量

跨模块复用的字面量只定义一次：

- Dart：`lib/src/common/constants/`
- Swift：`macos/Runner/Common/Constants.swift`

必须进常量的内容：

- 平台通道名（`translateapp/...`）
- 平台方法名（`invokeMethod` / `case` 分支）
- UserDefaults 键
- 引擎入口名（`settingsMain`、`screenshotMain` 等）
- 平台视图类型名
- 错误码（`FlutterError(code:)`）
- 状态机枚举（截图工具、标注种类、翻译阶段）
- 跨引擎外观模式和通知名称；UI 尺寸复用 `GlassMetrics`，数值以 Spec #1 与 UI 规则为准

调用处引用常量，不在业务文件里再写同一字符串。Dart 与 Swift 各自一份常量文件，字面量必须一致，不在两端各写一份散落的通道名或方法名。

单处私有、不会被第二处引用的文案可以留在该模块内。

## 工具函数

被两处及以上使用、且不属于单一模块私有职责的方法放在：

- Dart：`lib/src/common/utils/`
- Swift：`macos/Runner/Common/Utils.swift`

## 注释

每个类写明作用与职责边界。每个函数写明作用、参数含义与结构、返回值含义与结构。变量注释说明为什么，不复述名字。

## 当前协议入口

Dart 的 `ChannelNames`、`MethodNames`、`PreferenceKeys`、`ErrorCodes`、`PlatformViewTypes`、`BridgeEventTypes` 与 `TranslationPhase` 分别保存通道、方法、偏好字段、错误码、平台视图、系统事件和翻译状态；Swift 对应值统一在 `AppConstants`。新协议或偏好字段先定义常量，再在生产调用和真实协议测试中引用。`test/...` 夹具通道属于测试私有输入。
