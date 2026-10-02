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
      final dragArea = find.byKey(const ValueKey('result-drag-area'));
      expect(tester.getSize(dragArea).height, 56);
      await tester.dragFrom(
        tester.getTopLeft(dragArea) + const Offset(180, 50),
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
}
