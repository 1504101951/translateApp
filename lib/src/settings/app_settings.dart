import '../common/constants/appearance_modes.dart';
import '../common/constants/preference_keys.dart';
import '../translation/language_direction.dart';
import 'service_config.dart';
import 'screenshot_toolbar_preferences.dart';

/// Dart 持有完整偏好；平台只负责存储及热键、登录项等系统副作用。
class AppSettings {
  AppSettings({
    required this.primaryLanguage,
    this.secondaryLanguage,
    this.automatic = true,
    this.shortcutKeyCode = 17,
    this.shortcutLabel = 'T',
    this.shortcutModifiers = 6144,
    this.screenshotShortcutKeyCode = 1,
    this.screenshotShortcutLabel = 'S',
    this.screenshotShortcutModifiers = 6144,
    this.screenshotSaveDirectory = '',
    this.glassAppearance = AppearanceModes.system,
    this.glassOpacity = 0.8,
    this.launchAtLogin = false,
    Map<String, String>? excludedApps,
    this.defaultServiceId = ServiceConfig.builtinId,
    List<ServiceConfig>? services,
    ScreenshotToolbarPreferences? screenshotToolbar,
  }) : excludedApps = excludedApps ?? {},
       services = services ?? [],
       screenshotToolbar = screenshotToolbar ?? ScreenshotToolbarPreferences();

  ScreenshotToolbarPreferences screenshotToolbar;
  String primaryLanguage;
  String? secondaryLanguage;
  bool automatic;
  int shortcutKeyCode;
  String shortcutLabel;
  int shortcutModifiers;
  int screenshotShortcutKeyCode;
  String screenshotShortcutLabel;
  int screenshotShortcutModifiers;

  /// 固定截图保存目录；空字符串表示每次保存时询问。
  String screenshotSaveDirectory;

  /// 视觉偏好与业务设置一同提交，不单独保存第二份配置。
  String glassAppearance;
  double glassOpacity;
  bool launchAtLogin;
  final Map<String, String> excludedApps;
  String defaultServiceId;
  final List<ServiceConfig> services;

  static const languages = {
    'zh-CN': '简体中文',
    'zh-TW': '繁體中文',
    'en': 'English',
    'ja': '日本語',
    'ko': '한국어',
    'fr': 'Français',
    'de': 'Deutsch',
    'es': 'Español',
    'pt': 'Português',
    'it': 'Italiano',
    'ru': 'Русский',
    'ar': 'العربية',
    'hi': 'हिन्दी',
    'th': 'ไทย',
    'vi': 'Tiếng Việt',
    'id': 'Bahasa Indonesia',
    'nl': 'Nederlands',
    'tr': 'Türkçe',
  };

  /// map 为原生偏好字典；缺省语言取 macOS 首选语言，返回可编辑偏好。
  factory AppSettings.fromMap(Map<Object?, Object?> map) {
    final language = LanguageDirection.systemDefault(
      languageCode: map['systemLanguage'] as String?,
    );
    return AppSettings(
      screenshotToolbar: ScreenshotToolbarPreferences.fromMap(map),
      primaryLanguage:
          map[PreferenceKeys.primaryLanguage] as String? ??
          language.primaryCode,
      secondaryLanguage: map[PreferenceKeys.secondaryLanguage] as String?,
      automatic: map[PreferenceKeys.automatic] as bool? ?? true,
      defaultServiceId:
          map[PreferenceKeys.defaultServiceId] as String? ??
          ServiceConfig.builtinId,
      services: (map[PreferenceKeys.services] as List? ?? [])
          .map(
            (e) => ServiceConfig.fromMap(Map<Object?, Object?>.from(e as Map)),
          )
          .toList(),
      shortcutKeyCode: map[PreferenceKeys.shortcutKeyCode] as int? ?? 17,
      shortcutLabel: map[PreferenceKeys.shortcutLabel] as String? ?? 'T',
      shortcutModifiers: map[PreferenceKeys.shortcutModifiers] as int? ?? 6144,
      screenshotShortcutKeyCode:
          map[PreferenceKeys.screenshotShortcutKeyCode] as int? ?? 1,
      screenshotShortcutLabel:
          map[PreferenceKeys.screenshotShortcutLabel] as String? ?? 'S',
      screenshotShortcutModifiers:
          map[PreferenceKeys.screenshotShortcutModifiers] as int? ?? 6144,
      screenshotSaveDirectory:
          map[PreferenceKeys.screenshotSaveDirectory] as String? ?? '',
      glassAppearance:
          map[PreferenceKeys.glassAppearance] as String? ??
          AppearanceModes.system,
      glassOpacity:
          (map[PreferenceKeys.glassOpacity] as num?)?.toDouble() ?? 0.8,
      launchAtLogin: map[PreferenceKeys.launchAtLogin] as bool? ?? false,
      excludedApps: Map<String, String>.from(
        map[PreferenceKeys.excludedApps] as Map? ?? {},
      ),
    );
  }

