import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/text_mode.dart';
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

  test('模型段落编号必须完整有序，原文及分隔空白只取本地内容', () {
    // 多段、空行、缩进及尾部空白必须原样保留；缺段不能降为整篇高亮。
    const source = ' Hello.\r\n\r\n世界🌍! \n';
    final parsed = parseModelResult(
      jsonEncode({
        'segments': [
          {'id': 0, 'translation': '你好。'},
          {'id': 1, 'translation': '世界！'},
        ],
      }),
      source,
    );
    expect(parsed.translation, ' 你好。\r\n\r\n世界！ \n');
    expect(parsed.pairs.map((e) => e.source).join(), source);
    expect(parsed.pairs, hasLength(2));
    for (final segments in [
      [
        {'id': 0, 'translation': '整篇'},
      ],
      [
        {'id': 1, 'translation': '世界'},
        {'id': 0, 'translation': '你好'},
      ],
      [
        {'id': 0, 'translation': '你好'},
        {'id': 0, 'translation': '世界'},
      ],
      [
        {'id': 0, 'translation': '你好'},
        {'id': '1', 'translation': '世界'},
      ],
      [
        {'id': 0, 'translation': '你好'},
        {'id': 1, 'translation': ' '},
      ],
    ]) {
      expect(
        () => parseModelResult(jsonEncode({'segments': segments}), source),
        throwsFormatException,
      );
    }
    expect(() => parseModelResult('普通译文', source), throwsFormatException);
    expect(
      () => parseModelResult('{"segments":[', source),
      throwsFormatException,
    );
  });

  test('润色模式使用内置提示词整段发送纯文本，忽略段落对照，原文与目标同语言也发出请求', () async {
    // 边界：服务开启了按段落双语对照、原文与目标语言都是英文；润色仍须整段请求并接受纯文本结果。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const source = 'helo world.\n\nsecond line';
    final serving = () async {
      final incoming = await server.first;
      final body = jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
      final system = body['messages'][0]['content'] as String;
      expect(system, contains('润色'));
      expect(system, isNot(contains(ServiceConfig.defaultPrompt)));
      expect(body.containsKey('response_format'), isFalse);
      final input = jsonDecode(body['messages'][1]['content'] as String) as Map;
      expect(input['text'], source);
      expect(input.containsKey('paragraphs'), isFalse);
      incoming.response.write(
        'data: {"choices":[{"index":0,"delta":{"content":"Hello world.\\n\\nSecond line."},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      );
      await incoming.response.close();
    }();
    final events =
        await ApiTranslationProvider(
              config: ServiceConfig(
                id: 'test',
                kind: 'openai',
                name: 'Test',
                baseUrl: 'http://127.0.0.1:${server.port}',
                model: 'test-model',
                semanticPairs: true,
              ),
              credentials: () async => secrets,
              mode: TextMode.polish,
            )
            .translate(
              const TranslationRequest(
                sourceText: source,
                detectedLanguage: 'en',
                targetLanguage: 'en',
              ),
            )
            .toList();
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      'Hello world.\n\nSecond line.',
    );
    expect(events.last, isA<TranslationCompleted>());
    await serving;
  });

  test('DeepSeek 禁用思考并按输入编号返回完整对照，不显示协议 JSON', () async {
    // 本地真实 HTTP 同时验证协议输入和两段译文输出，无需账户或付费调用。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const source = 'First.\n\nSecond.';
    final serving = () async {
      final incoming = await server.first;
      final body = jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
      expect(incoming.uri.path, '/chat/completions');
      expect(body['thinking'], {'type': 'disabled'});
      expect(body['response_format'], {'type': 'json_object'});
      final input = jsonDecode(body['messages'][1]['content'] as String) as Map;
      expect(input['paragraphs'], [
        {'id': 0, 'text': 'First.'},
        {'id': 1, 'text': '\n\nSecond.'},
      ]);
      final content = jsonEncode({
        'segments': [
          {'id': 0, 'translation': '第一段。'},
          {'id': 1, 'translation': '第二段。'},
        ],
      });
      incoming.response.write(
        'data: {"choices":[{"index":0,"delta":{"reasoning_content":"internal"},"finish_reason":null}]}\n\n',
      );
      incoming.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'content': content},
              'finish_reason': 'stop',
            },
          ],
        })}\n\ndata: [DONE]\n\n',
      );
      await incoming.response.close();
    }();
    final events = await provider('deepseek', server, semantic: true)
        .translate(
          const TranslationRequest(
            sourceText: source,
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect(
      events.whereType<TranslationUpdate>().single.addition,
      '第一段。\n\n第二段。',
    );
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(pairs.map((pair) => pair.source).join(), source);
    expect(pairs.map((pair) => pair.translation), ['第一段。', '\n\n第二段。']);
    await serving;
  });

  /// events 为一次批量翻译的全部事件；返回各下标累计的译文。
  Map<int, String> batchItems(List<BatchTranslationEvent> events) {
    final items = <int, String>{};
    for (final event in events.whereType<BatchItemUpdate>()) {
      items[event.index] = (items[event.index] ?? '') + event.addition;
    }
    return items;
  }

  const batch = BatchTranslationRequest(
    texts: ['Hello', 'World'],
    detectedLanguage: 'en',
    targetLanguage: 'zh-CN',
  );

  test('批量翻译：模型按编号流式归属到段落，Google 一次请求携带多个原文', () async {
    // 作用：一批段落只发一次请求，译文按批次内下标返回。
    // 边界：模型先输出 [2] 再输出 [1]，且 [1] 的译文跨两个流式事件；Google 的实体只解码一次。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        final body =
            jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
        if (count++ == 0) {
          expect(incoming.uri.path, '/chat/completions');
          expect(
            jsonDecode(body['messages'][1]['content'])['paragraphs'],
            '[1] Hello\n[2] World',
          );
          incoming.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          for (final content in [r'[2] 世界\n[1] 你', '好']) {
            incoming.response.write(
              'data: {"choices":[{"index":0,"delta":{"content":"$content"},"finish_reason":null}]}\n\n',
            );
            await incoming.response.flush();
          }
          incoming.response.write(
            'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
        } else {
          expect(incoming.uri.path, '/language/translate/v2');
          expect(body['q'], ['Hello', 'World']);
          incoming.response.headers.contentType = ContentType.json;
          incoming.response.write(
            '{"data":{"translations":[{"translatedText":"你好"},{"translatedText":"A &amp;amp; B"}]}}',
          );
        }
        await incoming.response.close();
        if (count == 2) break;
      }
    }();
    final model = await provider(
      'openai',
      server,
    ).translateBatch(batch, client: client).toList();
    expect(batchItems(model), {0: '你好', 1: '世界'});
    expect(model.last, isA<BatchCompleted>());
    final google = await provider(
      'google',
      server,
    ).translateBatch(batch, client: client).toList();
    expect(batchItems(google), {0: '你好', 1: 'A &amp; B'});
    expect(google.last, isA<BatchCompleted>());
    await serving;
  });

  test('批量失败带错误类别：认证与限流为服务级，服务端错误为临时，输出截断为段落级', () async {
    // 作用：会话依据类别决定停止发送、放弃该段或重试。
    // 边界：499 仍为服务级，500 起为临时错误；finish_reason 为 length 时为段落级。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    const statuses = [401, 429, 499, 500];
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        await incoming.drain<void>();
        if (count < statuses.length) {
          incoming.response.statusCode = statuses[count];
          incoming.response.write('secret upstream body');
        } else {
          incoming.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          incoming.response.write(
            'data: {"choices":[{"index":0,"delta":{"content":"[1] 你"},"finish_reason":"length"}]}\n\n',
          );
        }
        await incoming.response.close();
        if (++count == statuses.length + 1) break;
      }
    }();
    final kinds = <TranslationFailureKind>[];
    for (var i = 0; i < statuses.length + 1; i++) {
      final events = await provider(
        'openai',
        server,
      ).translateBatch(batch, client: client).toList();
      final failure = events.last as BatchFailure;
      expect(failure.message.contains('secret upstream body'), isFalse);
      expect(events.whereType<BatchCompleted>(), isEmpty);
      kinds.add(failure.kind);
    }
    expect(kinds, [
      TranslationFailureKind.service,
      TranslationFailureKind.service,
      TranslationFailureKind.service,
      TranslationFailureKind.transient,
      TranslationFailureKind.paragraph,
    ]);
    await serving;
  });
}
