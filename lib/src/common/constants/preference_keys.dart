/// 持久化偏好字段；与Swift对应值保持一致，调用方不重复定义。
abstract final class PreferenceKeys {
  /// 每工具独立绘图参数。
  static const screenshotDrawing = 'screenshotDrawing';
  static const screenshotToolbarHidden = 'screenshotToolbarHidden';
  static const screenshotToolbarOrder = 'screenshotToolbarOrder';
  static const screenshotToolbarShortcuts = 'screenshotToolbarShortcuts';

  /// automatic 的稳定协议值，变更须同步两端及持久化调用方。
  static const automatic = 'automatic';

  /// defaultServiceId 的稳定协议值，变更须同步两端及持久化调用方。
  static const defaultServiceId = 'defaultServiceId';

  /// excludedApps 的稳定协议值，变更须同步两端及持久化调用方。
  static const excludedApps = 'excludedApps';

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
}
