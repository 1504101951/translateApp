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
  if (target <= 0 || max < target) {
    throw ArgumentError('分片目标必须大于0且不超过上限。');
  }
  if (source.isEmpty) return const [];
  if (source.characters.length <= max) return [source];

  final packed = <String>[];
  final paragraphs = RegExp(r'[^\r\n]+|\r\n|\n|\r')
      .allMatches(source)
      .map((m) => m.group(0)!);
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
      // 空白也是原文字符；极长空白不能绕过每片上限。
      if (bufferChars + pieceChars > max) flush();
      if (pieceChars > max) {
        packed.addAll(_splitOversized(piece, max));
        continue;
      }
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
  final sentences = RegExp(r'[\s\S]+?(?:[。！？.!?]+|$)')
      .allMatches(text)
      .map((m) => m.group(0)!);
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

/// 一次整篇翻译的检查点；只提交完整片，失败片的暂存输出不参与恢复。
class TranslationProgress {
  /// request 冻结完整原文与方向；按当前分片规则创建仅属于该请求的检查点。
  TranslationProgress(this.request)
    : segments = splitTranslationSegments(request.sourceText);

  /// 绑定原始请求，防止调用方把检查点用于另一篇文本。
  final TranslationRequest request;
  final List<String> segments;
  final List<TranslationPair> pairs = [];
  int nextIndex = 0;
  String completedText = '';
  String sourceTail = '';
  String translationTail = '';
}

/// translate 为单段服务；request 为整篇请求；usesSlidingContext 为模型后续片带尾部。
/// progress 属于当前请求，保存完整片以供重试；返回有序增量及全篇完成或失败事件。
Stream<TranslationEvent> translateSegmented(
  Stream<TranslationEvent> Function(TranslationRequest request) translate,
  TranslationRequest request, {
  bool usesSlidingContext = false,
  TranslationProgress? progress,
}) {
  final checkpoint = progress ?? TranslationProgress(request);
  if (!identical(checkpoint.request, request)) {
    throw ArgumentError('翻译检查点必须属于同一个请求。');
  }
  StreamIterator<TranslationEvent>? current;
  var cancelled = false;
  late StreamController<TranslationEvent> output;
  output = StreamController<TranslationEvent>(
    onCancel: () {
      cancelled = true;
      return current?.cancel();
    },
    onListen: () async {
      final segments = checkpoint.segments;
      if (segments.isEmpty) {
        output.add(const TranslationCompleted());
        await output.close();
        return;
      }

      try {
        for (var i = checkpoint.nextIndex; i < segments.length; i++) {
          if (cancelled) return;
          final segment = segments[i];
          final sliding = TranslationRequest(
            sourceText: segment,
            detectedLanguage: request.detectedLanguage,
            targetLanguage: request.targetLanguage,
            previousSourceTail: usesSlidingContext && i > 0
                ? checkpoint.sourceTail
                : null,
            previousTranslationTail: usesSlidingContext && i > 0
                ? checkpoint.translationTail
                : null,
          );
          current = StreamIterator(translate(sliding));
          var translated = '';
          // 连接结束不等于业务完成；缺少完成事件时不能把部分译文写入历史。
          var segmentCompleted = false;
          var segmentPairs = const <TranslationPair>[];
          while (await current!.moveNext()) {
            if (cancelled) return;
            final event = current!.current;
            switch (event) {
              case TranslationUpdate(:final addition):
                translated += addition;
                output.add(event);
              case TranslationCompleted(:final pairs):
                segmentCompleted = true;
                segmentPairs = pairs;
              case TranslationFailure():
                output.add(event);
                return;
            }
          }
          if (cancelled) return;
          if (!segmentCompleted) {
            output.add(const TranslationFailure('服务未返回完整译文。'));
            return;
          }
          if (segmentPairs.isEmpty) {
            segmentPairs = [TranslationPair(segment, translated)];
          }
          // 非流式提供方也必须向上层提供可见更新，不能只有完成配对。
          if (translated.isEmpty && segmentPairs.isNotEmpty) {
            translated = segmentPairs.map((pair) => pair.translation).join();
            if (translated.isNotEmpty) {
              output.add(TranslationUpdate(translated));
            }
          }
          // 完整片原子提交；失败/取消时保留前一检查点，重试不会重复追加半片。
          checkpoint.pairs.addAll(segmentPairs);
          checkpoint.completedText += translated;
          checkpoint.sourceTail = _tail(segment);
          checkpoint.translationTail = _tail(translated);
          checkpoint.nextIndex = i + 1;
        }
        output.add(
          TranslationCompleted(pairs: List.unmodifiable(checkpoint.pairs)),
        );
      } catch (error) {
        if (!cancelled) output.add(TranslationFailure('翻译失败：$error'));
      } finally {
        await current?.cancel();
        await output.close();
      }
    },
  );
  return output.stream;
}

/// text 为刚完成的单片；返回至多1000个完整字素，不累计更早片。
String _tail(String text) {
  final units = text.characters;
  if (units.length <= slidingContextChars) return text;
  return units.skip(units.length - slidingContextChars).join();
}
