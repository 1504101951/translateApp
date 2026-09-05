import 'dart:convert';

import 'translation_types.dart';

/// text 为模型完整输出，source 为本地原文；返回完整译文及通过覆盖校验的对照段落。
({String translation, List<TranslationPair> pairs}) parseModelResult(
  String text,
  String source,
) {
  var raw = text.trim();
  // Markdown 围栏是模型常见格式包装；只移除包住整个响应的一层围栏。
  if (raw.startsWith('```') && raw.endsWith('```')) {
    final newline = raw.indexOf('\n');
    if (newline >= 0) raw = raw.substring(newline + 1, raw.length - 3).trim();
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    if (raw.startsWith('{') || raw.startsWith('[') || raw.isEmpty) {
      throw const FormatException('模型返回的结构不完整，请重新翻译。');
    }
    return (translation: raw, pairs: const []);
  }
  if (decoded is! Map ||
      decoded['translation'] is! String ||
      (decoded['translation'] as String).trim().isEmpty) {
    throw const FormatException('模型未返回完整译文。');
  }
  final translation = decoded['translation'] as String;
  final segments = decoded['segments'];
  if (segments is! List || segments.isEmpty) {
    return (translation: translation, pairs: const []);
  }
  var cursor = 0;
  final pairs = <TranslationPair>[];
  for (final segment in segments) {
    if (segment is! Map ||
        segment['source'] is! String ||
        segment['translation'] is! String) {
      return (translation: translation, pairs: const []);
    }
    final original = segment['source'] as String;
    final translated = segment['translation'] as String;
    if (original.trim().isEmpty || translated.trim().isEmpty) {
      return (translation: translation, pairs: const []);
    }
    final position = source.indexOf(original, cursor);
    if (position < cursor ||
        source.substring(cursor, position).trim().isNotEmpty) {
      return (translation: translation, pairs: const []);
    }
    final end = position + original.length;
    // 展示源文切片来自本地；只有空白间隙可归入下一段，不允许模型改写或漏掉源文。
    pairs.add(TranslationPair(source.substring(cursor, end), translated));
    cursor = end;
  }
  if (source.substring(cursor).trim().isNotEmpty) {
    return (translation: translation, pairs: const []);
  }
  if (cursor < source.length) {
    final last = pairs.removeLast();
    pairs.add(
      TranslationPair(last.source + source.substring(cursor), last.translation),
    );
  }
  return (translation: translation, pairs: pairs);
}
