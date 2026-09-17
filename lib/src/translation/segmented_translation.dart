import 'dart:async';

import 'package:characters/characters.dart';

import 'translation_types.dart';

const translationSegmentTarget = 4000;
const translationSegmentMax = 6000;
const slidingContextChars = 1000;

/// source 为完整原文；按约 4000 字分包，为保住段落可到 6000，超长段再按句/硬切。
List<String> splitTranslationSegments(
  String source, {
  int target = translationSegmentTarget,
  int max = translationSegmentMax,
}) {
  if (source.isEmpty) return const [];
  if (source.characters.length <= max) return [source];

  final packed = <String>[];
  final paragraphs = RegExp(r'[^\r\n]+|\r\n|\n|\r').allMatches(source).map((m) => m.group(0)!);
  var buffer = StringBuffer();
  var bufferChars = 0;

  void flush() {
    if (buffer.isEmpty) return;
    packed.add(buffer.toString());
    buffer = StringBuffer();
    bufferChars = 0;
  }

  for (final piece in paragraphs) {
    final pieceChars = piece.characters.length;
    if (piece.trim().isEmpty) {
      buffer.write(piece);
      bufferChars += pieceChars;
      continue;
    }
    if (bufferChars > 0 && bufferChars + pieceChars <= target) {
      buffer.write(piece);
      bufferChars += pieceChars;
      continue;
    }
    if (bufferChars > 0 && bufferChars + pieceChars <= max) {
      buffer.write(piece);
      bufferChars += pieceChars;
      flush();
      continue;
    }
    flush();
    if (pieceChars <= max) {
      buffer.write(piece);
      bufferChars = pieceChars;
      if (bufferChars >= target) flush();
      continue;
    }
    for (final chunk in _splitOversized(piece, max)) {
      packed.add(chunk);
    }
  }
  flush();
  return packed;
}

/// text 超过 max；先按句子再按硬边界切开。
Iterable<String> _splitOversized(String text, int max) sync* {
  final sentences = RegExp(r'.+?(?:[。！？.!?]+|\s+|$)').allMatches(text).map((m) => m.group(0)!);
  var buffer = StringBuffer();
  var chars = 0;
  for (final sentence in sentences) {
    final len = sentence.characters.length;
    if (len > max) {
      if (buffer.isNotEmpty) {
        yield buffer.toString();
        buffer = StringBuffer();
        chars = 0;
      }
      final units = sentence.characters.toList();
      for (var i = 0; i < units.length; i += max) {
        yield units.skip(i).take(max).join();
      }
      continue;
    }
    if (chars + len > max && buffer.isNotEmpty) {
      yield buffer.toString();
      buffer = StringBuffer();
      chars = 0;
    }
    buffer.write(sentence);
    chars += len;
  }
  if (buffer.isNotEmpty) yield buffer.toString();
}

/// translate 为单段服务；request 为整篇请求；usesSlidingContext 为模型后续片带尾部。
/// startIndex 从失败片继续；完整成功才由调用方写历史。
Stream<TranslationEvent> translateSegmented(
  Stream<TranslationEvent> Function(TranslationRequest request) translate,
  TranslationRequest request, {
  bool usesSlidingContext = false,
  int startIndex = 0,
}) {
  StreamIterator<TranslationEvent>? current;
  var cancelled = false;
  late StreamController<TranslationEvent> output;
  output = StreamController<TranslationEvent>(
    onCancel: () {
      cancelled = true;
      return current?.cancel();
    },
    onListen: () async {
      final segments = splitTranslationSegments(request.sourceText);
      if (segments.isEmpty) {
        output.add(const TranslationCompleted());
        await output.close();
        return;
      }
      final pairs = <TranslationPair>[];
      var sourceTail = '';
      var translationTail = '';
      try {
        for (var i = startIndex; i < segments.length; i++) {
          if (cancelled) return;
          final segment = segments[i];
          final sliding = TranslationRequest(
            sourceText: segment,
            detectedLanguage: request.detectedLanguage,
            targetLanguage: request.targetLanguage,
            previousSourceTail: usesSlidingContext && i > 0 ? sourceTail : null,
            previousTranslationTail: usesSlidingContext && i > 0
                ? translationTail
                : null,
          );
          current = StreamIterator(translate(sliding));
          var translated = '';
          var segmentPairs = const <TranslationPair>[];
          while (await current!.moveNext()) {
            if (cancelled) return;
            final event = current!.current;
            switch (event) {
              case TranslationUpdate(:final addition):
                translated += addition;
                output.add(event);
              case TranslationCompleted(:final pairs):
                segmentPairs = pairs;
              case TranslationFailure():
                output.add(event);
                return;
            }
          }
          if (cancelled) return;
          if (segmentPairs.isEmpty) {
            segmentPairs = [TranslationPair(segment, translated)];
          }
          pairs.addAll(segmentPairs);
          sourceTail = _tail(segment);
          translationTail = _tail(translated);
        }
        output.add(TranslationCompleted(pairs: pairs));
      } catch (error, stack) {
        if (!cancelled) output.addError(error, stack);
      } finally {
        await current?.cancel();
        await output.close();
      }
    },
  );
  return output.stream;
}

String _tail(String text) {
  final units = text.characters;
  if (units.length <= slidingContextChars) return text;
  return units.skip(units.length - slidingContextChars).join();
}
