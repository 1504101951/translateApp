import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/settings/screenshot_toolbar_editor.dart';
import 'package:translate_app/src/settings/screenshot_toolbar_preferences.dart';

/// 覆盖真实配置状态、冲突边界及录制/排序后的结果，不检查下游调用次数。
void main() {
  test('合并旧矩形与遮挡保留顺序、绑定优先级及显隐意图', () {
    final old = [...ScreenshotActions.icons.keys, ScreenshotActions.mask];
    final migrated = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarOrder: old,
      PreferenceKeys.screenshotToolbarShortcuts: {
        ScreenshotActions.mask: {'keyId': 49, 'modifiers': 0},
      },
      PreferenceKeys.screenshotToolbarHidden: [ScreenshotActions.rect],
    });
    expect(migrated.order, ScreenshotActions.icons.keys.toList());
    expect(migrated.shortcuts[ScreenshotActions.rect]!.keyId, 49);
    expect(migrated.hidden, isNot(contains(ScreenshotActions.rect)));
    final hidden = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarOrder: old,
      PreferenceKeys.screenshotToolbarHidden: [
        ScreenshotActions.rect,
        ScreenshotActions.mask,
      ],
    });
    expect(hidden.hidden, contains(ScreenshotActions.rect));
    final oldWithoutRect = [...ScreenshotActions.icons.keys]
      ..remove(ScreenshotActions.rect);
    oldWithoutRect.insertAll(1, [
      ScreenshotActions.palette,
      ScreenshotActions.mask,
    ]);
    final relative = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarOrder: oldWithoutRect,
    });
    expect(relative.order[1], ScreenshotActions.rect);

    expect(
      hidden.toMap()[PreferenceKeys.screenshotToolbarOrder],
      isNot(contains(ScreenshotActions.mask)),
    );
  });

  test('顶层工具顺序/快捷键持久化，重复和保留键拒绝', () {
    final order = ScreenshotActions.icons.keys.toList().reversed.toList();
    final first = ToolbarShortcut(LogicalKeyboardKey.digit1.keyId, 0);
    final second = ToolbarShortcut(LogicalKeyboardKey.digit2.keyId, 8);
    final preferences = ScreenshotToolbarPreferences(
      order: order,
      hidden: {ScreenshotActions.text},
      shortcuts: {
        ScreenshotActions.text: first,
        ScreenshotActions.crop: second,
      },
    );
    final app = AppSettings(
      primaryLanguage: 'zh-CN',
      screenshotToolbar: preferences,
    );
    app.validate();
    final restored = AppSettings.fromMap(app.toMap());
    expect(restored.screenshotToolbar.order, order);
    expect(restored.screenshotToolbar.hidden, {ScreenshotActions.text});
    expect(
      () =>
          ScreenshotToolbarPreferences(hidden: {ScreenshotActions.sizeUp})
              .validate(),
      throwsFormatException,
    );
    expect(
      restored.screenshotToolbar.shortcuts[ScreenshotActions.crop]!.label,
      '⌘2',
    );
    expect(
      () =>
          ScreenshotToolbarPreferences(order: [...order, order.first])
              .validate(),
      throwsFormatException,
    );
    expect(
      () => ScreenshotToolbarPreferences(
        shortcuts: {
          ScreenshotActions.text: first,
          ScreenshotActions.crop: first,
        },
      ).validate(),
      throwsFormatException,
    );
    for (final reserved in [
      ToolbarShortcut(LogicalKeyboardKey.keyZ.keyId, 8),
      ToolbarShortcut(LogicalKeyboardKey.keyC.keyId, 8),
      ToolbarShortcut(LogicalKeyboardKey.digit4.keyId, 12),
      ToolbarShortcut(LogicalKeyboardKey.keyD.keyId, 10),
      ToolbarShortcut(LogicalKeyboardKey.enter.keyId, 0),
      ToolbarShortcut(LogicalKeyboardKey.keyA.keyId, 0),
    ]) {
      expect(reserved.validate, throwsFormatException);
    }
  });

  test('取消上下文自定义后保留顶层相对顺序与绑定，未知动作仍报错', () {
    // 旧配置确实包含全部22项；仅删除明确撤销的上下文配置，不能重排用户顶层工具。
    final order = ScreenshotActions.labels.keys.toList().reversed.toList();
    final preferences = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarOrder: order,
      PreferenceKeys.screenshotToolbarShortcuts: {
        ScreenshotActions.text: {
          'keyId': LogicalKeyboardKey.digit1.keyId,
          'modifiers': 0,
        },
        ScreenshotActions.sizeUp: {
          'keyId': LogicalKeyboardKey.digit2.keyId,
          'modifiers': 0,
        },
      },
    });
    expect(preferences.order, order.where(ScreenshotActions.icons.containsKey));
    expect(preferences.shortcuts.keys, [ScreenshotActions.text]);
    expect(
      () => ScreenshotToolbarPreferences.fromMap({
        PreferenceKeys.screenshotToolbarOrder: [
          ...preferences.order,
          'unknown',
        ],
      }),
      throwsFormatException,
    );
  });

  testWidgets('录制数字、拒绝冲突、清除与排序不会静默覆盖其他动作', (tester) async {
    // 默认560pt窗口减去页面44pt和卡片32pt内边距，列表实际可用484pt。
    tester.view.physicalSize = const Size(484, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var saved = ScreenshotToolbarPreferences();
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ScreenshotToolbarEditor(
              value: saved,
              onChanged: (value) => saved = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bind-screenshot-tool-cursor')));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(saved.shortcuts[ScreenshotActions.cursor]!.label, '1');
    // 隐藏不能清除绑定，拖拽和录制其他工具也不能使其重新显示。
    await tester.tap(
      find.byKey(const ValueKey('visibility-screenshot-tool-cursor')),
    );
    await tester.pumpAndSettle();
    expect(saved.hidden, {ScreenshotActions.cursor});
    expect(saved.shortcuts[ScreenshotActions.cursor]!.label, '1');
    expect(find.byTooltip('显示 光标'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bind-screenshot-tool-crop')));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(find.text('快捷键已绑定其他截图动作。'), findsOneWidget);
    expect(saved.shortcuts.containsKey(ScreenshotActions.crop), isFalse);
    // 通过真实拖拽手柄跨过下一行中线，验证保存顺序；112pt避开84pt的原位落点边界。
    final handle = find.byKey(const ValueKey('drag-screenshot-tool-cursor'));
    final gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 92));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved.order.take(2), [
      ScreenshotActions.crop,
      ScreenshotActions.cursor,
    ]);
    await tester.tap(find.byTooltip('清除 光标 快捷键'));
    await tester.pumpAndSettle();
    expect(saved.shortcuts, isEmpty);
    await tester.tap(handle);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(saved.order.first, ScreenshotActions.cursor);
    expect(saved.hidden, {ScreenshotActions.cursor});
    await tester.tap(find.byTooltip('显示 光标'));
    await tester.pumpAndSettle();
    expect(saved.hidden, isEmpty);
    expect(
      find.byIcon(ScreenshotActions.icons[ScreenshotActions.cursor]!),
      findsOneWidget,
    );
    expect(find.text('增大字号'), findsNothing);
    expect(find.text('在 Finder 中显示'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bind-screenshot-tool-crop')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(saved.shortcuts[ScreenshotActions.crop]!.label, '⌘2');
    expect(
      ScreenshotToolbarPreferences.fromMap(saved.toMap())
          .shortcuts[ScreenshotActions.crop]!
          .modifiers,
      8,
    );
    expect(tester.takeException(), isNull);
  });
}
