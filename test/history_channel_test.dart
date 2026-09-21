import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/main.dart' as app;

/// 无参数；验证截图翻译等待期间，真实主引擎仍能读取历史和持久化记录开关。
void main() {
  testWidgets('截图翻译等待语言识别时，历史分页和关闭记录不等待翻译完成', (tester) async {
    // 设备识别保持未完成；这是网络开始前即可稳定复现的异步边界。
    final detection = Completer<String?>();
    final started = Completer<void>();
    final directory = Directory.systemTemp.createTempSync('history-channel-');
    const methods = MethodChannel(ChannelNames.macos);
    const events = MethodChannel(ChannelNames.macosEvents);
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case MethodNames.loadSettings:
          return <String, Object>{};
        case MethodNames.applicationSupportPath:
          return directory.path;
        case MethodNames.detectLanguage:
          started.complete();
          return detection.future;
        case MethodNames.isCurrentScreenshot:
          return false;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    await app.main();
    await tester.pump();
    final history = tester
        .widget<app.TranslateApp>(find.byType(app.TranslateApp))
        .history;
    addTearDown(() {
      history.database.close();
      directory.deleteSync(recursive: true);
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      methods.setMethodCallHandler(null);
    });

    /// name/arguments 为原生向主引擎发送的请求；返回解码后的真实通道响应。
    Future<Object?> request(
      String name, [
      Map<String, Object> arguments = const {},
    ]) {
      final result = Completer<Object?>();
      unawaited(
        messenger.handlePlatformMessage(
          methods.name,
          codec.encodeMethodCall(MethodCall(name, arguments)),
          (reply) {
            try {
              result.complete(codec.decodeEnvelope(reply!));
            } catch (error, stack) {
              result.completeError(error, stack);
            }
          },
        ),
      );
      return result.future;
    }

    final translating = request(MethodNames.translatePlainText, {
      'text': 'Hello',
      'id': 'closed-shot',
    });
    final cancelled = expectLater(
      translating,
      throwsA(isA<PlatformException>()),
    );
    await started.future;
    await request(MethodNames.setHistoryRecording, {'enabled': false});
    expect(history.recordingEnabled, isFalse);
    expect(await request(MethodNames.historyPage, {'limit': 10}), isEmpty);
    expect(detection.isCompleted, isFalse);
    // 截图已经关闭，释放设备识别后应取消请求，不访问远程服务或新增历史。
    detection.complete('en');
    await cancelled;
    expect(history.page(), isEmpty);
  });
}
