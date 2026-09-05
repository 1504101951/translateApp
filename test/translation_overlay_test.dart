import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/overlay/translation_overlay.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 以固定译文驱动真实会话，避免界面回归测试依赖外部网络。
class _Provider implements TranslationProvider {
  @override
  String get id => 'local-test';

  /// request 为真实翻译请求；返回一个完整译文事件流。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    yield const TranslationUpdate('你好');
    yield const TranslationCompleted();
  }
}

/// 无参数；注册紧凑按钮的拖动、翻译和关闭回归检查。
void main() {
  testWidgets(
    'compact trigger drags without translating and expands on click',
    (tester) async {
      // 84×36 是真实原生触发窗口边界；拖动应保留 trigger，点击才产生译文。
      tester.view.physicalSize = TranslationOverlay.triggerSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SelectionSession(
        detectLanguage: (_) async => 'en',
        provider: _Provider(),
      );
      addTearDown(session.dispose);
      session.begin(sessionId: 's1', text: 'Hello');
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationOverlay(
            session: session,
            onActivate: session.activate,
            onDismiss: session.dismiss,
            onDrag: () {},
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
