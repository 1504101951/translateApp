import 'package:translate_app/src/common/constants/selection_gesture_types.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/bridge_event_types.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/selection/selection_translation_app.dart'
    show TranslateApp;
import 'package:translate_app/src/history/translation_history.dart';
import 'package:translate_app/src/platform/macos_platform_bridge.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/language_direction.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 以显式业务事件驱动实际会话；不模拟历史写入。
class _Provider extends TranslationProvider {
  /// id 是服务身份，events 是业务事件流，用于冻结配置和完成边界核验。
  _Provider(this.id, this.events);
  @override
  final String id;
  final Stream<TranslationEvent> events;

  /// request 为真实会话输入；返回测试场景的事件流。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) => events;
}

/// 无参数；通过真实 App 和事件编解码验证最终数据库状态。
void main() {
  testWidgets('选区历史保留来源和激活配置，失败、未完成与关闭不写记录', (tester) async {
    const methods = MethodChannel('test/selection-history/methods');
    const events = EventChannel('test/selection-history/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name),
      (_) async => null,
    );
    final database = sqlite3.openInMemory();
    final history = TranslationHistoryStore(database);
    final detection = Completer<String?>();
    final session = SelectionSession(
      provider: _Provider(
        'original',
        Stream.fromIterable([
          const TranslationUpdate('Hello'),
          const TranslationCompleted(),
        ]),
      ),
      detectLanguage: (_) => detection.future,
      language: const LanguageDirection(
        primaryCode: 'zh-CN',
        secondaryCode: 'en',
      ),
    );
    addTearDown(() {
      session.dispose();
      database.close();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
    });
    await tester.pumpWidget(
      TranslateApp(
        bridge: MacosPlatformBridge(methods: methods, events: events),
        session: session,
        history: history,
      ),
    );
    await tester.pump();

    /// payload 为原生选区/关闭事件；刷新 App 后返回，不检查内部方法调用。
    Future<void> send(Map<String, Object> payload) async {
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope(payload),
        (_) {},
      );
      await tester.pump();
    }

    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'success',
      'gesture': SelectionGestureTypes.hotkey,
      'text': '你好',
      'sourceAppName': 'Safari',
    });
    expect(session.snapshot.phase, TranslationPhase.translating);
    // 检测期间修改设置，结果仍须记录激活时的服务及次要目标语言。
    session.provider = _Provider('changed', const Stream.empty());
    session.language = const LanguageDirection(primaryCode: 'fr');
    detection.complete('zh-Hans');
    await tester.pumpAndSettle();
    expect(
      session.snapshot.phase,
      TranslationPhase.completed,
      reason: session.snapshot.message,
    );
    expect(history.page(), hasLength(1));
    final row = history.page().single;
    expect(row.sourceLabel, 'Safari');
    expect(row.targetLanguage, 'en');
    expect(row.providerId, 'original');
    expect(row.translatedText, 'Hello');
    for (final ending in ['failed', 'incomplete', 'cancelled']) {
      // 只发送增量后失败、断流或关闭，均不构成完整成功的第二条记录。
      final stream = StreamController<TranslationEvent>();
      session.provider = _Provider(ending, stream.stream);
      await send({
        'type': BridgeEventTypes.selectionCaptured,
        'sessionId': ending,
        'gesture': SelectionGestureTypes.hotkey,
        'text': 'Other',
        'sourceAppName': 'Notes',
      });
      stream.add(const TranslationUpdate('部分'));
      if (ending == 'failed') stream.add(const TranslationFailure('翻译失败'));
      if (ending == 'cancelled') {
        await send({'type': MethodNames.escapePressed, 'sessionId': ending});
      }
      // 关闭事件需由 Flutter 的测试队列投递；先安排关闭，再推进队列。
      unawaited(stream.close());
      await tester.pumpAndSettle();
      expect(
        session.snapshot.phase,
        ending == 'cancelled' ? TranslationPhase.idle : TranslationPhase.failed,
      );
      expect(history.page(), hasLength(1));
    }
    expect(tester.takeException(), isNull);
  });
}
