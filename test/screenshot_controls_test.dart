import 'package:translate_app/src/common/constants/method_names.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/settings/screenshot_toolbar_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/utils/geometry.dart';
import 'package:translate_app/src/common/constants/screenshot_enums.dart';
import 'package:translate_app/src/screenshot/edit_document.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';
import 'package:translate_app/src/common/widgets/native_resize_cursor.dart';
import 'package:translate_app/src/screenshot/screenshot_editor_layout.dart';

/// 无参数；验证工具栏避让的几何边界及硬件回车的真实编辑/导出结果。
void main() {
  test('工具栏依次使用下、上、右、左侧空白，完整位于窗口且不与选区相交', () {
    // 四个选区分别只允许纵向下方、上方或横向单侧放置。
    const viewport = Size(960, 740);
    final cases = [
      (crop: const Rect.fromLTWH(200, 100, 400, 200), side: 'bottom'),
      (crop: const Rect.fromLTWH(200, 440, 400, 290), side: 'top'),
      (crop: const Rect.fromLTWH(0, 0, 820, 740), side: 'right'),
      (crop: const Rect.fromLTWH(140, 0, 820, 740), side: 'left'),
    ];
    for (final item in cases) {
      final layout = ScreenshotEditorLayout.place(
        viewport: viewport,
        image: viewport,
        crop: item.crop,
      );
      expect(layout.canvas, Offset.zero & viewport);
      expect(layout.toolbar.overlaps(item.crop), isFalse);
      expect((Offset.zero & viewport).contains(layout.toolbar.topLeft), isTrue);
      expect(
        (Offset.zero & viewport).contains(layout.toolbar.bottomRight),
        isTrue,
      );
      switch (item.side) {
        case 'bottom':
          expect(layout.toolbar.top, greaterThan(item.crop.bottom));
          expect(layout.axis, Axis.horizontal);
        case 'top':
          expect(layout.toolbar.bottom, lessThan(item.crop.top));
          expect(layout.axis, Axis.horizontal);
        case 'right':
          expect(layout.toolbar.left, greaterThan(item.crop.right));
          expect(layout.axis, Axis.vertical);
        case 'left':
          expect(layout.toolbar.right, lessThan(item.crop.left));
          expect(layout.axis, Axis.vertical);
      }
    }
  });

  test('全屏和近全屏选区将工具栏放在内侧边缘，不移动或缩放画布', () {
    // 普通、窄屏及 Retina 场景：无外侧空白时允许覆盖选区，画布必须保持整屏。
    for (final viewport in [const Size(960, 740), const Size(320, 600)]) {
      const image = Size(1920, 1480);
      for (final crop in [
        Offset.zero & image,
        const Rect.fromLTWH(2, 2, 1916, 1476),
      ]) {
        final layout = ScreenshotEditorLayout.place(
          viewport: viewport,
          image: image,
          crop: crop,
        );
        expect(layout.canvas, Offset.zero & viewport);
        expect(
          layout.toolbar.overlaps(mapRectToFitted(crop, image, layout.canvas)),
          isTrue,
        );
        expect(
          (Offset.zero & viewport).contains(layout.toolbar.bottomRight),
          isTrue,
        );
      }
    }
  });

  test('三四行工具栏在全屏贴边与横竖布局中保持屏幕内且不改变画布', () {
    // 3/4行厚度120/156pt；源图倍率1/2及负原点显示器归一化后的视口使用相同局部几何。
    for (final size in [const Size(960, 740), const Size(320, 600)]) {
      for (final rows in [3, 4]) {
        for (final scale in [1.0, 2.0]) {
          for (final crop in [
            Offset.zero & size,
            Rect.fromLTWH(0, 0, size.width - 190, size.height),
          ]) {
            final layout = ScreenshotEditorLayout.place(
              viewport: size,
              image: Size(size.width * scale, size.height * scale),
              crop: Rect.fromLTRB(
                crop.left * scale,
                crop.top * scale,
                crop.right * scale,
                crop.bottom * scale,
              ),
              rowCount: rows,
              toolbarLength: 1200,
            );
            expect(layout.canvas, Offset.zero & size);
            expect(
              (Offset.zero & size).contains(layout.toolbar.topLeft),
              isTrue,
            );
            expect(
              (Offset.zero & size).contains(layout.toolbar.bottomRight),
              isTrue,
            );
            expect(
              layout.axis == Axis.horizontal
                  ? layout.toolbar.height
                  : layout.toolbar.width,
              16 + rows * 32 + (rows - 1) * 4,
            );
          }
        }
      }
    }
  });

  testWidgets('默认窗口仅预览可重新框选，手动选区八点和边框可拉伸', (tester) async {
    // 初始窗口预览不能拦截新框选；用户框选后才显示八点和边线拉伸光标。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_image);
    const channel = MethodChannel('test/crop-cursor');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'cursor',
          'bytes': png,
          'width': 960,
          'height': 740,
          'cropX': 200,
          'cropY': 180,
          'cropWidth': 400,
          'cropHeight': 300,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    await mouse.moveTo(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.precise,
    );
    // 从预览框内部画更小矩形：旧错误会将原框整体拖动，无法得到下述八个新边界。
    await tester.dragFrom(const Offset(280, 220), const Offset(240, 180));
    await tester.pumpAndSettle();
    final cases = <Offset, MouseCursor>{
      const Offset(280, 220): const NativeResizeCursor(
        ResizeCursorAxes.northWestSouthEast,
        channel: channel,
      ),
      const Offset(400, 220): SystemMouseCursors.resizeUpDown,
      const Offset(520, 220): const NativeResizeCursor(
        ResizeCursorAxes.northEastSouthWest,
        channel: channel,
      ),
      const Offset(520, 310): SystemMouseCursors.resizeLeftRight,
      const Offset(520, 400): const NativeResizeCursor(
        ResizeCursorAxes.northWestSouthEast,
        channel: channel,
      ),
      const Offset(400, 400): SystemMouseCursors.resizeUpDown,
      const Offset(280, 400): const NativeResizeCursor(
        ResizeCursorAxes.northEastSouthWest,
        channel: channel,
      ),
      const Offset(280, 310): SystemMouseCursors.resizeLeftRight,
      const Offset(340, 220): SystemMouseCursors.resizeUpDown,
      const Offset(340, 400): SystemMouseCursors.resizeUpDown,
      const Offset(280, 260): SystemMouseCursors.resizeLeftRight,
      const Offset(520, 260): SystemMouseCursors.resizeLeftRight,
      const Offset(400, 300): SystemMouseCursors.grab,
      const Offset(100, 100): SystemMouseCursors.precise,
    };
    for (final item in cases.entries) {
      await mouse.moveTo(item.key);
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        item.value,
        reason: '光标位置 ${item.key}',
      );
    }
    await mouse.removePointer();
  });

  testWidgets('整屏与上次区域的初始选区直接选中：控制点可拉伸，内部可拖动', (tester) async {
    // 边界：与窗口预览相同的初始矩形，cropSelected 为 true 时角点立即是拉伸光标、内部为抓手，
    // 拖动右下角后新角点仍可拉伸（#105）。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_image);
    const channel = MethodChannel('test/crop-selected');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'selected',
          'bytes': png,
          'width': 960,
          'height': 740,
          'cropX': 200,
          'cropY': 180,
          'cropWidth': 400,
          'cropHeight': 300,
          'cropSelected': true,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));

    /// position 为窗口坐标；移动鼠标并返回当前光标。
    Future<MouseCursor?> cursorAt(Offset position) async {
      await mouse.moveTo(position);
      await tester.pumpAndSettle();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    }

    const resize = NativeResizeCursor(
      ResizeCursorAxes.northWestSouthEast,
      channel: channel,
    );
    expect(await cursorAt(const Offset(200, 180)), resize);
    expect(await cursorAt(const Offset(400, 330)), SystemMouseCursors.grab);
    await tester.dragFrom(const Offset(600, 480), const Offset(-100, -80));
    await tester.pumpAndSettle();
    expect(await cursorAt(const Offset(500, 400)), resize);
    // 选区外的空白处仍是框选光标（工具栏位于新选区下方，避开其位置）。
    expect(await cursorAt(const Offset(100, 100)), SystemMouseCursors.precise);
    await mouse.removePointer();
  });

  test('比例矩形朝指针方向生长，较短边不小于下限，空间不足时整体缩小', () {
    // 边界：宽度由 dx 驱动时忽略 dy；指针在锚点左上方时向左上生长；byHeight 由 dy 推算宽度；
    // 下方只剩 40、右侧只剩 60 时分别被对应方向限制；横向与纵向比例下较短边各自不小于 8；minSide 为 0 时允许空矩形（#106）。
    const bounds = Size(960, 740);
    Rect rect(
      Offset anchor,
      Offset toward,
      double ratio, {
      bool byHeight = false,
      double minSide = 8,
    }) => ratioRect(
      anchor: anchor,
      toward: toward,
      ratio: ratio,
      byHeight: byHeight,
      bounds: bounds,
      minSide: minSide,
    );
    expect(
      rect(const Offset(100, 100), const Offset(300, 400), 1),
      const Rect.fromLTWH(100, 100, 200, 200),
    );
    expect(
      rect(const Offset(100, 100), const Offset(40, 0), 16 / 9),
      const Rect.fromLTWH(40, 66.25, 60, 33.75),
    );
    expect(
      rect(const Offset(0, 0), const Offset(500, 90), 16 / 9, byHeight: true),
      const Rect.fromLTWH(0, 0, 160, 90),
    );
    expect(
      rect(const Offset(100, 700), const Offset(900, 710), 1),
      const Rect.fromLTWH(100, 700, 40, 40),
    );
    expect(
      rect(const Offset(900, 100), const Offset(1200, 200), 1),
      const Rect.fromLTWH(900, 100, 60, 60),
    );
    final landscape = rect(const Offset(10, 10), const Offset(11, 11), 16 / 9);
    expect(landscape.height, closeTo(8, 1e-9));
    expect(landscape.width, closeTo(128 / 9, 1e-9));
    final portrait = rect(const Offset(10, 10), const Offset(11, 11), 9 / 16);
    expect(portrait.width, closeTo(8, 1e-9));
    expect(portrait.height, closeTo(128 / 9, 1e-9));
    expect(
      rect(const Offset(10, 10), const Offset(10, 10), 1, minSide: 0),
      const Rect.fromLTWH(10, 10, 0, 0),
    );
  });

  testWidgets('方向键移动选区 1 像素、⇧ 10 像素，⌥ 调整大小，限制在截图内且最小边长 8', (tester) async {
    // 边界：移动与 ⌥ 调整均停在截图四边；⌥⇧← 连按后宽度停在 8；
    // 尺寸标签上方空间足够时贴在选区左上角外侧，选区贴顶时放进选区内 4pt；导出图与记住的区域和标签一致（#106）。
    final calls = (await _pumpSelectedCrop(tester, 'test/crop-nudge')).calls;
    final label = find.byKey(const Key('crop-size-label'));
    expect(find.text('400 × 300'), findsOneWidget);
    expect(tester.getRect(label).bottom, 176);
    expect(tester.getRect(label).left, 200);

    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    await _arrow(tester, LogicalKeyboardKey.arrowDown);
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowLeft,
      modifiers: [LogicalKeyboardKey.shiftLeft],
    );
    expect(await _copyCrop(tester, calls), (
      const Size(400, 300),
      const Rect.fromLTWH(191, 181, 400, 300),
    ));

    await _arrow(
      tester,
      LogicalKeyboardKey.arrowRight,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowUp,
      modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.shiftLeft],
    );
    expect(find.text('401 × 290'), findsOneWidget);
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await _arrow(
        tester,
        key,
        modifiers: [LogicalKeyboardKey.shiftLeft],
        times: 60,
      );
    }
    expect(await _copyCrop(tester, calls), (
      const Size(401, 290),
      const Rect.fromLTWH(559, 450, 401, 290),
    ));

    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
    ]) {
      await _arrow(
        tester,
        key,
        modifiers: [LogicalKeyboardKey.shiftLeft],
        times: 60,
      );
    }
    expect(tester.getRect(label).topLeft, const Offset(4, 4));
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowLeft,
      modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.shiftLeft],
      times: 50,
    );
    expect(find.text('8 × 290'), findsOneWidget);
    expect(await _copyCrop(tester, calls), (
      const Size(8, 290),
      const Rect.fromLTWH(0, 0, 8, 290),
    ));
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await _arrow(
        tester,
        key,
        modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.shiftLeft],
        times: 100,
      );
    }
    expect(find.text('960 × 740'), findsOneWidget);
    // 等待复制反馈计时结束，避免遗留计时器。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('文字输入中与选中标注时方向键不移动选区，取消选中后恢复', (tester) async {
    // 边界：输入框打开时隐藏尺寸标签且方向键留给输入框；光标工具选中矩形后方向键无效；
    // 点击空白取消选中后同一按键移动 1 像素，证明前两次是被条件拦下（#106）。
    final calls = (await _pumpSelectedCrop(
      tester,
      'test/crop-nudge-ignore',
    )).calls;
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hi',
    );
    expect(find.byKey(const Key('crop-size-label')), findsNothing);
    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screenshot-tool-rect')));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(250, 250), const Offset(100, 80));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenshot-tool-cursor')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(350, 300));
    // 画布同时识别双击，单击要等双击超时后才生效。
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    expect(
      (await _copyCrop(tester, calls)).$2,
      const Rect.fromLTWH(200, 180, 400, 300),
    );

    await tester.tapAt(const Offset(100, 100));
    // 画布同时识别双击，单击要等双击超时后才生效。
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    expect(
      (await _copyCrop(tester, calls)).$2,
      const Rect.fromLTWH(201, 180, 400, 300),
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('锁定比例后新框选、控制点与 ⌥ 方向键保持比例；自由与新截图解除', (tester) async {
    // 边界：选择 1:1/16:9 以左上角为锚点保持宽度；角点由宽度驱动、上边由高度驱动；
    // Esc 先收起比例行但比例仍生效；选择自由后 ⌥↓ 只改高度；新截图恢复自由（#106）。
    final pumped = await _pumpSelectedCrop(tester, 'test/crop-ratio');
    await tester.tap(find.byKey(const Key(ScreenshotActions.ratio)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ratio-row')), findsOneWidget);
    await tester.tap(find.byTooltip('比例 1:1'));
    await tester.pumpAndSettle();
    expect(find.text('400 × 400'), findsOneWidget);
    await tester.tap(find.byTooltip('比例 16:9'));
    await tester.pumpAndSettle();
    expect(find.text('400 × 225'), findsOneWidget);

    await tester.dragFrom(const Offset(600, 405), const Offset(100, 300));
    await tester.pumpAndSettle();
    expect(find.text('500 × 281'), findsOneWidget);
    await tester.dragFrom(const Offset(450, 180), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('642 × 361'), findsOneWidget);
    await tester.dragFrom(const Offset(20, 20), const Offset(160, 40));
    await tester.pumpAndSettle();
    expect(find.text('160 × 90'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ratio-row')), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowRight,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    expect(find.text('161 × 91'), findsOneWidget);

    await tester.tap(find.byKey(const Key(ScreenshotActions.ratio)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('自由比例'));
    await tester.pumpAndSettle();
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowDown,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    expect(find.text('161 × 92'), findsOneWidget);

    await tester.tap(find.byTooltip('比例 1:1'));
    await tester.pumpAndSettle();
    expect(find.text('161 × 161'), findsOneWidget);
    await tester.runAsync(() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            pumped.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(MethodNames.screenshotChanged, {
                ...pumped.snapshot,
                'id': 'second',
              }),
            ),
            (_) {},
          );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ratio-row')), findsNothing);
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowRight,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    expect(find.text('401 × 300'), findsOneWidget);
  });

  testWidgets('光标优先操作文字并可选中移动拉伸截图，空白拖动不重新框选', (tester) async {
    // 使用与视口1:1的图像，实际鼠标坐标应对应导出像素和文本框几何。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(() => _image(width: 960, height: 740));
    const channel = MethodChannel('test/unified-cursor');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'unified',
          'bytes': png,
          'width': 960,
          'height': 740,
          'cropX': 200,
          'cropY': 180,
          'cropWidth': 400,
          'cropHeight': 300,
        };
      }
      if (call.method == MethodNames.copyScreenshot) {
        copied = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(400, 300), const Offset(40, 20));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(640, 350), const Offset(60, 0));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(240, 200));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      const NativeResizeCursor(
        ResizeCursorAxes.northWestSouthEast,
        channel: channel,
      ),
    );
    await mouse.removePointer();
    // 在截图内部添加文字；光标拖文字不能连带移动截图。
    await tester.tap(find.byKey(const Key(ScreenshotActions.text)));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(300, 260), const Offset(200, 60));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      '来源与译文',
    );
    // Esc 结束输入并保留文字。文字框宽 200（拖出的宽度），高度为一行文字的高度。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final lineHeight = textBoxHeight(
      text: '来源与译文',
      fontSize: ScreenshotDefaults.fontSize,
      width: 200,
    );
    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pumpAndSettle();
    // 框内拖动是移动：左上角从 (300,260) 到 (330,290)。
    await tester.dragFrom(
      Offset(400, 260 + lineHeight / 2),
      const Offset(30, 30),
    );
    await tester.pumpAndSettle();
    // 拖右边把宽度从 200 加到 240；纵向位移不改变高度。
    await tester.dragFrom(
      Offset(530, 290 + lineHeight / 2),
      const Offset(40, 20),
    );
    await tester.pumpAndSettle();
    // 文本四角与截图采用相同原生轴；离开对象后必须归还普通箭头。
    final textMouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await textMouse.addPointer(location: const Offset(40, 40));
    for (final corner in <Offset, String>{
      const Offset(330, 290): ResizeCursorAxes.northWestSouthEast,
      const Offset(570, 290): ResizeCursorAxes.northEastSouthWest,
      Offset(330, 290 + lineHeight): ResizeCursorAxes.northEastSouthWest,
      Offset(570, 290 + lineHeight): ResizeCursorAxes.northWestSouthEast,
    }.entries) {
      await textMouse.moveTo(corner.key);
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        NativeResizeCursor(corner.value, channel: channel),
      );
    }
    await textMouse.moveTo(const Offset(40, 40));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    await textMouse.removePointer();
    // 双击文字重新编辑，几何来自实际TextField，不能只检验状态字段。
    await tester.tapAt(Offset(440, 290 + lineHeight / 2));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(Offset(440, 290 + lineHeight / 2));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('screenshot-text-field'));
    expect(field, findsOneWidget);
    // 文字框高度随内容：一行文字时等于一行的高度，宽度为拖动后的 240。
    final textBox = find
        .ancestor(of: field, matching: find.byType(Positioned))
        .first;
    expect(tester.getRect(textBox), Rect.fromLTWH(330, 290, 240, lineHeight));
    expect(find.text('来源与译文'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(50, 50), const Offset(40, 40));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key(ScreenshotActions.copy)));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();
    expect(copied, isNotNull);
    final decoded = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(copied!);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    });
    expect(decoded!.width, 460);
    expect(decoded.height, 300);
    decoded.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具顺序与局部快捷键生效，文字编辑不切换工具，更新配置保留画布', (tester) async {
    final png = await tester.runAsync(_image);
    final preferences = ScreenshotToolbarPreferences(
      order: ScreenshotActions.icons.keys.toList().reversed.toList(),
      hidden: {ScreenshotActions.text},
      shortcuts: {
        ScreenshotActions.text: ToolbarShortcut(
          LogicalKeyboardKey.digit1.keyId,
          0,
        ),
        ScreenshotActions.crop: ToolbarShortcut(
          LogicalKeyboardKey.digit2.keyId,
          8,
        ),
      },
    );
    const channel = MethodChannel('test/toolbar-config');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'tool-test',
          'bytes': png,
          'width': 320,
          'height': 240,
          ...preferences.toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
    expect(
      tester.getTopLeft(find.byKey(const Key(ScreenshotActions.close))).dx,
      lessThan(
        tester.getTopLeft(find.byKey(const Key(ScreenshotActions.crop))).dx,
      ),
    );
    expect(find.byKey(const Key(ScreenshotActions.text)), findsNothing);
    // 原生非激活面板发送语义动作；必须看到实际文字控件出现，旧捕获不能切换工具。
    Future<void> nativeAction(String id, String action) async {
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(MethodNames.screenshotToolbarAction, {
            'id': id,
            'action': action,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await nativeAction('stale', ScreenshotActions.text);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsNothing);
    await nativeAction('tool-test', ScreenshotActions.text);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await nativeAction('tool-test', ScreenshotActions.crop);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await tester.tapAt(canvas.center);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await nativeAction('tool-test', ScreenshotActions.crop);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await tester.enterText(find.byType(TextField), '保留草稿');
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(
          MethodNames.screenshotToolbarChanged,
          ScreenshotToolbarPreferences().toMap(),
        ),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('保留草稿'), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.text)), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('screenshot-canvas'))), canvas);
  });

  testWidgets('主键盘和小键盘回车复制完整像素并退出，文字输入中回车只换行', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_image);
    const channel = MethodChannel('test/screenshot-enter');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? clipboard;
    var ended = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'enter',
            'bytes': png,
            'width': 320,
            'height': 240,
            'capturedAt': 0,
          };
        case MethodNames.copyScreenshot:
          clipboard = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
        case MethodNames.closeScreenshot:
          // 原生窗口关闭后会释放捕获；模拟该状态通知，而非断言方法调用次数。
          await messenger.handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(
              const MethodCall(
                MethodNames.screenshotChanged,
                <String, Object>{},
              ),
            ),
            (_) {},
          );
          ended.complete();
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final key in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
    ]) {
      clipboard = null;
      ended = Completer<void>();
      // 原生截图引擎逐次创建；先销毁旧实例，避免旧 dispose 清除新通道监听。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        ScreenshotApp(key: ValueKey(key), channel: channel),
      );
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
      final toolbar = tester.getRect(
        find.byKey(const Key('screenshot-toolbar')),
      );
      expect(canvas, const Rect.fromLTWH(0, 0, 960, 740));
      expect(canvas.overlaps(toolbar), isTrue);
      // PNG 编码使用真实图像线程，随后由测试队列接收原生窗口状态通知。
      await tester.runAsync(() async {
        await tester.sendKeyEvent(key);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(ended.isCompleted, isTrue);
      expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
      final size = await tester.runAsync(() async {
        final decoder = await ui.instantiateImageCodec(clipboard!);
        final frame = await decoder.getNextFrame();
        final size = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        // 工具栏覆盖屏幕中的图片，导出右下角仍必须是原图蓝色，而非工具栏背景。
        final pixels = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(pixels!.buffer.asUint8List().sublist((320 * 240 - 1) * 4), [
          0x22,
          0x55,
          0xAA,
          0xFF,
        ]);
        frame.image.dispose();
        decoder.dispose();
        return size;
      });
      expect(size, const Size(320, 240));
    }

    // 文字输入优先级：Shift+Enter 保留编辑，普通 Enter 提交，下一次 Enter 才复制退出。
    clipboard = null;
    ended = Completer<void>();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      const ScreenshotApp(key: ValueKey('text-enter'), channel: channel),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hello',
    );
    // 原生确认也必须保留输入法组词状态，不能把未确认的拼音当成最终标注。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.confirmScreenshot, {'id': 'enter'}),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    expect(clipboard, isNull);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hello',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    // 输入中回车是换行，不结束输入也不复制截图；Esc 才结束输入。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);
    expect(clipboard, isNull);
    expect(ended.isCompleted, isFalse);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
    expect(clipboard, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左右竖栏完整可用，状态可见，拖动中保持画布位置且隐藏工具栏', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_image);
    const channel = MethodChannel('test/screenshot-toolbar-sides');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final snapshot = <String, Object?>{
      'id': 'sides',
      'bytes': png,
      'width': 320,
      'height': 240,
      'capturedAt': 0,
      'cropX': 0,
      'cropY': 0,
      'cropWidth': 270,
      'cropHeight': 240,
    };
    Uint8List? clipboard;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.copyScreenshot) {
        clipboard = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    // 占满纵向，仅左右留白的两个选区，必须实际切换为竖向工具栏。
    for (final x in [0, 50]) {
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          MethodCall(MethodNames.screenshotChanged, {...snapshot, 'cropX': x}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
      final crop = mapRectToFitted(
        Rect.fromLTWH(x.toDouble(), 0, 270, 240),
        const Size(320, 240),
        canvas,
      );
      final toolbar = tester.getRect(
        find.byKey(const Key('screenshot-toolbar')),
      );
      expect(toolbar.height, greaterThan(toolbar.width));
      expect(toolbar.overlaps(crop), isFalse);
      expect(toolbar.left > crop.right || toolbar.right < crop.left, isTrue);
      await tester.ensureVisible(find.byKey(const Key('screenshot-copy')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('screenshot-copy')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(clipboard, isNotNull);
      expect(
        toolbar.overlaps(
          tester.getRect(find.byKey(const Key('toolbar-feedback-bubble'))),
        ),
        isFalse,
      );
      final size = await tester.runAsync(() async {
        final decoder = await ui.instantiateImageCodec(clipboard!);
        final frame = await decoder.getNextFrame();
        final size = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        frame.image.dispose();
        decoder.dispose();
        return size;
      });
      expect(size, const Size(270, 240));
    }
    // 拖动期间只改变预览，不移动/缩放已建立的画布坐标系。
    final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
    final gesture = await tester.startGesture(canvas.center);
    await gesture.moveBy(const Offset(80, 80));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-toolbar')), findsNothing);
    expect(tester.getRect(find.byKey(const Key('screenshot-canvas'))), canvas);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-toolbar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('复制成功在工具栏外浮动一秒，重复成功重新计时，换图立即清除', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_image);
    const channel = MethodChannel('test/copy-feedback');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final snapshot = <String, Object?>{
      'id': 'feedback',
      'bytes': bytes,
      'width': 320,
      'height': 240,
      'capturedAt': 0,
    };
    Uint8List? clipboard;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.copyScreenshot) {
        clipboard = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    final feedback = find.byKey(const Key('toolbar-feedback-bubble'));
    final copyButton = find.byKey(const Key('screenshot-copy'));

    /// 无参数；真实图像线程完成复制后返回，计时器保持在 Widget 测试时钟内。
    Future<void> copy() async {
      await tester.ensureVisible(copyButton);
      await tester.tap(copyButton);
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester.widget<IconButton>(copyButton).onPressed != null &&
            feedback.evaluate().isNotEmpty) {
          return;
        }
      }
      fail('复制没有在限定时间内完成');
    }

    await copy();
    expect(clipboard, isNotNull);
    final toolbar = tester.getRect(find.byKey(const Key('screenshot-toolbar')));
    expect(tester.getRect(feedback).bottom, lessThan(toolbar.top));
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-toolbar')),
        matching: find.text('已复制图片'),
      ),
      findsNothing,
    );
    // 500ms 后再次复制，检查新反馈的 999ms/1000ms 边界，旧定时器不得提前清除。
    await tester.pump(const Duration(milliseconds: 500));
    await copy();
    await tester.pump(const Duration(milliseconds: 999));
    expect(feedback, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(feedback, findsNothing);
    expect(find.text('已复制图片'), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);

    // 工具栏贴近屏幕顶边时仍需保证提示在屏幕内，且不盖住工具栏。
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(MethodNames.screenshotChanged, {
          ...snapshot,
          'id': 'top',
          'cropX': 70,
          'cropY': 24,
          'cropWidth': 200,
          'cropHeight': 216,
        }),
      ),
      (_) {},
    );
    await tester.pump();
    await copy();
    final toastRect = tester.getRect(feedback);
    expect(
      (Offset.zero & const Size(960, 740)).contains(toastRect.topLeft),
      isTrue,
    );
    expect(
      (Offset.zero & const Size(960, 740)).contains(toastRect.bottomRight),
      isTrue,
    );
    expect(
      toastRect.overlaps(
        tester.getRect(find.byKey(const Key('screenshot-toolbar'))),
      ),
      isFalse,
    );
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(MethodNames.screenshotChanged, {...snapshot, 'id': 'next'}),
      ),
      (_) {},
    );
    await tester.pump();
    expect(feedback, findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });
  testWidgets('识别文字后复制的迟到成功不能在替换后的截图显示提示', (tester) async {
    // 复制请求已发出但回复尚未到达时换图；反馈必须属于发起请求的那张截图。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_image);
    const channel = MethodChannel('test/copy-feedback-stale-text');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final copyReply = Completer<void>();
    final copyPending = Completer<void>();
    final snapshot = <String, Object?>{
      'id': 'first',
      'bytes': bytes,
      'width': 320,
      'height': 240,
      'capturedAt': 0,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.recognizeText) {
        return {'text': 'Hello', 'codes': <Object>[]};
      }
      if (call.method == MethodNames.copyText) {
        copyPending.complete();
        await copyReply.future;
        return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('screenshot-ocr-copy')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-ocr-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    // 识别结果弹窗里点“复制全部”才发起剪贴板请求。
    await tester.tap(find.byTooltip('复制全部'));
    await tester.pump();
    await copyPending.future;
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(MethodNames.screenshotChanged, {
          ...snapshot,
          'id': 'second',
        }),
      ),
      (_) {},
    );
    await tester.pump();
    copyReply.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('toolbar-feedback-bubble')), findsNothing);
    expect(find.text('已复制文字'), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
  });
}

