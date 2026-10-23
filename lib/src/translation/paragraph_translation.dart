import 'dart:async';
import 'dart:io';

import '../common/constants/network_limits.dart';
import 'language_direction.dart';
import 'translation_types.dart';

/// translate 处理一次服务请求；request 提供文本与方向；返回可取消的配对译文流。
/// 不同语言时整片作为一次请求，保留模型语义上下文；已是目标语言时按行直通原文，不发请求。
Stream<TranslationEvent> translateParagraphs(
  Stream<TranslationEvent> Function(TranslationRequest request) translate,
  TranslationRequest request,
) {
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
        // 不同语言整片发送；已是目标语言时按行直通，空白行留在分隔符里。
        final pattern = sameLanguage ? r'[^\r\n]+' : r'[\s\S]+';
        for (final match in RegExp(pattern).allMatches(source)) {
          if (cancelled) return;
          final paragraph = match.group(0)!;
          if (paragraph.trim().isEmpty) continue;
          final gap = source.substring(end, match.start);
          if (gap.isNotEmpty) output.add(TranslationUpdate(gap));
          var translated = '';
          var semanticPairs = const <TranslationPair>[];
          var completed = sameLanguage;
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
                  previousSourceTail: request.previousSourceTail,
                  previousTranslationTail: request.previousTranslationTail,
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
                  completed = true;
                  semanticPairs = pairs;
                case TranslationFailure():
                  output.add(event);
                  return;
              }
            }
            if (cancelled) return;
            // 外层分片只接受明确完成的段落；网络断流不能升级为全篇成功。
            if (!completed) {
              output.add(
                const TranslationFailure(incompleteTranslationMessage),
              );
              return;
            }
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

/// provider 为支持批量的服务，request 为一片原文与方向，maxItems/maxChars 为单次批量请求的段落数与字符数上限（maxItems 为空时只按字符数）；
/// 按原文行切成段落，同语言直通，其余按阅读顺序装成批次逐批请求，一次翻译共用一个 HTTP 连接（#113）。
/// 返回按原文顺序的分隔符与译文增量，以及覆盖完整原文的段落配对；任一批失败、或有段落没有译文（段落数对不上）时整片失败。
Stream<TranslationEvent> translateParagraphBatches(
  BatchTranslationProvider provider,
  TranslationRequest request, {
  required int? maxItems,
  required int maxChars,
}) {
  StreamSubscription<BatchTranslationEvent>? current;
  HttpClient? client;
  var cancelled = false;
  late StreamController<TranslationEvent> output;
  output = StreamController<TranslationEvent>(
    onCancel: () {
      cancelled = true;
      // 取消即断开本次连接，未返回的批量请求立即结束。
      client?.close(force: true);
      return current?.cancel();
    },
    onListen: () async {
      final source = request.sourceText;
      final sameLanguage =
          request.detectedLanguage ==
          LanguageDirection.normalize(request.targetLanguage);
      // 普通接口没有对齐信息；以原文行作为段落边界，空白行留在分隔符里。
      final paragraphs = [
        for (final match in RegExp(r'[^\r\n]+').allMatches(source))
          if (match.group(0)!.trim().isNotEmpty) match,
      ];
      final pairs = <TranslationPair>[];
      var end = 0;

      /// index 为段落下标，translation 为其译文；按原文顺序输出前面的分隔符与译文并记下配对，无返回值。
      void publish(int index, String translation) {
        final match = paragraphs[index];
        final gap = source.substring(end, match.start);
        if (gap.isNotEmpty) output.add(TranslationUpdate(gap));
        output.add(TranslationUpdate(translation));
        pairs.add(TranslationPair(gap + match.group(0)!, gap + translation));
        end = match.end;
      }

      try {
        if (sameLanguage) {
          // 已是目标语言时保留原文，不产生网络请求。
          for (final (index, match) in paragraphs.indexed) {
            publish(index, match.group(0)!);
          }
        } else {
          client = HttpClient()
            ..connectionTimeout = NetworkLimits.connectionTimeout;
          var start = 0;
          while (start < paragraphs.length) {
            // 按阅读顺序装满一批：段落数与字符数先到为准，单段超过字符上限时自成一批。
            var stop = start;
            var chars = 0;
            while (stop < paragraphs.length &&
                (maxItems == null || stop - start < maxItems)) {
              final length = paragraphs[stop].group(0)!.length;
              if (stop > start && chars + length > maxChars) break;
              chars += length;
              stop++;
            }
            final texts = [
              for (final match in paragraphs.sublist(start, stop))
                match.group(0)!,
            ];
            final buffers = [for (final _ in texts) StringBuffer()];
            final done = Completer<String?>();

            /// message 为失败原因，null 为整批完成；只记录第一次结果，无返回值。
            void settle(String? message) {
              if (!done.isCompleted) done.complete(message);
            }

            // translateBatch 发出一次批量请求，增量带批次内下标。
            current = provider
                .translateBatch(
                  BatchTranslationRequest(
                    texts: texts,
                    detectedLanguage: request.detectedLanguage,
                    targetLanguage: request.targetLanguage,
                    previousSourceTail: request.previousSourceTail,
                    previousTranslationTail: request.previousTranslationTail,
                  ),
                  client: client!,
                )
                .listen(
                  (event) {
                    switch (event) {
                      case BatchItemUpdate(:final index, :final addition):
                        buffers[index].write(addition);
                      case BatchCompleted():
                        settle(null);
                      case BatchFailure(:final message):
                        settle(message);
                    }
                  },
                  onError: (Object _) => settle('翻译失败，请重试。'),
                  onDone: () => settle(incompleteTranslationMessage),
                );
            final failure = await done.future;
            await current?.cancel();
            current = null;
            if (cancelled) return;
            if (failure != null) {
              output.add(TranslationFailure(failure));
              return;
            }
            // 每段都必须有译文；缺少时说明返回的段落数与原文不一致，整片失败由用户重试。
            if (buffers.any((buffer) => buffer.toString().trim().isEmpty)) {
              output.add(const TranslationFailure('服务返回的段落数与原文不一致，请重试。'));
              return;
            }
            for (final (offset, buffer) in buffers.indexed) {
              publish(start + offset, buffer.toString());
            }
            start = stop;
          }
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
        client?.close(force: true);
        await output.close();
      }
    },
  );
  return output.stream;
}
