/// Dart 使用的跨端错误码协议值；与 Swift AppConstants 同名值字面量一致，改名须两端同步。
abstract final class ErrorCodes {
  static const invalidSettings = 'invalid_settings';

  static const ocrEmpty = 'ocr_empty';

  /// upload_failed：主 Dart 引擎上传截图失败或未配置目标，截图引擎显示其 message（#111）。
  static const uploadFailed = 'upload_failed';

  static const saveFailed = 'save_failed';

  static const settingsConflict = 'settings_conflict';

  static const staleCapture = 'stale_capture';

  static const testFailed = 'test_failed';

  static const translateFailed = 'translate_failed';

  /// Apple 系统翻译的语言对未下载语言包；变更须同步两端。
  static const translationNotInstalled = 'translation_not_installed';

  /// Apple 系统翻译不支持该语言对；变更须同步两端。
  static const translationUnsupported = 'translation_unsupported';
}
