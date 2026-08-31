/// #2 最小闭环用的本地方向：按 Unicode 粗判来源，再落到主要/次要语言。
/// 可编辑语言设置属于 #4。
class LanguageDirection {
  const LanguageDirection({
    required this.primaryCode,
    required this.secondaryCode,
  });

  final String primaryCode;
  final String secondaryCode;

  factory LanguageDirection.systemDefault({String? languageCode}) {
    final primary = _normalize(languageCode ?? 'en');
    final secondary = primary == 'en' ? 'zh-CN' : 'en';
    return LanguageDirection(primaryCode: primary, secondaryCode: secondary);
  }

  ({String? detectedLanguage, String targetLanguage}) resolve(String text) {
    final detected = detect(text);
    if (detected != null && _same(detected, primaryCode)) {
      return (detectedLanguage: detected, targetLanguage: secondaryCode);
    }
    return (detectedLanguage: detected, targetLanguage: primaryCode);
  }

  static String? detect(String text) {
    final han = RegExp(r'\p{Script=Han}', unicode: true);
    final latin = RegExp(r'\p{Script=Latin}', unicode: true);
    var hanCount = 0;
    var latinCount = 0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (han.hasMatch(ch)) hanCount += 1;
      if (latin.hasMatch(ch)) latinCount += 1;
    }
    if (hanCount == 0 && latinCount == 0) return null;
    return hanCount >= latinCount ? 'zh-CN' : 'en';
  }

  static String _normalize(String raw) {
    final parts = raw.replaceAll('_', '-').split('-');
    if (parts.isEmpty) return raw;
    final first = parts.first.toLowerCase();
    if (first == 'zh') {
      final rest = parts.skip(1).join('-').toLowerCase();
      if (rest.contains('hant') || rest == 'tw' || rest == 'hk') {
        return 'zh-TW';
      }
      return 'zh-CN';
    }
    return first;
  }

  static bool _same(String a, String b) => _normalize(a) == _normalize(b);
}
