import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../translation_types.dart';

/// 零配置翻译源；每个流独占 HTTP 连接，取消订阅即中止网络请求。
class UnofficialGoogleProvider implements TranslationProvider {
  /// endpoint 为翻译接口 URL；构造可取消的 Google Provider。
  UnofficialGoogleProvider({
    this.endpoint = 'https://translate.googleapis.com/translate_a/single',
  });

  @override
  final String id = 'unofficial-google';
  final String endpoint;

  /// request 包含原文和语言方向；返回可取消的译文、完成或失败事件流。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    late final HttpClient client;
    late final StreamController<TranslationEvent> events;
    events = StreamController<TranslationEvent>(
      onListen: () async {
        client = HttpClient();
        try {
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
                'sl': request.detectedLanguage ?? 'auto',
                'tl': request.targetLanguage,
                'dt': 't',
                'q': request.sourceText,
              },
            ).query,
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
