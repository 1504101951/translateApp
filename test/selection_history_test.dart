import 'package:translate_app/src/common/constants/selection_gesture_types.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/bridge_event_types.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/common/constants/text_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/selection/selection_translation_app.dart'
    show TranslateApp;
import 'package:translate_app/src/history/translation_history.dart';
import 'package:translate_app/src/history/vocabulary.dart';
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
        vocabulary: VocabularyStore(database),
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
      'x': 0,
      'y': 0,
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
        'x': 0,
        'y': 0,
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

  testWidgets('输入翻译完整成功后替换原文并关闭卡片，替换被拒时保留译文卡片', (tester) async {
    const methods = MethodChannel('test/input-translation/methods');
    const events = EventChannel('test/input-translation/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 原生是否接受替换：模拟来源仍在前台（true）与已切换应用或安全输入（false）两种边界。
    var replaceAccepted = true;
    messenger.setMockMethodCallHandler(
      methods,
      (call) async =>
          call.method == MethodNames.replaceSelection ? replaceAccepted : null,
    );
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name),
      (_) async => null,
    );
    final database = sqlite3.openInMemory();
    final history = TranslationHistoryStore(database);
    final session = SelectionSession(
      provider: _Provider(
        'input',
        Stream.fromIterable([
          const TranslationUpdate('Hello'),
          const TranslationCompleted(),
        ]),
      ),
      detectLanguage: (_) async => 'zh-Hans',
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
        vocabulary: VocabularyStore(database),
      ),
    );
    await tester.pump();

    /// sessionId 标识本次输入翻译；发送输入翻译快捷键的选区事件并等待翻译与替换结束。
    Future<void> sendInput(String sessionId) async {
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope({
          'type': BridgeEventTypes.selectionCaptured,
          'sessionId': sessionId,
          'gesture': SelectionGestureTypes.inputHotkey,
          'text': '你好',
          'sourceAppName': 'Notes',
          'x': 0,
          'y': 0,
        }),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await sendInput('replaced');
    // 替换成功：卡片关闭，翻译仍记入历史。
    expect(session.snapshot.phase, TranslationPhase.idle);
    expect(history.page(), hasLength(1));

    replaceAccepted = false;
    await sendInput('kept');
    // 替换被拒：卡片保留完整译文，用户仍可手动复制。
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(session.snapshot.translatedText, 'Hello');
    expect(history.page(), hasLength(2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('卡片切换为润色只显示结果不写历史，切回翻译成功后再记录一条', (tester) async {
    const methods = MethodChannel('test/mode-history/methods');
    const events = EventChannel('test/mode-history/events');
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
    final session =
        SelectionSession(
            provider: _Provider(
              'translate',
              Stream.fromIterable([
                const TranslationUpdate('你好'),
                const TranslationCompleted(),
              ]),
            ),
            detectLanguage: (_) async => 'en',
            language: const LanguageDirection(primaryCode: 'zh-CN'),
          )
          ..assistProviderFor = (_) => _Provider(
            'polish',
            Stream.fromIterable([
              const TranslationUpdate('Hello.'),
              const TranslationCompleted(),
            ]),
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
        vocabulary: VocabularyStore(database),
      ),
    );
    await tester.pump();
    await messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope({
        'type': BridgeEventTypes.selectionCaptured,
        'sessionId': 'mode',
        'gesture': SelectionGestureTypes.hotkey,
        'text': 'hello',
        'sourceAppName': 'Notes',
        'x': 0,
        'y': 0,
      }),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(history.page(), hasLength(1));

    /// label 为菜单选项；打开卡片标题区的模式菜单并选择该项，等待处理结束。
    Future<void> choose(String label) async {
      await tester.tap(find.byType(NativeGlassMenuButton<TextMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, label));
      await tester.pumpAndSettle();
    }

    // 边界：润色完整成功也不属于翻译历史。
    await choose('润色');
    expect(session.snapshot.translatedText, 'Hello.');
    expect(find.text('润色结果'), findsOneWidget);
    expect(history.page(), hasLength(1));
    await choose('翻译');
    expect(session.snapshot.translatedText, '你好');
    expect(history.page(), hasLength(2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('单词查到释义时右栏为词典并可加入生词本，长句只翻译不查词典', (tester) async {
    const methods = MethodChannel('test/dictionary/methods');
    const events = EventChannel('test/dictionary/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name),
      (_) async => null,
    );
    final database = sqlite3.openInMemory();
    final vocabulary = VocabularyStore(database);
    final looked = <String>[];
    final session = SelectionSession(
      provider: _Provider(
        'translate',
        Stream.fromIterable([
          const TranslationUpdate('机缘凑巧'),
          const TranslationCompleted(),
        ]),
      ),
      detectLanguage: (_) async => 'en',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
      lookupDefinition: (text) async {
        looked.add(text);
        return 'serendipity | noun 机缘凑巧';
      },
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
        history: TranslationHistoryStore(database),
        vocabulary: vocabulary,
      ),
    );
    await tester.pump();

    /// text 为快捷键读取到的原文；发送全局翻译快捷键事件并等待翻译与查词结束。
    Future<void> translate(String sessionId, String text) async {
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope({
          'type': BridgeEventTypes.selectionCaptured,
          'sessionId': sessionId,
          'gesture': SelectionGestureTypes.hotkey,
          'text': text,
          'sourceAppName': 'Notes',
          'x': 0,
          'y': 0,
        }),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    // 边界一：单词带首尾空白，查词使用去空白后的原文，右栏改为词典。
    await translate('word', ' serendipity ');
    expect(looked, ['serendipity']);
    expect(find.text('词典'), findsOneWidget);
    expect(find.text('serendipity | noun 机缘凑巧'), findsOneWidget);
    await tester.tap(find.byTooltip('加入生词本'));
    await tester.pump();
    expect(find.byTooltip('已加入生词本'), findsOneWidget);
    expect(
      [for (final e in vocabulary.list()) (e.word, e.translation)],
      [('serendipity', '机缘凑巧')],
    );

    // 边界二：超过三个词的句子不查词典，右栏仍为原文，也没有加入按钮。
    await translate('sentence', 'this is a long sentence');
    expect(looked, ['serendipity']);
    expect(find.text('原文'), findsOneWidget);
    expect(find.byTooltip('加入生词本'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
