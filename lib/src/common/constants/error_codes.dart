/// 跨端错误分类；与Swift对应值保持一致，调用方不重复定义。
abstract final class ErrorCodes {
  /// bad_app 的稳定协议值，变更须同步两端及持久化调用方。
  static const badApp = 'bad_app';

  /// bad_args 的稳定协议值，变更须同步两端及持久化调用方。
  static const badArgs = 'bad_args';

  /// bad_settings 的稳定协议值，变更须同步两端及持久化调用方。
  static const badSettings = 'bad_settings';

  /// copy_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const copyFailed = 'copy_failed';

  /// invalid_settings 的稳定协议值，变更须同步两端及持久化调用方。
  static const invalidSettings = 'invalid_settings';

  /// keychain_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const keychainFailed = 'keychain_failed';

  /// ocr_empty 的稳定协议值，变更须同步两端及持久化调用方。
  static const ocrEmpty = 'ocr_empty';

  /// ocr_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const ocrFailed = 'ocr_failed';

  /// rollback_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const rollbackFailed = 'rollback_failed';

  /// save_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const saveFailed = 'save_failed';

  /// settings_conflict 的稳定协议值，变更须同步两端及持久化调用方。
  static const settingsConflict = 'settings_conflict';

  /// settings_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const settingsFailed = 'settings_failed';

  /// shortcut_invalid 的稳定协议值，变更须同步两端及持久化调用方。
  static const shortcutInvalid = 'shortcut_invalid';

  /// stale_capture 的稳定协议值，变更须同步两端及持久化调用方。
  static const staleCapture = 'stale_capture';

  /// test_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const testFailed = 'test_failed';

  /// translate_failed 的稳定协议值，变更须同步两端及持久化调用方。
  static const translateFailed = 'translate_failed';
}
