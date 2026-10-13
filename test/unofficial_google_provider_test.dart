import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/providers/unofficial_google_provider.dart';
import 'package:translate_app/src/translation/translation_types.dart';

void main() {
  test('dismissing a selection closes its in-flight HTTP connection', () async {
    // 本地服务收到请求但不返回响应；关闭会话必须产生真实断连，不能只忽略译文。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final requested = Completer<void>();
    final disconnected = Completer<void>();
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (_) {
          if (!requested.isCompleted) requested.complete();
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    final session = SelectionSession(
      detectLanguage: (_) async => "en",
      provider: UnofficialGoogleProvider(
        endpoint: 'http://127.0.0.1:${server.port}/translate',
      ),
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 's1', text: 'Hello');
    final pending = session.activate();
    // 5 秒是本地连接的失败上限，测试不等待任何外部翻译服务。
    await requested.future.timeout(const Duration(seconds: 5));
    session.dismiss();
    await disconnected.future.timeout(const Duration(seconds: 5));
    await pending;
    expect(session.snapshot.phase, TranslationPhase.idle);
  });

  test('parses single sentence fixture', () {
    const body = r'''[[["你好","Hello",null,null,10]],null,"en"]''';
    expect(UnofficialGoogleProvider.parseTranslatedText(body), '你好');
  });

  test('concatenates multi sentence fixture', () {
    const body =
        r'''[[["第一句。","First.",null,null,3],["第二句。","Second.",null,null,3]],null,"en"]''';
    expect(UnofficialGoogleProvider.parseTranslatedText(body), '第一句。第二句。');
  });

  test('preserves paragraph and line separators in translated sentences', () {
    // 接口句段不是段落；只保留响应自带的分隔符，不能统一 join 换行或删除空行。
    const body =
        r'''[[["第一段。\n\n","First paragraph.\n\n"],["第二段。\n","Second paragraph.\n"],["同段换行。","Line break."]],null,"en"]''';
    expect(
      UnofficialGoogleProvider.parseTranslatedText(body),
      '第一段。\n\n第二段。\n同段换行。',
    );
  });

  test('http error becomes failure without completed', () async {
    // 实际 HTTP 429 是限流边界；验证网络响应到业务失败的转换。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 429;
      request.response.write('rate limit');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final provider = UnofficialGoogleProvider(
      endpoint: 'http://127.0.0.1:${server.port}/translate',
    );
    final events = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Hello',
            detectedLanguage: "en",
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect(events, hasLength(1));
    expect(events.first, isA<TranslationFailure>());
    expect(
      (events.first as TranslationFailure).message.contains('429'),
      isTrue,
    );
  });

  test('unconfigured provider id is unofficial-google', () {
    expect(UnofficialGoogleProvider().id, 'unofficial-google');
  });

  test('批量翻译按换行拆回各段，行数对不上时不给出译文，限流为服务级错误', () async {
    // 作用：多个段落合成一次请求后仍能一一对应。
    // 边界：返回 2 行对 2 段时逐段给出；返回 1 行对 2 段时全部缺失但整批完成；HTTP 429 不可重试。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    var count = 0;
    server.listen((incoming) async {
      final form = Uri.splitQueryString(
        await utf8.decoder.bind(incoming).join(),
      );
      expect(form['q'], 'Hello\nWorld');
      switch (count++) {
        case 0:
          incoming.response.write(
            jsonEncode([
              [
                ['你好\n', 'Hello\n'],
                ['世界', 'World'],
              ],
            ]),
          );
        case 1:
          incoming.response.write(
            jsonEncode([
              [
                ['你好世界', 'Hello World'],
              ],
            ]),
          );
        default:
          incoming.response.statusCode = 429;
      }
      await incoming.response.close();
    });
    final provider = UnofficialGoogleProvider(
      endpoint: 'http://127.0.0.1:${server.port}/translate',
    );
    const batch = BatchTranslationRequest(
      texts: ['Hello', 'World'],
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );
    expect(provider.allowsParallelBatches, isFalse);
    final matched = await provider
        .translateBatch(batch, client: client)
        .toList();
    expect(
      matched.whereType<BatchItemUpdate>().map(
        (event) => (event.index, event.addition),
      ),
      [(0, '你好'), (1, '世界')],
    );
    expect(matched.last, isA<BatchCompleted>());
    final mismatched = await provider
        .translateBatch(batch, client: client)
        .toList();
    expect(mismatched.single, isA<BatchCompleted>());
    final limited = await provider
        .translateBatch(batch, client: client)
        .toList();
    expect(
      (limited.single as BatchFailure).kind,
      TranslationFailureKind.service,
    );
  });
}
