import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/settings/service_config.dart';
import 'package:translate_app/src/translation/language_direction.dart';
import 'package:translate_app/src/translation/providers/api_translation_provider.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 真实本地HTTP失败到恢复的业务路径，不以内部调用次数代替结果。
void main() {
  test('长文失败保留完整片，恢复沿用原服务方向和前片1000字符上下文', () async {
    // 4000+4000超过单片6000，第二次HTTP返回503；长译文验证双尾1000边界。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final inputs = <Map<String, dynamic>>[];
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final input = jsonDecode(
        (body['messages'] as List).last['content'] as String,
      ) as Map<String, dynamic>;
      inputs.add(input);
      if (inputs.length == 2) {
        request.response.statusCode = 503;
        request.response.write('temporarily unavailable');
      } else {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': inputs.length == 1 ? '译' * 1200 : '续译'},
              },
            ],
          })}\n\n',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
            ],
          })}\n\n',
        );
      }
      await request.response.close();
    });
    final provider = ApiTranslationProvider(
      config: ServiceConfig(
        id: 'original',
        kind: 'openai',
        name: 'local',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'test',
      ),
      credentials: () async => {'apiKey': 'local-test'},
    );
    final session = SelectionSession(
      provider: provider,
      detectLanguage: (_) async => 'en',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
    );
    addTearDown(session.dispose);
    final source = '${'A' * 4000}\n${'B' * 4000}';
    session.begin(sessionId: 'resume', text: source);
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.failed);
    expect(session.snapshot.translatedText, '译' * 1200);
    expect(session.canRetry, isTrue);
    session.language = const LanguageDirection(primaryCode: 'ja');
    await session.retry();
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(session.snapshot.translatedText, '${'译' * 1200}\n续译');
    expect(session.snapshot.pairs.map((p) => p.source).join(), source);
    expect(inputs.last['target_language'], 'zh-CN');
    expect(inputs.last['previous_context'], {
      'source_tail': 'A' * 1000,
      'translation_tail': '译' * 1000,
    });
    expect(inputs.last['text'], 'B' * 4000);
    expect(session.canRetry, isFalse);
  });
}
