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

  test('旧配置补上实时翻译并丢弃已移除的撤销与重做', () {
    // 作用：升级前保存的工具栏配置在新版本里仍能读取，不因顶层动作增减而校验失败。
    // 边界：旧顺序含撤销、重做且不含实时翻译与美化；新动作插到默认顺序中各自前一个动作之后（实时翻译在翻译文字后，美化在画笔后）；
    // 撤销的快捷键和隐藏状态一并丢弃，其余动作的相对顺序不变。
    const old = [
      ScreenshotActions.close,
      'screenshot-undo',
      ScreenshotActions.ocrTranslate,
      ScreenshotActions.cursor,
      'screenshot-redo',
      ScreenshotActions.crop,
      ScreenshotActions.rect,
      ScreenshotActions.arrow,
      ScreenshotActions.text,
      ScreenshotActions.brush,
      ScreenshotActions.pin,
      ScreenshotActions.save,
      ScreenshotActions.copy,
      ScreenshotActions.ocrCopy,
    ];
    final migrated = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarOrder: old,
      PreferenceKeys.screenshotToolbarHidden: ['screenshot-redo'],
      PreferenceKeys.screenshotToolbarShortcuts: {
        'screenshot-undo': {'keyId': 49, 'modifiers': 0},
        ScreenshotActions.crop: {'keyId': 50, 'modifiers': 0},
      },
    });
    expect(migrated.order, [
      ScreenshotActions.close,
      ScreenshotActions.ocrTranslate,
      ScreenshotActions.live,
      ScreenshotActions.cursor,
      ScreenshotActions.crop,
      ScreenshotActions.rect,
      ScreenshotActions.arrow,
      ScreenshotActions.text,
      ScreenshotActions.brush,
      ScreenshotActions.beautify,
      ScreenshotActions.pin,
      ScreenshotActions.save,
      ScreenshotActions.copy,
      ScreenshotActions.ocrCopy,
    ]);
    expect(migrated.hidden, isEmpty);
    expect(migrated.shortcuts.keys, [ScreenshotActions.crop]);
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

  test('默认结构为截图包含录制与滚动长截图；旧配置读取后回到同一结构', () {
    // 作用：升级前只保存了一级顺序的配置，读取后不因缺少两个功能而校验失败。
    // 边界：旧配置没有父子结构键，也不含录制与滚动长截图；两者回到截图之下，其余一级顺序不变。
    final defaults = ScreenshotToolbarPreferences();
    expect(defaults.children, {
      ScreenshotActions.crop: [
        ScreenshotActions.record,
        ScreenshotActions.scrolling,
      ],
    });
    expect(defaults.parentOf(ScreenshotActions.record), ScreenshotActions.crop);
    expect(defaults.parentOf(ScreenshotActions.crop), isNull);
    final old = defaults.order.reversed.toList();
    final migrated = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarOrder: old,
    });
    expect(migrated.order, old);
    expect(migrated.children, defaults.children);
    // 保存后再读取，结构保持不变。
    expect(
      ScreenshotToolbarPreferences.fromMap(migrated.toMap()).children,
      defaults.children,
    );
  });

  test('只有一级的工具可以包含子级，每个功能必须恰好出现一次', () {
    // 作用：拼接结果不合法时拒绝保存。
    // 边界：动作（保存）不能当父级；子级不能再当父级；同一功能不能既是一级又是子级。
    final all = ScreenshotActions.composable.keys.toList();
    List<String> without(Set<String> ids) => [
      for (final id in all)
        if (!ids.contains(id)) id,
    ];
    ScreenshotToolbarPreferences(
      order: without({ScreenshotActions.save}),
      children: {
        ScreenshotActions.brush: [ScreenshotActions.save],
      },
    ).validate();
    expect(
      () => ScreenshotToolbarPreferences(
        order: without({ScreenshotActions.copy}),
        children: {
          ScreenshotActions.save: [ScreenshotActions.copy],
        },
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => ScreenshotToolbarPreferences(
        order: without({ScreenshotActions.rect, ScreenshotActions.arrow}),
        children: {
          ScreenshotActions.brush: [ScreenshotActions.rect],
          ScreenshotActions.rect: [ScreenshotActions.arrow],
        },
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => ScreenshotToolbarPreferences(
        order: all,
        children: {
          ScreenshotActions.brush: [ScreenshotActions.save],
        },
      ).validate(),
      throwsFormatException,
    );
  });

  testWidgets('拖到右半边挂到指针所在的工具之下，左半边是一级；动作不能被挂载', (tester) async {
    // 作用：只想换顺序时不会误挂；挂载要明确拖到右半边的目标行上；子级拖到左半边即变回一级。
    // 边界：列表宽 484pt，中线 242pt；手柄中心在左侧 16pt 处，右移 100pt 仍在左半边，右移 300pt 进入右半边。每行 56pt。
    tester.view.physicalSize = const Size(484, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 顺序：画笔、保存、文字、其余；全部为一级。
    final order = [
      ScreenshotActions.brush,
      ScreenshotActions.save,
      ScreenshotActions.text,
      for (final id in ScreenshotActions.composable.keys)
        if (id != ScreenshotActions.brush &&
            id != ScreenshotActions.save &&
            id != ScreenshotActions.text)
          id,
    ];
    var saved = ScreenshotToolbarPreferences(order: order);
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

    /// id 为被拖动的功能，delta 为总位移，whileHeld 在松手前执行；用鼠标拖动它的手柄后松手。
    Future<void> drag(
      String id,
      Offset delta, {
      VoidCallback? whileHeld,
    }) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('drag-$id'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveBy(delta - const Offset(0, 20));
      await tester.pumpAndSettle();
      whileHeld?.call();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    const brush = {
      ScreenshotActions.brush: [ScreenshotActions.save],
    };
    // 文字（第 3 行）拖到右半边的保存行上：保存是动作，不能被挂载。
    // 拖动中保存行的右半边是遮罩，画笔行的右半边是可挂载的底色；松手后结构和顺序都不变。
    await drag(
      ScreenshotActions.text,
      const Offset(300, -56),
      whileHeld: () {
        expect(
          find.byKey(const ValueKey('toolbar-blocked-screenshot-save')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('toolbar-attach-screenshot-tool-brush')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('toolbar-host-highlight')),
          findsNothing,
        );
      },
    );
    expect(saved.children, isEmpty);
    expect(saved.order.take(3), order.take(3));
    // 保存（第 2 行）右移 100pt 仍在左半边：只是排序，不会挂到画笔之下。
    await drag(ScreenshotActions.save, const Offset(100, 0));
    expect(saved.children, isEmpty);
    expect(saved.order.take(3), order.take(3));
    // 保存拖到右半边的画笔行上：画笔行整行高亮，松手后成为画笔的子级。
    await drag(
      ScreenshotActions.save,
      const Offset(300, -56),
      whileHeld: () => expect(
        find.byKey(const ValueKey('toolbar-host-highlight')),
        findsOneWidget,
      ),
    );
    expect(saved.children, brush);
    expect(saved.order.take(2), [
      ScreenshotActions.brush,
      ScreenshotActions.text,
    ]);
    // 子级保存在左半边原地松手：变回一级，位置在画笔之后。
    await drag(ScreenshotActions.save, Offset.zero);
    expect(saved.children, isEmpty);
    expect(saved.order.take(3), order.take(3));
    // 方向键：右键放到画笔之下，左键变回一级，再右键放回去。
    await tester.tap(find.byKey(const ValueKey('drag-screenshot-save')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(saved.children, brush);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(saved.children, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(saved.children, brush);
    // 此时各行为：画笔、保存（子级）、文字。文字拖到右半边保存行的上半行（行内 14pt 处）：插到保存之前。
    await drag(ScreenshotActions.text, const Offset(300, -70));
    expect(saved.children, {
      ScreenshotActions.brush: [ScreenshotActions.text, ScreenshotActions.save],
    });
    expect(tester.takeException(), isNull);
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
    // 通过真实拖拽手柄把光标拖到截图及其两个子级之后：每行 56pt，
    // 从第 1 行中心下移 196pt 落在第 4 行与第 5 行之间；指针没有右移，保持一级。
    final handle = find.byKey(const ValueKey('drag-screenshot-tool-cursor'));
    final gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 176));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar-drop-line')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar-drop-line')), findsNothing);
    expect(saved.children[ScreenshotActions.crop], [
      ScreenshotActions.record,
      ScreenshotActions.scrolling,
    ]);
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
