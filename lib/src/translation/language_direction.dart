/// 根据设备识别的来源语言，选择用户配置的主要或次要语言。
class LanguageDirection {
  const LanguageDirection({
    required this.primaryCode,
    required this.secondaryCode,
  });
  final String primaryCode;
  final String secondaryCode;

  /// languageCode 为 macOS 首选 BCP-47 语言；返回初始主/次语言。
  factory LanguageDirection.systemDefault({String? languageCode}) {
    final primary = normalize(languageCode ?? 'en');
    return LanguageDirection(
      primaryCode: primary,
      secondaryCode: primary == 'en' ? 'zh-CN' : 'en',
    );
  }

  /// detected 为设备识别结果或 null；返回来源语言及此次翻译的目标语言。
  ({String? detectedLanguage, String targetLanguage}) resolve(
    String? detected,
  ) {
    final code = detected == null ? null : normalize(detected);
    return (
      detectedLanguage: code,
      targetLanguage: code == normalize(primaryCode)
          ? secondaryCode
          : primaryCode,
    );
  }

  /// raw 为 BCP-47 或下划线格式语言码；返回翻译服务使用的语言码。
  static String normalize(String raw) {
    final parts = raw.replaceAll('_', '-').toLowerCase().split('-');
    if (parts.first != 'zh') return parts.first;
    return parts.contains('hant') ||
            parts.contains('tw') ||
            parts.contains('hk')
        ? 'zh-TW'
        : 'zh-CN';
  }
}