  /// 无参数；校验可执行的语言方向及系统快捷键，非法配置抛 FormatException。
  void validate() {
    screenshotToolbar.validate();
    if (!AppearanceModes.values.contains(glassAppearance) ||
        !glassOpacity.isFinite ||
        glassOpacity < 0.2 ||
        glassOpacity > 1) {
      throw const FormatException('外观模式或玻璃透明度无效。');
    }
    for (final service in services) {
      service.validate();
    }
    if (services.map((e) => e.id).toSet().length != services.length ||
        defaultServiceId != ServiceConfig.builtinId &&
            !services.any((e) => e.id == defaultServiceId)) {
      throw const FormatException('默认翻译服务不存在或配置标识重复。');
    }
    if (primaryLanguage.isEmpty ||
        secondaryLanguage != null &&
            (secondaryLanguage!.isEmpty ||
                LanguageDirection.normalize(primaryLanguage) ==
                    LanguageDirection.normalize(secondaryLanguage!))) {
      throw const FormatException('主要语言和次要语言必须不同。');
    }
    // Shift 单独搭配字母会吞掉普通输入，至少要求一个系统修饰键。
    for (final (code, label, modifiers) in [
      (shortcutKeyCode, shortcutLabel, shortcutModifiers),
      (
        screenshotShortcutKeyCode,
        screenshotShortcutLabel,
        screenshotShortcutModifiers,
      ),
    ]) {
      if (code < 0 ||
          code > 127 ||
          code == 53 ||
          label.isEmpty ||
          modifiers & 6400 == 0 ||
          modifiers & ~6912 != 0) {
        throw const FormatException(
          '快捷键至少需要 Control、Option 或 Command，且不能使用 Esc。',
        );
      }
    }
    if (shortcutKeyCode == screenshotShortcutKeyCode &&
        shortcutModifiers == screenshotShortcutModifiers) {
      throw const FormatException('翻译与截图快捷键不能相同。');
    }
  }

  /// 无参数；返回可经 MethodChannel 和 UserDefaults 存储的标量字典。
  Map<String, Object> toMap() => {
    ...screenshotToolbar.toMap(),
    PreferenceKeys.defaultServiceId: defaultServiceId,
    PreferenceKeys.services: services.map((e) => e.toMap()).toList(),
    PreferenceKeys.primaryLanguage: primaryLanguage,
    // 完整偏好字典通过 UserDefaults 覆盖保存；省略未设置项，避免存储不支持的 null。
    PreferenceKeys.secondaryLanguage: ?secondaryLanguage,
    PreferenceKeys.automatic: automatic,
    PreferenceKeys.shortcutKeyCode: shortcutKeyCode,
    PreferenceKeys.shortcutLabel: shortcutLabel,
    PreferenceKeys.shortcutModifiers: shortcutModifiers,
    PreferenceKeys.screenshotShortcutKeyCode: screenshotShortcutKeyCode,
    PreferenceKeys.screenshotShortcutLabel: screenshotShortcutLabel,
    PreferenceKeys.screenshotShortcutModifiers: screenshotShortcutModifiers,
    PreferenceKeys.screenshotSaveDirectory: screenshotSaveDirectory,
    PreferenceKeys.glassAppearance: glassAppearance,
    PreferenceKeys.glassOpacity: glassOpacity,
    PreferenceKeys.launchAtLogin: launchAtLogin,
    PreferenceKeys.excludedApps: excludedApps,
  };

  /// 无参数；返回当前主要/次要语言决定的翻译方向规则。
  LanguageDirection get direction => LanguageDirection(
    primaryCode: primaryLanguage,
    secondaryCode: secondaryLanguage,
  );
}
