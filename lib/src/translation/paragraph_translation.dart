import 'dart:async';

import 'language_direction.dart';
import 'translation_types.dart';

/// translate 处理一次服务请求；request 提供文本与方向，keepWholeSource 保留模型语义上下文；返回可取消的配对译文流。
Stream<TranslationEvent> translateParagraphs(
  Stream<TranslationEvent> Function(TranslationRequest request) translate,
  TranslationRequest request, {
  bool keepWholeSource = false,
}) {
  StreamIterator<TranslationEvent>? current;
  var cancelled = false;
  late StreamController<TranslationEvent> output;
  output = StreamController<TranslationEvent>(
    onCancel: () {
      cancelled = true;
      // 显式取消迭代器，连首个响应尚未到达的 HTTP 请求也能立即结束。
      return current?.cancel();
    },
    onListen: () async {
      final source = request.sourceText;
      final pairs = <TranslationPair>[];
      final sameLanguage =
          request.detectedLanguage ==
          LanguageDirection.normalize(request.targetLanguage);
      var end = 0;
      try {
        // 普通接口没有对齐信息；以原文段落作为请求边界，不按译文句数猜配对。
        final pattern = keepWholeSource && !sameLanguage
            ? r'[\s\S]+'
            : r'[^\r\n]+';
        for (final match in RegExp(pattern).allMatches(source)) {
          if (cancelled) return;
          final paragraph = match.group(0)!;
          if (paragraph.trim().isEmpty) continue;
          final gap = source.substring(end, match.start);
          if (gap.isNotEmpty) output.add(TranslationUpdate(gap));
          var translated = '';
          var semanticPairs = const <TranslationPair>[];
          if (sameLanguage) {
            // 已是目标语言时保留原文，避免未设置次要语言仍产生无意义的 API 请求。
            translated = paragraph;
            output.add(TranslationUpdate(paragraph));
          } else {
            // Provider 负责网络和模型配对校验；当前迭代器也负责传播消费者的取消。
            current = StreamIterator(
              translate(
                TranslationRequest(
                  sourceText: paragraph,
                  detectedLanguage: request.detectedLanguage,
                  targetLanguage: request.targetLanguage,
                ),
              ),
            );
            while (await current!.moveNext()) {
              if (cancelled) return;
              final event = current!.current;
              switch (event) {
                case TranslationUpdate(:final addition):
                  translated += addition;
                  output.add(event);
                case TranslationCompleted(:final pairs):
                  semanticPairs = pairs;
                case TranslationFailure():
                  output.add(event);
                  return;
              }
            }
            if (cancelled) return;
          }
          final paragraphPairs = semanticPairs.isEmpty
              ? [TranslationPair(paragraph, translated)]
              : semanticPairs;
          // 分隔符属于展示和复制内容；合并所有配对后仍须覆盖完整原文。
          final first = paragraphPairs.first;
          pairs.add(
            TranslationPair(gap + first.source, gap + first.translation),
          );
          pairs.addAll(paragraphPairs.skip(1));
          end = match.end;
        }
        final tail = source.substring(end);
        if (tail.isNotEmpty) {
          output.add(TranslationUpdate(tail));
          if (pairs.isNotEmpty) {
            final last = pairs.removeLast();
            pairs.add(
              TranslationPair(last.source + tail, last.translation + tail),
            );
          }
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
