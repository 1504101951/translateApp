import 'package:translate_app/src/common/constants/selection_gesture_types.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/bridge_event_types.dart';

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/selection/selection_translation_app.dart'
    show TranslateApp;
import 'package:translate_app/src/history/translation_history.dart';
import 'package:translate_app/src/history/vocabulary.dart';
import 'package:translate_app/src/platform/macos_platform_bridge.dart';
import 'package:translate_app/src/translation/language_direction.dart';
import 'package:translate_app/src/overlay/translation_overlay.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 以固定译文驱动真实会话，避免界面回归测试依赖外部网络。
class _Provider implements TranslationProvider {
  @override
  String get id => 'local-test';
  @override
  bool get usesSlidingContext => false;

  /// request 为真实翻译请求；返回一个完整译文事件流。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    yield const TranslationUpdate('你好');
    yield const TranslationCompleted();
  }
}

/// 无参数；注册紧凑按钮的拖动、翻译和关闭回归检查。
void main() {
  testWidgets('加载与结果保留至显式关闭，自动新选区不替换，热键可替换', (tester) async {
    // 使用真实事件编解码、App 和会话；只替代不可在 headless 测试中运行的原生窗口端。
    const methods = MethodChannel('test/retained-overlay/methods');
    const events = EventChannel('test/retained-overlay/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/retained-overlay/events'),
      (_) async => null,
    );
    final detection = Completer<String?>();
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) => detection.future,
      language: LanguageDirection(primaryCode: 'zh-CN'),
    );
    addTearDown(session.dispose);
    addTearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('test/retained-overlay/events'),
        null,
      );
    });
    await tester.pumpWidget(
      TranslateApp(
        bridge: MacosPlatformBridge(methods: methods, events: events),
        session: session,
        history: TranslationHistoryStore(sqlite3.openInMemory()),
        vocabulary: VocabularyStore(sqlite3.openInMemory()),
      ),
    );
    await tester.pump();

    /// payload 为原生事件字典；通过真实通道发给 App 并刷新一帧，无返回值。
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
      'sessionId': 'first',
      'gesture': SelectionGestureTypes.hotkey,
      'text': 'Hello',
      'x': 0,
      'y': 0,
    });
    expect(session.snapshot.phase, TranslationPhase.translating);
    await send({
      'type': BridgeEventTypes.selectionInvalidated,
      'sessionId': 'first',
    });
    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'passive',
      'gesture': SelectionGestureTypes.selectAll,
      'text': 'Ignored',
      'x': 0,
      'y': 0,
    });
    expect(session.sessionId, 'first');
    expect(session.snapshot.phase, TranslationPhase.translating);
    detection.complete('en');
    await tester.pumpAndSettle();
    await send({
      'type': BridgeEventTypes.selectionInvalidated,
      'sessionId': 'first',
    });
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    // 真实App入口不经过Scaffold；验证最终文字样式，避免黄色诊断双下划线回归。
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      expect(
        rich.text.style?.decoration?.contains(TextDecoration.underline) ??
            false,
        isFalse,
      );
    }
    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'replacement',
      'gesture': SelectionGestureTypes.hotkey,
      'text': 'Next',
      'x': 0,
      'y': 0,
    });
    await tester.pumpAndSettle();
    expect(session.sessionId, 'replacement');
    expect(find.text('Next'), findsOneWidget);
    await send({'type': MethodNames.escapePressed, 'sessionId': 'first'});
    expect(session.isExpanded, isTrue);
    await send({'type': MethodNames.escapePressed, 'sessionId': 'replacement'});
    expect(session.snapshot.phase, TranslationPhase.idle);
    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'close',
      'gesture': SelectionGestureTypes.hotkey,
      'text': 'Close',
      'x': 0,
      'y': 0,
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(session.snapshot.phase, TranslationPhase.idle);
    expect(find.text('你好'), findsNothing);

    // 空文本是热键读取失败的边界：显示可关闭的错误卡片，不能退回隐藏状态。
    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'empty-hotkey',
      'gesture': SelectionGestureTypes.hotkey,
      'text': '',
      'x': 0,
      'y': 0,
    });
    await tester.pumpAndSettle();
    expect(session.snapshot.phase, TranslationPhase.failed);
    expect(find.text('未读取到选中文字，请重新选择后使用翻译快捷键。'), findsOneWidget);
    await send({
      'type': BridgeEventTypes.selectionInvalidated,
      'sessionId': 'empty-hotkey',
    });
    expect(session.snapshot.phase, TranslationPhase.failed);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(session.snapshot.phase, TranslationPhase.idle);
  });

  testWidgets(
    'compact trigger drags without translating and expands on click',
    (tester) async {
      // 原生窗口84×32含透明命中边缘，视觉按钮84×30；拖动保留trigger。
      tester.view.physicalSize = TranslationOverlay.triggerWindowSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SelectionSession(
        detectLanguage: (_) async => 'en',
        provider: _Provider(),
      );
      addTearDown(session.dispose);
      session.begin(sessionId: 's1', text: 'Hello');
      var drags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationOverlay(
            session: session,
            onActivate: session.activate,
            onDismiss: session.dismiss,
            onDrag: () => drags += 1,
            onMode: session.switchMode,
            onSpeak: (_) {},
            onAddVocabulary: () {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('翻译'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      expect(
        tester.getSize(
          find.byWidgetPredicate((widget) => widget is FilledButton),
        ),
        TranslationOverlay.triggerSize,
      );

      await tester.drag(find.text('翻译'), const Offset(30, 0));
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.trigger);

      // 点击位置仍在小按钮里；结果态使用真实结果窗口尺寸。
      await tester.tap(find.text('翻译'));
      tester.view.physicalSize = const Size(720, 420);
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.completed);
      expect(find.text('你好'), findsOneWidget);
      // 首屏优先展示译文；比较真实布局坐标，避免仅验证两个文本都存在。
      expect(
        tester.getTopLeft(find.text('你好')).dx,
        lessThan(tester.getTopLeft(find.text('Hello')).dx),
      );
      expect(find.byTooltip('复制原文'), findsOneWidget);
      expect(find.byTooltip('复制译文'), findsOneWidget);
      // 标题下缘空白也能拖动；正文/关闭保持独立，拖动不改变结果内容或会话。
      // 边界：标题区高 44pt（#134），在距顶 40pt 处起拖仍属拖动区。
      final dragArea = find.byKey(const ValueKey('result-drag-area'));
      expect(tester.getSize(dragArea).height, 44);
      await tester.dragFrom(
        tester.getTopLeft(dragArea) + const Offset(180, 40),
        const Offset(40, 0),
      );
      await tester.pumpAndSettle();
      expect(drags, 2);
      expect(session.sessionId, 's1');
      expect(session.snapshot.phase, TranslationPhase.completed);
      expect(find.text('你好'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.idle);
      expect(find.text('你好'), findsNothing);
    },
  );

  testWidgets('两栏各有朗读按钮，点击分别朗读结果栏与原文栏，空栏禁用', (tester) async {
    // 边界：结果栏为空（翻译刚开始）时只能朗读原文；两栏都有内容时各自回报所属栏。
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
    );
    addTearDown(session.dispose);
    session.snapshot = const TranslationSnapshot(
      phase: TranslationPhase.translating,
      sourceText: 'Hello',
      translatedText: '',
    );
    final spoken = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: () {},
          onDismiss: () {},
          onDrag: () {},
          onMode: (_) {},
          onSpeak: spoken.add,
          onAddVocabulary: () {},
        ),
      ),
    );
    IconButton speaker(String tooltip) => tester.widget<IconButton>(
      find
          .widgetWithIcon(IconButton, Icons.volume_up_rounded)
          .at(tooltip == '朗读译文' ? 0 : 1),
    );
    expect(speaker('朗读译文').onPressed, isNull);
    expect(speaker('朗读原文').onPressed, isNotNull);
    session.snapshot = const TranslationSnapshot(
      phase: TranslationPhase.completed,
      sourceText: 'Hello',
      translatedText: '你好',
    );
    session.notifyListeners();
    await tester.pump();
    await tester.tap(find.byTooltip('朗读译文'));
    await tester.tap(find.byTooltip('朗读原文'));
    expect(spoken, [false, true]);
  });

  testWidgets('已验证的语义段落按译文原文成对展示', (tester) async {
    // 完整译文与分段译文不同，用最终可见文本证明使用了已校验配对。
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
    );
    addTearDown(session.dispose);
    session.snapshot = const TranslationSnapshot(
      phase: TranslationPhase.completed,
      sourceText: 'First. Second.',
      translatedText: '完整译文',
      pairs: [
        TranslationPair('First.', '第一段。'),
        TranslationPair('Second.', '第二段。'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: () {},
          onDismiss: () {},
          onDrag: () {},
          onMode: (_) {},
          onSpeak: (_) {},
          onAddVocabulary: () {},
        ),
      ),
    );
    expect(find.text('First.'), findsOneWidget);
    expect(find.text('第二段。'), findsOneWidget);
    expect(find.text('完整译文'), findsNothing);
    // 两组边界同时验证译文在左、原文在右，悬停只高亮对应段落。
    for (final pair in [('第一段。', 'First.'), ('第二段。', 'Second.')]) {
      final translated = tester.getTopLeft(find.text(pair.$1));
      final source = tester.getTopLeft(find.text(pair.$2));
      expect(translated.dx, lessThan(source.dx));
      expect(translated.dy, source.dy);
    }
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (var index = 0; index < 2; index++) {
      await mouse.moveTo(
        tester.getCenter(find.byKey(ValueKey('translated-paragraph-$index'))),
      );
      await tester.pump();
      for (var source = 0; source < 2; source++) {
        final container = tester.widget<Container>(
          find.byKey(ValueKey('source-paragraph-$source')),
        );
        final color = (container.decoration! as BoxDecoration).color;
        expect(
          color,
          source == index ? isNot(Colors.transparent) : Colors.transparent,
        );
      }
    }
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    final source = tester.widget<Container>(
      find.byKey(const ValueKey('source-paragraph-1')),
    );
    expect((source.decoration! as BoxDecoration).color, Colors.transparent);
  });

  /// tester 为测试驱动，session 为已激活的会话；以 720×420 结果窗口装载卡片并等待翻译与查词完成，无返回值。
  Future<void> pumpCard(WidgetTester tester, SelectionSession session) async {
    tester.view.physicalSize = const Size(720, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: session.activate,
          onDismiss: session.dismiss,
          onDrag: () {},
          onMode: session.switchMode,
          onSpeak: (_) {},
          onAddVocabulary: () {},
        ),
      ),
    );
    await session.activate();
    await tester.pumpAndSettle();
  }

  testWidgets('查到词典：左 2/5 上译文下原文用 18pt，右 3/5 词典栏头依次为生词本、朗读、复制（#134）', (
    tester,
  ) async {
    // 边界：720pt 宽卡片左栏占 288pt，词典栏从 x=288 起；译文在原文上方且同在左栏；
    // 词典栏头三个按钮从左到右为加入生词本、朗读词典、复制词典，可见按钮 24pt。
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
      language: const LanguageDirection(
        primaryCode: 'zh-CN',
        secondaryCode: 'en',
      ),
      lookupDefinition: (_) async => 'pot | BrE pɒt | A. noun ① 锅 guō',
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'dict', text: 'pot');
    await pumpCard(tester, session);
    final translated = tester.getTopLeft(find.text('你好'));
    final source = tester.getTopLeft(find.text('pot'));
    expect(translated.dx, source.dx);
    expect(translated.dy, lessThan(source.dy));
    expect(tester.widget<EditableText>(find.text('你好')).style.fontSize, 18);
    final dictionaryX = tester.getTopLeft(find.text('词典')).dx;
    expect(dictionaryX, greaterThan(288));
    expect(translated.dx, lessThan(288));
    final buttons = [
      '加入生词本',
      '朗读词典',
      '复制词典',
    ].map((tooltip) => tester.getRect(find.byTooltip(tooltip))).toList();
    expect(buttons[0].left, lessThan(buttons[1].left));
    expect(buttons[1].left, lessThan(buttons[2].left));
    expect(buttons[1].left - buttons[0].right, 4);
    expect(buttons[0].size, const Size(24, 24));
    expect(find.text('A. noun'), findsOneWidget);
  });

  testWidgets('原文已是目标语言时只显示原文一栏，没有译文栏（#134）', (tester) async {
    // 边界：未设置次要语言且识别为主要语言时目标语言等于原文语言；卡片只保留「复制原文」。
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'zh-CN',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'same', text: '今天天气很好');
    await pumpCard(tester, session);
    expect(session.sourceIsTarget, isTrue);
    expect(find.byTooltip('复制原文'), findsOneWidget);
    expect(find.byTooltip('复制译文'), findsNothing);
    expect(find.text('今天天气很好'), findsOneWidget);
  });
}
