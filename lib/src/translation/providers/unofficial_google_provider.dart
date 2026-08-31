import 'dart:convert';
import 'dart:io';

import '../translation_types.dart';

/// 零配置 Default Translation Provider。可用性不受保证。
class UnofficialGoogleProvider implements TranslationProvider {
  UnofficialGoogleProvider({
    this.httpPost = defaultHttpPost,
    this.endpoint = 'https://translate.googleapis.com/translate_a/single',
  });

  @override
  final String id = 'unofficial-google';

  final Future<({int status, String body})> Function(
    Uri url,
    String body,
    Map<String, String> headers,
  ) httpPost;
  final String endpoint;

  static Future<({int status, String body})> defaultHttpPost(
    Uri url,
    String body,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(url);
      headers.forEach(request.headers.set);
      request.add(utf8.encode(body));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (status: response.statusCode, body: text);
    } finally {
      client.close();
    }
  }

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    try {
      final uri = Uri.parse(endpoint);
      final body = Uri(queryParameters: {
        'client': 'gtx',
        'sl': request.detectedLanguage ?? 'auto',
        'tl': request.targetLanguage,
        'dt': 't',
        'q': request.sourceText,
      }).query;
      final response = await httpPost(uri, body, {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
        'User-Agent': 'Mozilla/5.0',
      });
      if (response.status < 200 || response.status >= 300) {
        yield TranslationFailure(
          'Unofficial Google Provider 请求失败（HTTP ${response.status}）。',
        );
        return;
      }
      final text = parseTranslatedText(response.body);
      yield TranslationUpdate(text);
      yield const TranslationCompleted();
    } on FormatException {
      yield const TranslationFailure(
        'Unofficial Google Provider 返回了无法解析的响应。',
      );
    } catch (_) {
      yield const TranslationFailure('Unofficial Google Provider 请求失败。');
    }
  }

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
