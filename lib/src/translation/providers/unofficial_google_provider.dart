import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../translation_types.dart';
import '../paragraph_translation.dart';

/// 零配置翻译源。单篇翻译每个流独占 HTTP 连接；批量翻译使用调用方传入的连接。
class UnofficialGoogleProvider implements BatchTranslationProvider {
  /// endpoint 为翻译接口 URL；构造可取消的 Google Provider。
  UnofficialGoogleProvider({
    this.endpoint = 'https://translate.googleapis.com/translate_a/single',
  });

  @override
  final String id = 'unofficial-google';
  @override
  bool get usesSlidingContext => false;

  /// 该接口按来源地址限流，同一时刻只发一个批次。
  @override
  bool get allowsParallelBatches => false;
  final String endpoint;
  static const _batchTimeout = Duration(seconds: 30);

  /// request 包含原文和语言方向；返回可取消的译文、完成或失败事件流。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    // 以原文段落为边界翻译，原文与译文的映射不依赖远端句子数量。
    return translateParagraphs(_translate, request);
  }

  /// request 为一个段落的原文与方向；返回可取消的 HTTP 翻译结果。
  Stream<TranslationEvent> _translate(TranslationRequest request) {
    late final HttpClient client;
    late final StreamController<TranslationEvent> events;
    events = StreamController<TranslationEvent>(
      onListen: () async {
        client = HttpClient();
        try {
          // _open 写好表单并返回尚未发送的请求。
          final connection = await _open(
            client,
            q: request.sourceText,
            detected: request.detectedLanguage,
            target: request.targetLanguage,
          );
          final response = await connection.close();
          final body = await utf8.decodeStream(response);
          if (events.isClosed) return;
          if (response.statusCode < 200 || response.statusCode >= 300) {
            events.add(
              TranslationFailure(
                'Unofficial Google Provider 请求失败（HTTP ${response.statusCode}）。',
              ),
            );
            return;
          }
          // 消费端共享同一译文事件契约，HTTP 解析不进入会话或界面层。
          events.add(TranslationUpdate(parseTranslatedText(body)));
          events.add(const TranslationCompleted());
        } on FormatException {
          if (!events.isClosed) {
            events.add(
              const TranslationFailure(
                'Unofficial Google Provider 返回了无法解析的响应。',
              ),
            );
          }
        } catch (_) {
          // 取消导致的断连不向已经结束的会话发送失败消息。
          if (!events.isClosed) {
            events.add(
              const TranslationFailure('Unofficial Google Provider 请求失败。'),
            );
          }
        } finally {
          client.close(force: true);
          if (!events.isClosed) await events.close();
        }
      },
      onCancel: () {
        // Stream 的取消直接关闭当前请求，无需另建取消令牌或共享客户端。
        client.close(force: true);
        if (!events.isClosed) unawaited(events.close());
      },
    );
    return events.stream;
  }

  /// request 为一批段落与语言方向，client 为会话持有的连接。
  /// 多个段落以换行拼成一次请求，译文按换行拆回；行数与段落数不一致时全部留作缺失。
  /// 返回带下标的增量及整批完成或失败事件，取消订阅即中止本次请求。
  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    final events = StreamController<BatchTranslationEvent>();
    var active = true;
    HttpClientRequest? pending;

    /// event 为批量事件；取消后不再发布迟到结果，无返回值。
    void emit(BatchTranslationEvent event) {
      if (active && !events.isClosed) events.add(event);
    }

    /// 无参数；执行一次批量请求并发布各段译文。
    Future<void> run() async {
      final connection = await _open(
        client,
        // 一行只放一个段落，换行才能作为段落边界。
        q: [
          for (final text in request.texts)
            text.replaceAll(RegExp(r'[\r\n]+'), ' '),
        ].join('\n'),
        detected: request.detectedLanguage,
        target: request.targetLanguage,
      );
      pending = connection;
      if (!active) return;
      final response = await connection.close();
      final body = await utf8.decodeStream(response);
      if (!active) return;
      final status = response.statusCode;
      if (status < 200 || status >= 300) {
        emit(
          BatchFailure(
            'Unofficial Google Provider 请求失败（HTTP $status）。',
            // 服务端错误（5xx）可重试；限流与其余拒绝不会因重试而改变。
            status >= 500
                ? TranslationFailureKind.transient
                : TranslationFailureKind.service,
          ),
        );
        return;
      }
      final text = parseTranslatedText(body);
      final translations = request.texts.length == 1
          ? [text]
          : text.split('\n');
      if (translations.length == request.texts.length) {
        for (final (index, item) in translations.indexed) {
          emit(BatchItemUpdate(index, item));
        }
      }
      emit(const BatchCompleted());
    }

    events.onListen = () async {
      try {
        await run().timeout(_batchTimeout);
      } on FormatException {
        emit(
          const BatchFailure(
            'Unofficial Google Provider 返回了无法解析的响应。',
            TranslationFailureKind.transient,
          ),
        );
      } catch (_) {
        emit(
          const BatchFailure(
            'Unofficial Google Provider 请求失败。',
            TranslationFailureKind.transient,
          ),
        );
      } finally {
        active = false;
        // 连接由会话持有；这里只中止本次请求。
        pending?.abort();
        await events.close();
      }
    };
    events.onCancel = () {
      active = false;
      pending?.abort();
    };
    return events.stream;
  }

  /// client 为发起请求的连接；q 为原文，多段以换行分隔；detected/target 为语言方向。
  /// 返回已写入表单、尚未发送的请求。
  Future<HttpClientRequest> _open(
    HttpClient client, {
    required String q,
    required String? detected,
    required String target,
  }) async {
    final connection = await client.postUrl(Uri.parse(endpoint));
    connection.headers.set(
      'Content-Type',
      'application/x-www-form-urlencoded;charset=UTF-8',
    );
    connection.headers.set('User-Agent', 'Mozilla/5.0');
    connection.write(
      Uri(
        queryParameters: {
          'client': 'gtx',
          'sl': detected ?? 'auto',
          'tl': target,
          'dt': 't',
          'q': q,
        },
      ).query,
    );
    return connection;
  }

  /// raw 为 Google JSON 响应；返回拼接译文，空白或结构不合法时抛出 FormatException。
  static String parseTranslatedText(String raw) {
    var payload = raw.trim();
    if (payload.startsWith(")]}'")) {
      payload = payload.substring(4);
    }
    final decoded = jsonDecode(payload);
    if (decoded is! List || decoded.isEmpty || decoded.first is! List) {
      throw const FormatException('unreadable');
    }
    final sentences = decoded.first as List;
    final buffer = StringBuffer();
    for (final sentence in sentences) {
      if (sentence is List && sentence.isNotEmpty && sentence.first is String) {
        buffer.write(sentence.first);
      }
    }
    final text = buffer.toString();
    if (text.trim().isEmpty) {
      throw const FormatException('empty');
    }
    return text;
  }
}