/// width/height为图像像素尺寸，默认320×240；返回合成截图PNG。
Future<Uint8List> _image({int width = 320, int height = 240}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFF2255AA), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

/// tester 为测试驱动，name 为通道名；以 960×740 截图、已选中的选区 (200,180,400,300) 装载编辑器。
/// 返回通道、记录全部调用的列表与截图快照，供导出后读取选区或发送新截图（#106）。
Future<
  ({
    MethodChannel channel,
    List<MethodCall> calls,
    Map<String, Object?> snapshot,
  })
>
_pumpSelectedCrop(WidgetTester tester, String name) async {
  tester.view.physicalSize = const Size(960, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final png = await tester.runAsync(() => _image(width: 960, height: 740));
  final channel = MethodChannel(name);
  final calls = <MethodCall>[];
  final snapshot = <String, Object?>{
    'id': 'crop',
    'bytes': png,
    'width': 960,
    'height': 740,
    'capturedAt': 0,
    'cropX': 200,
    'cropY': 180,
    'cropWidth': 400,
    'cropHeight': 300,
    'cropSelected': true,
  };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return call.method == MethodNames.getScreenshot ? snapshot : null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(ScreenshotApp(channel: channel));
  await tester.pumpAndSettle();
  return (channel: channel, calls: calls, snapshot: snapshot);
}

/// tester 为测试驱动，key 为方向键，modifiers 为按住的修饰键，times 为连按次数；发送按键并刷新，无返回值。
Future<void> _arrow(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> modifiers = const [],
  int times = 1,
}) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(key);
  }
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pumpAndSettle();
}

/// tester 为测试驱动，calls 为通道调用记录；点击复制，返回导出图像素尺寸与记住的截图区域。
Future<(Size, Rect)> _copyCrop(
  WidgetTester tester,
  List<MethodCall> calls,
) async {
  calls.clear();
  final copy = find.byKey(const Key(ScreenshotActions.copy));
  await tester.ensureVisible(copy);
  // 导出与 PNG 解码使用真实图像线程。
  final size = await tester.runAsync(() async {
    await tester.tap(copy);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final bytes =
        (calls
                    .firstWhere(
                      (call) => call.method == MethodNames.copyScreenshot,
                    )
                    .arguments
                as Map)['bytes']
            as Uint8List;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    codec.dispose();
    return size;
  });
  await tester.pumpAndSettle();
  final region =
      calls
              .firstWhere(
                (call) => call.method == MethodNames.rememberScreenshotRegion,
              )
              .arguments
          as Map;
  return (
    size!,
    Rect.fromLTWH(
      (region['x'] as num).toDouble(),
      (region['y'] as num).toDouble(),
      (region['width'] as num).toDouble(),
      (region['height'] as num).toDouble(),
    ),
  );
}
