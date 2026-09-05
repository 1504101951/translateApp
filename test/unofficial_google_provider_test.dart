import 'dart:async';
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
      detectLanguage: (_) async => 'en',
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
            detectedLanguage: 'en',
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
}
