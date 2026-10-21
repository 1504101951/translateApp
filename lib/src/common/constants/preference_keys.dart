/// 持久化偏好字段；与Swift对应值保持一致，调用方不重复定义。
abstract final class PreferenceKeys {
  /// 每工具独立绘图参数。
  static const screenshotDrawing = 'screenshotDrawing';
  static const screenshotToolbarHidden = 'screenshotToolbarHidden';
  static const screenshotToolbarOrder = 'screenshotToolbarOrder';

  /// 截图工具栏的父子结构：父级ID到子级ID列表；与原生偏好键一致。
  static const screenshotToolbarChildren = 'screenshotToolbarChildren';
  static const screenshotToolbarShortcuts = 'screenshotToolbarShortcuts';

  /// automatic 的稳定协议值，变更须同步两端及持久化调用方。
  static const automatic = 'automatic';

  /// defaultServiceId 的稳定协议值，变更须同步两端及持久化调用方。
  static const defaultServiceId = 'defaultServiceId';

  /// excludedApps 的稳定协议值，变更须同步两端及持久化调用方。
  static const excludedApps = 'excludedApps';

  /// 区域截图冻结帧是否包含鼠标指针；Swift 冻结画面时读取（#105）。
  static const screenshotIncludesCursor = 'screenshotIncludesCursor';

  /// 区域与显示器录制是否由系统绘制鼠标点击高亮；Swift 开始录制时读取（#110）。
  static const recordingShowsClicks = 'recordingShowsClicks';

  /// 确认截图时的动作：copy、copyAndSave 或 upload；仅 Dart 读取（#111）。
  static const screenshotConfirmAction = 'screenshotConfirmAction';

  /// S3 兼容上传目标的服务地址、区域、存储桶、对象键前缀与分享链接前缀；仅 Dart 读取，访问密钥在钥匙串（#111）。
  static const uploadEndpoint = 'uploadEndpoint';
  static const uploadRegion = 'uploadRegion';
  static const uploadBucket = 'uploadBucket';
  static const uploadPrefix = 'uploadPrefix';
  static const uploadPublicBase = 'uploadPublicBase';

  /// 上传访问密钥的钥匙串账户；值为 {accessKeyId, secretAccessKey}，随 saveSettings 的 credentials 提交（#111）。
  static const uploadCredentials = 'upload-s3';

  /// 术语表；值为 {term, translation, language} 字典列表，仅 Dart 读取（#104）。
  static const glossary = 'glossary';

  /// glassAppearance 的稳定协议值，变更须同步两端及持久化调用方。
  static const glassAppearance = 'glassAppearance';

  /// glassOpacity 的稳定协议值，变更须同步两端及持久化调用方。
  static const glassOpacity = 'glassOpacity';

  /// launchAtLogin 的稳定协议值，变更须同步两端及持久化调用方。
  static const launchAtLogin = 'launchAtLogin';

  /// permissionWizardFinished 的稳定协议值，变更须同步两端及持久化调用方。
  static const permissionWizardFinished = 'permissionWizardFinished';

  /// preferences 的稳定协议值，变更须同步两端及持久化调用方。
  static const preferences = 'preferences';

  /// primaryLanguage 的稳定协议值，变更须同步两端及持久化调用方。
  static const primaryLanguage = 'primaryLanguage';

  /// screenshotSaveDirectory 的稳定协议值，变更须同步两端及持久化调用方。
  static const screenshotSaveDirectory = 'screenshotSaveDirectory';

  /// GIF完整视频导出的每秒采样帧数；与原生偏好键一致。
  static const gifFramesPerSecond = 'gifFramesPerSecond';

  /// 实时翻译时是否同步录制；与原生偏好键一致。
  static const liveRecording = 'liveRecording';

  /// 是否允许本机 MCP 客户端截图（#96）；与原生 AppConstants.mcpEnabledKey 一致。
  static const mcpEnabled = 'mcpEnabled';

  /// GIF最大像素宽度；省略表示不限制，输出仍不会放大原视频。
  static const gifMaximumWidth = 'gifMaximumWidth';

  /// screenshotShortcutKeyCode 的稳定协议值，变更须同步两端及持久化调用方。
  static const screenshotShortcutKeyCode = 'screenshotShortcutKeyCode';

  /// screenshotShortcutLabel 的稳定协议值，变更须同步两端及持久化调用方。
  static const screenshotShortcutLabel = 'screenshotShortcutLabel';

  /// screenshotShortcutModifiers 的稳定协议值，变更须同步两端及持久化调用方。
  static const screenshotShortcutModifiers = 'screenshotShortcutModifiers';

  /// secondaryLanguage 的稳定协议值，变更须同步两端及持久化调用方。
  static const secondaryLanguage = 'secondaryLanguage';

  /// services 的稳定协议值，变更须同步两端及持久化调用方。
  static const services = 'services';

  /// shortcutKeyCode 的稳定协议值，变更须同步两端及持久化调用方。
  static const shortcutKeyCode = 'shortcutKeyCode';

  /// shortcutLabel 的稳定协议值，变更须同步两端及持久化调用方。
  static const shortcutLabel = 'shortcutLabel';

  /// shortcutModifiers 的稳定协议值，变更须同步两端及持久化调用方。
  static const shortcutModifiers = 'shortcutModifiers';

  /// 输入翻译快捷键键码；变更须同步两端及持久化调用方。
  static const inputShortcutKeyCode = 'inputShortcutKeyCode';

  /// 输入翻译快捷键显示名；变更须同步两端及持久化调用方。
  static const inputShortcutLabel = 'inputShortcutLabel';

  /// 输入翻译快捷键修饰键；变更须同步两端及持久化调用方。
  static const inputShortcutModifiers = 'inputShortcutModifiers';
}
