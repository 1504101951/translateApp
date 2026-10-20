import 'dart:convert';

import 'translation_types.dart';

/// source 为本地原文；返回按非空行划分的段落，合并后完整保留原文和分隔空白。
List<String> modelSourceParagraphs(String source) {
  final paragraphs = <String>[];
  var end = 0;
  for (final match in RegExp(r'\S[^\r\n]*').allMatches(source)) {
    paragraphs.add(source.substring(end, match.end));
    end = match.end;
  }
  if (paragraphs.isNotEmpty) {
    paragraphs[paragraphs.length - 1] += source.substring(end);
  }
  return paragraphs;
}

/// text 为模型 JSON，source 为本地原文；校验编号完整且有序后返回整篇译文与段落配对。
({String translation, List<TranslationPair> pairs}) parseModelResult(
  String text,
  String source,
) {
  var raw = text.trim();
  if (raw.startsWith('```') && raw.endsWith('```')) {
    final newline = raw.indexOf('\n');
    if (newline >= 0) raw = raw.substring(newline + 1, raw.length - 3).trim();
  }
  final decoded = jsonDecode(raw);
  final paragraphs = modelSourceParagraphs(source);
  final segments = decoded is Map ? decoded['segments'] : null;
  if (paragraphs.isEmpty ||
      segments is! List ||
      segments.length != paragraphs.length) {
    throw const FormatException('模型未返回完整的逐段译文，请重试。');
  }
  final pairs = <TranslationPair>[];
  for (var index = 0; index < paragraphs.length; index++) {
    final segment = segments[index];
    if (segment is! Map ||
        segment['id'] is! int ||
        segment['id'] != index ||
        segment['translation'] is! String ||
        (segment['translation'] as String).trim().isEmpty) {
      throw const FormatException('模型段落编号缺失、重复或顺序错误，请重试。');
    }
    // pairParagraph 由本地原文保留分隔符；模型只决定这一段的译文。
    pairs.add(
      pairParagraph(paragraphs[index], segment['translation'] as String),
    );
  }
  return (
    translation: pairs.map((pair) => pair.translation).join(),
    pairs: pairs,
  );
}

/// original 为 modelSourceParagraphs 切出的本地段落（含前后分隔空白），translation 为该段译文。
/// 返回把原段首尾空白套在去空白译文外侧的配对，保证拼接后的译文保留原文分隔。
TranslationPair pairParagraph(String original, String translation) {
  final prefix = RegExp(r'^\s*').stringMatch(original)!;
  final suffix = RegExp(r'\s*$').stringMatch(original)!;
  return TranslationPair(original, prefix + translation.trim() + suffix);
}
