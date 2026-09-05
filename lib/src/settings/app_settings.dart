import '../translation/language_direction.dart';

/// Dart 持有完整偏好；平台只负责存储及热键、登录项等系统副作用。
class AppSettings {
  AppSettings({
    required this.primaryLanguage,
    required this.secondaryLanguage,
    this.automatic = true,
    this.shortcutKey = 'T',
    this.shortcutModifiers = 6144,
    this.launchAtLogin = false,
    Map<String, String>? excludedApps,
  }) : excludedApps = excludedApps ?? {};

  String primaryLanguage;
  String secondaryLanguage;
  bool automatic;
  String shortcutKey;
  int shortcutModifiers;
  bool launchAtLogin;
  final Map<String, String> excludedApps;

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
      primaryLanguage:
          map['primaryLanguage'] as String? ?? language.primaryCode,
      secondaryLanguage:
          map['secondaryLanguage'] as String? ?? language.secondaryCode,
      automatic: map['automatic'] as bool? ?? true,
      shortcutKey: map['shortcutKey'] as String? ?? 'T',
      shortcutModifiers: map['shortcutModifiers'] as int? ?? 6144,
      launchAtLogin: map['launchAtLogin'] as bool? ?? false,
      excludedApps: Map<String, String>.from(map['excludedApps'] as Map? ?? {}),
    );
  }

  /// 无参数；校验可执行的语言方向及系统快捷键，非法配置抛 FormatException。
  void validate() {
    if (primaryLanguage.isEmpty ||
        secondaryLanguage.isEmpty ||
        LanguageDirection.normalize(primaryLanguage) ==
            LanguageDirection.normalize(secondaryLanguage)) {
      throw const FormatException('主要语言和次要语言必须不同。');
    }
    // Shift 单独搭配字母会吞掉普通输入，至少要求一个系统修饰键。
    if (!RegExp(r'^[A-Z]$').hasMatch(shortcutKey) ||
        shortcutModifiers & 6400 == 0 ||
        shortcutModifiers & ~6912 != 0) {
      throw const FormatException('快捷键至少需要 Control、Option 或 Command。');
    }
  }

  /// 无参数；返回可经 MethodChannel 和 UserDefaults 存储的标量字典。
  Map<String, Object> toMap() => {
    'primaryLanguage': primaryLanguage,
    'secondaryLanguage': secondaryLanguage,
    'automatic': automatic,
    'shortcutKey': shortcutKey,
    'shortcutModifiers': shortcutModifiers,
    'launchAtLogin': launchAtLogin,
    'excludedApps': excludedApps,
  };

  /// 无参数；返回当前主要/次要语言决定的翻译方向规则。
  LanguageDirection get direction => LanguageDirection(
    primaryCode: primaryLanguage,
    secondaryCode: secondaryLanguage,
  );
}
