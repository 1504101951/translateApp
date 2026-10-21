import 'language_direction.dart';

/// 术语表中的一条；translation 为空表示保留原文不译，language 为生效的目标语言（#104）。
class GlossaryEntry {
  /// term 为原文术语，translation 为译法（空为保留原文），language 为目标语言码；创建不可变条目。
  const GlossaryEntry({
    required this.term,
    required this.translation,
    required this.language,
  });

  /// map 为偏好字典中的一条；返回术语条目。
  factory GlossaryEntry.fromMap(Map<Object?, Object?> map) => GlossaryEntry(
    term: map['term'] as String,
    translation: map['translation'] as String,
    language: map['language'] as String,
  );

  final String term;
  final String translation;
  final String language;

  /// 拉丁字母与数字；术语首尾为这类字符时，该侧相邻字符不能同类（整词匹配）。
  static final _wordCharacter = RegExp('[A-Za-z0-9]');

  /// 无参数；返回可存入 UserDefaults 的字典。
  Map<String, String> toMap() => {
    'term': term,
    'translation': translation,
    'language': language,
  };

  /// 无参数；返回判断重复的键（术语不区分大小写，目标语言为规范码）。
  (String, String) get key =>
      (term.toLowerCase(), LanguageDirection.normalize(language));

  /// text 为待翻译原文；返回原文是否出现本术语。
  /// 不区分大小写；首尾为拉丁字母或数字的一侧按整词匹配，汉字与符号一侧按子串匹配。
  bool occursIn(String text) {
    final before = _wordCharacter.hasMatch(term[0]) ? '(?<![A-Za-z0-9])' : '';
    final after = _wordCharacter.hasMatch(term[term.length - 1])
        ? '(?![A-Za-z0-9])'
        : '';
    return RegExp(
      '$before${RegExp.escape(term)}$after',
      caseSensitive: false,
    ).hasMatch(text);
  }
}

/// entries 为术语表，texts 为本次请求的全部原文，targetLanguage 为目标语言码。
/// 返回目标语言一致且在原文中出现的术语，结构为 {term, translation}（保留原文时 translation 与 term 相同）；没有命中时为空列表。
List<Map<String, String>> glossaryHits(
  List<GlossaryEntry> entries,
  Iterable<String> texts,
  String targetLanguage,
) {
  final target = LanguageDirection.normalize(targetLanguage);
  return [
    for (final entry in entries)
      if (LanguageDirection.normalize(entry.language) == target &&
          texts.any(entry.occursIn))
        {
          'term': entry.term,
          'translation': entry.translation.isEmpty
              ? entry.term
              : entry.translation,
        },
  ];
}
