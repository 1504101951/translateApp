/// Dart 使用的持久化偏好键协议值；与 Swift AppConstants 同名值字面量一致，改名须两端同步。
abstract final class PreferenceKeys {
  /// 每工具独立绘图参数。
  static const screenshotDrawing = 'screenshotDrawing';
  static const screenshotToolbarHidden = 'screenshotToolbarHidden';
  static const screenshotToolbarOrder = 'screenshotToolbarOrder';

  /// 截图工具栏的父子结构：父级ID到子级ID列表；与原生偏好键一致。
  static const screenshotToolbarChildren = 'screenshotToolbarChildren';
  static const screenshotToolbarShortcuts = 'screenshotToolbarShortcuts';

  static const automatic = 'automatic';

  static const defaultServiceId = 'defaultServiceId';

  static const excludedApps = 'excludedApps';

  /// 区域截图冻结帧是否包含鼠标指针；Swift 冻结画面时读取（#105）。
  static const screenshotIncludesCursor = 'screenshotIncludesCursor';

  /// 区域与显示器录制是否由系统绘制鼠标点击高亮；Swift 开始录制时读取（#110）。
  static const recordingShowsClicks = 'recordingShowsClicks';

  /// 长截图滚动方式：manual 或 automatic；Swift 开始长截图时读取（#112）。
  static const scrollCaptureMode = 'scrollCaptureMode';

  /// 确认截图时的动作：copy 或 copyAndSave；仅 Dart 读取（#111）。
  static const screenshotConfirmAction = 'screenshotConfirmAction';

  /// 术语表；值为 {term, translation, language} 字典列表，仅 Dart 读取（#104）。
  static const glossary = 'glossary';

  static const glassAppearance = 'glassAppearance';

  static const glassOpacity = 'glassOpacity';

  static const launchAtLogin = 'launchAtLogin';

  static const primaryLanguage = 'primaryLanguage';

  static const screenshotSaveDirectory = 'screenshotSaveDirectory';

  /// GIF完整视频导出的每秒采样帧数；与原生偏好键一致。
  static const gifFramesPerSecond = 'gifFramesPerSecond';

  /// 实时翻译时是否同步录制；与原生偏好键一致。
  static const liveRecording = 'liveRecording';

  /// 是否允许本机 MCP 客户端截图（#96）；与原生 AppConstants.mcpEnabledKey 一致。
  static const mcpEnabled = 'mcpEnabled';

  /// GIF最大像素宽度；省略表示不限制，输出仍不会放大原视频。
  static const gifMaximumWidth = 'gifMaximumWidth';

  static const screenshotShortcutKeyCode = 'screenshotShortcutKeyCode';

  static const screenshotShortcutLabel = 'screenshotShortcutLabel';

  static const screenshotShortcutModifiers = 'screenshotShortcutModifiers';

  static const secondaryLanguage = 'secondaryLanguage';

  static const services = 'services';

  static const shortcutKeyCode = 'shortcutKeyCode';

  static const shortcutLabel = 'shortcutLabel';

  static const shortcutModifiers = 'shortcutModifiers';

  /// 输入翻译快捷键键码；变更须同步两端及持久化调用方。
  static const inputShortcutKeyCode = 'inputShortcutKeyCode';

  /// 输入翻译快捷键显示名；变更须同步两端及持久化调用方。
  static const inputShortcutLabel = 'inputShortcutLabel';

  /// 输入翻译快捷键修饰键；变更须同步两端及持久化调用方。
  static const inputShortcutModifiers = 'inputShortcutModifiers';
}
