import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../settings/service_config.dart';
import '../translation_types.dart';
import '../numbered_batch.dart';
import '../paragraph_translation.dart';

/// 零配置翻译源。单篇翻译按段落分批调用批量接口并独占一个 HTTP 连接；实时翻译的批量请求使用会话传入的连接。
class UnofficialGoogleProvider implements BatchTranslationProvider {
  /// endpoint 为翻译接口 URL，requestTimeout 为单篇与批量请求共用的整次时限（默认 30 秒，#114）；
  /// 构造可取消的 Google Provider。
  UnofficialGoogleProvider({
    this.endpoint = 'https://translate.googleapis.com/translate_a/single',
    this.requestTimeout = const Duration(seconds: 30),
  });

  @override
  final String id = ServiceConfig.builtinId;
  @override
  bool get usesSlidingContext => false;

  /// 该接口按来源地址限流，同一时刻只发一个批次。
  @override
  bool get allowsParallelBatches => false;
  final String endpoint;
  final Duration requestTimeout;

  /// request 包含原文和语言方向；返回可取消的译文、完成或失败事件流。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    // 以原文段落为边界分批翻译，原文与译文的映射不依赖远端句子数量；使用段落批量通用上限（#113）。
    return translateParagraphBatches(
      this,
      request,
      maxItems: batchItemLimit,
      maxChars: batchCharLimit,
    );
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
        q: [for (final text in request.texts) singleLineParagraph(text)]
            .join('\n'),
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
            // 限流（429）按退避重试，服务端错误（5xx）可重试；其余拒绝不会因重试而改变（#118）。
            status == 429
                ? TranslationFailureKind.rateLimited
                : status >= 500
                ? TranslationFailureKind.transient
                : TranslationFailureKind.service,
            retryAfter: parseRetryAfter(response.headers.value('retry-after')),
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
        await run().timeout(requestTimeout);
      } on TimeoutException {
        // 网络挂起时按时限失败，单篇翻译卡片显示超时并可重试（#114）。
        emit(
          const BatchFailure(
            translationTimeoutMessage,
            TranslationFailureKind.transient,
          ),
        );
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
