import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/service_config.dart';
import 'package:translate_app/src/translation/model_result.dart';
import 'package:translate_app/src/translation/providers/api_translation_provider.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 无参数；用真实本地 HTTP 验证协议、流完整性及取消，不调用付费服务。
void main() {
  const request = TranslationRequest(
    sourceText: 'Hello 世界 & +',
    detectedLanguage: 'en',
    targetLanguage: 'zh-CN',
  );
  const secrets = {'apiKey': 'test-secret', 'appId': 'test-app'};

  /// kind 指定协议，server 为真实监听端，semantic 控制结构化结果；返回测试 Provider。
  ApiTranslationProvider provider(
    String kind,
    HttpServer server, {
    bool semantic = false,
  }) => ApiTranslationProvider(
    config: ServiceConfig(
      id: 'test',
      kind: kind,
      name: 'Test',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'test-model',
      semanticPairs: semantic,
    ),
    credentials: () async => secrets,
  );

  test('百度表单正确编码原文与签名，Google 解码文本实体且携带 API 凭据', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        final body = await utf8.decoder.bind(incoming).join();
        if (count++ == 0) {
          expect(incoming.method, 'POST');
          expect(incoming.uri.path, '/api/trans/vip/translate');
          final fields = Uri.splitQueryString(body);
          expect(fields['q'], request.sourceText);
          expect(fields['to'], 'zh');
          expect(
            fields['sign'],
            md5
                .convert(
                  utf8.encode(
                    '${secrets['appId']}${request.sourceText}${fields['salt']}${secrets['apiKey']}',
                  ),
                )
                .toString(),
          );
          incoming.response.write(
            jsonEncode({
              'trans_result': [
                {'src': request.sourceText, 'dst': '你好，世界'},
              ],
            }),
          );
        } else {
          expect(incoming.uri.path, '/language/translate/v2');
          expect(incoming.headers.value('x-goog-api-key'), secrets['apiKey']);
          expect(jsonDecode(body), {
            'q': request.sourceText,
            'target': 'zh-CN',
            'source': 'en',
            'format': 'text',
          });
          incoming.response.write(
            jsonEncode({
              'data': {
                'translations': [
                  {'translatedText': '你好 &amp; &#x4E16;&#30028; &amp;lt;'},
                ],
              },
            }),
          );
        }
        await incoming.response.close();
        if (count == 2) break;
      }
    }();
    final baidu = await provider('baidu', server).translate(request).toList();
    expect((baidu.first as TranslationUpdate).addition, '你好，世界');
    expect(baidu.last, isA<TranslationCompleted>());
    final google = await provider('google', server).translate(request).toList();
    expect((google.first as TranslationUpdate).addition, '你好 & 世界 &lt;');
    expect(google.last, isA<TranslationCompleted>());
    await serving;
  });

  test('两种模型协议保留 Unicode 增量，按 SSE 事件边界读取多行 data', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        final body =
            jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
        expect(body['model'], 'test-model');
        expect(body['stream'], true);
        incoming.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        if (count++ == 0) {
          expect(incoming.uri.path, '/chat/completions');
          expect(incoming.headers.value('authorization'), 'Bearer test-secret');
          expect(
            jsonDecode(body['messages'][1]['content'])['text'],
            request.sourceText,
          );
          incoming.response.write(
            'data: {"choices":\ndata: [{"index":0,"delta":{"content":"你好🌍"},"finish_reason":null}]}\n\n',
          );
          await incoming.response.flush();
          incoming.response.write(
            'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
        } else {
          expect(incoming.uri.path, '/messages');
          expect(incoming.headers.value('x-api-key'), 'test-secret');
          expect(incoming.headers.value('anthropic-version'), '2023-06-01');
          expect(body['max_tokens'], 4096);
          incoming.response.write(
            'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好🌍"}}\n\n',
          );
          incoming.response.write(
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\ndata: {"type":"message_stop"}\n\n',
          );
        }
        await incoming.response.close();
        if (count == 2) break;
      }
    }();
    for (final kind in ['openai', 'anthropic']) {
      final events = await provider(kind, server).translate(request).toList();
      expect(
        events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
        '你好🌍',
      );
      expect(events.last, isA<TranslationCompleted>());
    }
    await serving;
  });

  test('截断、缺少完成标记和响应错误都不被标记完成，也不回显服务正文', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const cases = [
      (
        'openai',
        'data: {"choices":[{"index":0,"delta":{"content":"部分"},"finish_reason":"length"}]}\n\n',
      ),
      (
        'openai',
        'data: {"choices":[{"index":0,"delta":{"content":"部分"}}]}\n\ndata: [DONE]\n\n',
      ),
      (
        'anthropic',
        'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}\n\ndata: {"type":"message_stop"}\n\n',
      ),
      (
        'openai',
        'data: {"error":{"message":"test-secret sensitive source"}}\n\n',
      ),
    ];
    final serving = () async {
      var index = 0;
      await for (final incoming in server) {
        await incoming.drain<void>();
        incoming.response.write(cases[index++].$2);
        await incoming.response.close();
        if (index == cases.length) break;
      }
    }();
    for (final item in cases) {
      final events = await provider(
        item.$1,
        server,
      ).translate(request).toList();
      expect(events.whereType<TranslationCompleted>(), isEmpty);
      expect(events.last, isA<TranslationFailure>());
      expect(
        (events.last as TranslationFailure).message,
        isNot(contains('test-secret')),
      );
    }
    await serving;
  });

  test('取消订阅关闭真实 socket，凭据未读完时取消不发出请求', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final connected = Completer<Socket>();
    final disconnected = Completer<void>();
    server.listen((socket) {
      connected.complete(socket);
      socket.listen(
        (_) {},
        onDone: () {
          disconnected.complete();
          socket.destroy();
        },
      );
    });
    final config = ServiceConfig(
      id: 'cancel',
      kind: 'openai',
      name: 'Test',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'test-model',
    );
    final active = ApiTranslationProvider(
      config: config,
      credentials: () async => secrets,
    );
    final events = <TranslationEvent>[];
    final subscription = active.translate(request).listen(events.add);
    await connected.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    await disconnected.future.timeout(const Duration(seconds: 5));
    expect(events, isEmpty);
    final secret = Completer<Map<String, String>>();
    final pending = ApiTranslationProvider(
      config: config,
      credentials: () => secret.future,
    ).translate(request).listen(events.add);
    await pending.cancel();
    secret.complete(secrets);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
  });

  test('模型对照仅接受顺序完整覆盖，保留本地原文及完整译文', () {
    const source = '  Hello.\n\n世界🌍!  ';
    const full = '你好。\n世界！';
    final parsed = parseModelResult(
      jsonEncode({
        'translation': full,
        'segments': [
          {'source': 'Hello.', 'translation': '你好。'},
          {'source': '世界🌍!', 'translation': '世界！'},
        ],
      }),
      source,
    );
    expect(parsed.translation, full);
    expect(parsed.pairs.map((e) => e.source).join(), source);
    expect(parsed.pairs, hasLength(2));
    // 漏段、乱序、虚构原文、空译文均只能降为完整对照，不能展示错误配对。
    for (final segments in [
      [
        {'source': 'Hello.', 'translation': '你好'},
      ],
      [
        {'source': '世界🌍!', 'translation': '世界'},
        {'source': 'Hello.', 'translation': '你好'},
      ],
      [
        {'source': '$source invented', 'translation': '错误'},
      ],
      [
        {'source': source, 'translation': ''},
      ],
    ]) {
      final fallback = parseModelResult(
        jsonEncode({'translation': full, 'segments': segments}),
        source,
      );
      expect(fallback.translation, full);
      expect(fallback.pairs, isEmpty);
    }
    expect(parseModelResult('普通译文', source).translation, '普通译文');
    expect(
      () => parseModelResult('{"translation":"截断', source),
      throwsFormatException,
    );
  });

  test('语义模式不流出 JSON，完成后一次发布校验过的段落', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = () async {
      final incoming = await server.first;
      await incoming.drain<void>();
      final content = jsonEncode({
        'translation': '你好',
        'segments': [
          {'source': request.sourceText, 'translation': '你好'},
        ],
      });
      incoming.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'content': content},
              'finish_reason': 'stop',
            },
          ],
        })}\n\n',
      );
      await incoming.response.close();
    }();
    final events = await provider(
      'openai',
      server,
      semantic: true,
    ).translate(request).toList();
    expect(events.whereType<TranslationUpdate>().single.addition, '你好');
    expect(
      (events.last as TranslationCompleted).pairs.single.source,
      request.sourceText,
    );
    await serving;
  });
}
