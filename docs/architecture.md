# Flutter macOS 重构架构

当前只交付 macOS 14+。Flutter/Dart 是应用与业务主体，Swift 是 macOS 启动壳和系统桥接。

## 架构图

```mermaid
flowchart LR
    Apps[macOS 源应用] --> Bridge[Swift macOS 桥]
    Bridge --> Session[Dart Selection Session]
    Session --> Engine[Dart Translation Engine]
    Engine --> Providers[Google / OpenAI / Anthropic]
    Session --> UI[Flutter Overlay / 设置 / 历史]
    UI --> Panel[Swift 非激活 NSPanel]
    Engine --> Store[Dart SQLite / Settings]
```

## 翻译流程

```mermaid
flowchart TD
    A[鼠标选区或 Command-A] --> B{合法文本上下文?}
    B -- 否 --> C[忽略]
    B -- 是 --> D[显示 Trigger Overlay]
    D --> E{点击翻译或会话失效?}
    E -- 失效 / Escape --> F[取消并隐藏]
    E -- 点击 --> G[长度校验、语言方向、分片]
    G --> H[Provider 串行翻译并流式更新]
    H --> I{全部完成?}
    I -- 否 --> J[保留完成片并从失败片重试]
    J --> H
    I -- 是 --> K[显示结果并写入一条历史记录]
```

## 职责边界

| Flutter/Dart | Swift macOS 桥 |
|---|---|
| Session、Provider、分片、流式状态、Overlay 内容、设置、SQLite | Accessibility、全局鼠标/按键、Text Selection Context、非激活 NSPanel、Keychain、登录项 |

Dart 是业务状态的唯一事实源。Swift 不保存翻译状态，不实现 Provider，不写翻译业务。

## 目录结构

```text
translateApp/
├── pubspec.yaml
├── lib/
│   ├── main.dart
│   └── src/
│       ├── platform/macos_platform_bridge.dart
│       ├── selection/
│       ├── translation/providers/
│       ├── overlay/
│       ├── settings/
│       └── history/
├── macos/Runner/
│   ├── MacPlatformBridge.swift
│   ├── AccessibilitySelection.swift
│   ├── SelectionMonitor.swift
│   └── OverlayPanel.swift
└── test/
```

只在对应 Issue 开始时创建目录和文件，不提前搭建空模块。

## 平台通道

- Swift → Dart：`selectionCaptured`、`selectionInvalidated`、权限变化、Escape。
- Dart → Swift：显示/隐藏 Overlay、权限设置、应用排除、Keychain、登录项。
- Swift `NSPanel` 原生处理拖动；同一 `sessionId` 保留位置，新 Session 重置到新选区锚点。
- 所有事件和命令携带 `sessionId`，过期 Session 的结果直接丢弃。

## 实施顺序

```text
#13 → #2 → (#9、#11、#12) → #10 → #3 → (#4、#5、#6) → #7 → #8
```

#13 必须先验证 Flutter 内容可在非激活 `NSPanel` 中交互，且不会抢占源应用焦点。完成 Dart 迁移后删除对应 Swift 业务代码，不维护兼容层。
