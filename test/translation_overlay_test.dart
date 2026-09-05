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
      final session = SelectionSession(provider: _Provider());
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
      tester.view.physicalSize = const Size(320, 220);
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.completed);
      expect(find.text('你好'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.idle);
      expect(find.text('你好'), findsNothing);
    },
  );
}
