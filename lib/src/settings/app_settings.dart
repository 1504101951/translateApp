import '../translation/language_direction.dart';
import 'service_config.dart';

/// Dart 持有完整偏好；平台只负责存储及热键、登录项等系统副作用。
class AppSettings {
  AppSettings({
    required this.primaryLanguage,
    required this.secondaryLanguage,
    this.automatic = true,
    this.shortcutKeyCode = 17,
    this.shortcutLabel = 'T',
    this.shortcutModifiers = 6144,
    this.launchAtLogin = false,
    Map<String, String>? excludedApps,
    this.defaultServiceId = ServiceConfig.builtinId,
    List<ServiceConfig>? services,
  }) : excludedApps = excludedApps ?? {},
       services = services ?? [];

  String primaryLanguage;
  String secondaryLanguage;
  bool automatic;
  int shortcutKeyCode;
  String shortcutLabel;
  int shortcutModifiers;
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
      primaryLanguage:
          map['primaryLanguage'] as String? ?? language.primaryCode,
      secondaryLanguage:
          map['secondaryLanguage'] as String? ?? language.secondaryCode,
      automatic: map['automatic'] as bool? ?? true,
      defaultServiceId:
          map['defaultServiceId'] as String? ?? ServiceConfig.builtinId,
      services: (map['services'] as List? ?? [])
          .map(
            (e) => ServiceConfig.fromMap(Map<Object?, Object?>.from(e as Map)),
          )
          .toList(),
      shortcutKeyCode: map['shortcutKeyCode'] as int? ?? 17,
      shortcutLabel: map['shortcutLabel'] as String? ?? 'T',
      shortcutModifiers: map['shortcutModifiers'] as int? ?? 6144,
      launchAtLogin: map['launchAtLogin'] as bool? ?? false,
      excludedApps: Map<String, String>.from(map['excludedApps'] as Map? ?? {}),
    );
  }

  /// 无参数；校验可执行的语言方向及系统快捷键，非法配置抛 FormatException。
  void validate() {
    for (final service in services) {
      service.validate();
    }
    if (services.map((e) => e.id).toSet().length != services.length ||
        defaultServiceId != ServiceConfig.builtinId &&
            !services.any((e) => e.id == defaultServiceId)) {
      throw const FormatException('默认翻译服务不存在或配置标识重复。');
    }
    if (primaryLanguage.isEmpty ||
        secondaryLanguage.isEmpty ||
        LanguageDirection.normalize(primaryLanguage) ==
            LanguageDirection.normalize(secondaryLanguage)) {
      throw const FormatException('主要语言和次要语言必须不同。');
    }
    // Shift 单独搭配字母会吞掉普通输入，至少要求一个系统修饰键。
    if (shortcutKeyCode < 0 ||
        shortcutKeyCode > 127 ||
        shortcutLabel.isEmpty ||
        shortcutModifiers & 6400 == 0 ||
        shortcutModifiers & ~6912 != 0) {
      throw const FormatException('快捷键至少需要 Control、Option 或 Command。');
    }
  }

  /// 无参数；返回可经 MethodChannel 和 UserDefaults 存储的标量字典。
  Map<String, Object> toMap() => {
    'defaultServiceId': defaultServiceId,
    'services': services.map((e) => e.toMap()).toList(),
    'primaryLanguage': primaryLanguage,
    'secondaryLanguage': secondaryLanguage,
    'automatic': automatic,
    'shortcutKeyCode': shortcutKeyCode,
    'shortcutLabel': shortcutLabel,
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
