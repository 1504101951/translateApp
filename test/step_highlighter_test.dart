import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/drawing_metrics.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/common/constants/screenshot_enums.dart';
import 'package:translate_app/src/screenshot/drawing_preferences.dart';
import 'package:translate_app/src/screenshot/drawing_style.dart';
import 'package:translate_app/src/screenshot/edit_document.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';

/// 无参数；验证步骤编号的推导、样式与放置，以及荧光笔的半透明叠加与默认样式（#107）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('编号按标注顺序推导：撤销、重做与删除中间标记后其余编号随顺序更新', () async {
    // 边界：中间夹一个矩形不占编号；撤销最后一个后只剩 1、2，重做恢复 3；
    // 删除第 2 个后第 3 个前移为 2，撤销删除后回到原位置与原编号。
    final doc = EditDocument()..loadCapture(await _png(64, 64), 64, 64);
    String step(double x) => doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.step,
        bounds: Rect.fromCircle(center: Offset(x, 32), radius: 14),
      ),
    );
    final first = step(16);
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: const Rect.fromLTWH(0, 0, 8, 8),
      ),
    );
    final second = step(32);
    final third = step(48);
    expect(stepNumbers(doc.annotations), {first: 1, second: 2, third: 3});
    doc.undo();
    expect(stepNumbers(doc.annotations), {first: 1, second: 2});
    doc.redo();
    expect(stepNumbers(doc.annotations), {first: 1, second: 2, third: 3});
    doc.removeAnnotation(second);
    expect(stepNumbers(doc.annotations), {first: 1, third: 2});
    doc.undo();
    expect(stepNumbers(doc.annotations), {first: 1, second: 2, third: 3});
  });

  test('编号为实心圆，数字按圆亮度取白或黑，三位数缩小后宽度不超过直径 80%', () async {
    // 边界：蓝色（亮度低）配白字、黄色 #FFCC00（亮度约 0.66 > 0.5）配黑字；
    // 第 100 个标记的三位数字原字号会超出 22.4px，缩小后像素宽度不超过 23px（含抗锯齿 1px）。
    final doc = EditDocument()..loadCapture(await _png(96, 64), 96, 64);
    final blue = Rect.fromCircle(center: const Offset(20, 32), radius: 14);
    final yellow = Rect.fromCircle(center: const Offset(76, 32), radius: 14);
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.step,
        bounds: blue,
        color: const Color(0xFF0000FF),
      ),
    );
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.step,
        bounds: yellow,
        color: const Color(0xFFFFCC00),
      ),
    );
    var pixels = await _rgba(await doc.renderPng(), 96);
    expect(pixels(8, 32), [0, 0, 255]);
    expect(pixels(64, 32), [255, 204, 0]);
    expect(_inside(blue, pixels).any((p) => _light(p.rgb)), isTrue);
    expect(_inside(yellow, pixels).any((p) => _dark(p.rgb)), isTrue);
    expect(_inside(yellow, pixels).any((p) => _light(p.rgb)), isFalse);

    // 前 98 个标记叠在左侧圆下，最上层的第 100 个画在右侧。
    for (var i = 2; i < 99; i++) {
      doc.addAnnotation(
        EditAnnotation(
          id: '',
          kind: AnnotationKind.step,
          bounds: blue,
          color: const Color(0xFF0000FF),
        ),
      );
    }
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.step,
        bounds: yellow,
        color: const Color(0xFF0000FF),
      ),
    );
    expect(stepNumbers(doc.annotations).values.last, 100);
    pixels = await _rgba(await doc.renderPng(), 96);
    final digits = [
      for (final (:x, :rgb) in _inside(yellow, pixels))
        if (_light(rgb)) x,
    ];
    expect(digits, isNotEmpty);
    final width =
        digits.reduce((a, b) => a > b ? a : b) -
        digits.reduce((a, b) => a < b ? a : b) +
        1;
    expect(width, lessThanOrEqualTo(23));
  });

  test('荧光笔以 40% 不透明度叠加：同一笔重叠不加深，不同笔叠加加深，黑字仍为深色', () async {
    // 边界：白底上黄色 #FFCC00 的 40% 混合为 (255,235,153)；同一笔来回经过同一像素结果不变；
    // 第二笔交叉处再混合一次为 (255,223,92)；黑色区域只得到 (102,82,0)，仍远暗于高亮背景。
    final doc = EditDocument()
      ..loadCapture(await _png(40, 40, blackFrom: 20), 40, 40);
    EditAnnotation highlight(List<Offset> points) => EditAnnotation(
      id: '',
      kind: AnnotationKind.stroke,
      shapeMode: ShapeMode.highlighter,
      color: const Color(0xFFFFCC00),
      strokeWidth: 10,
      bounds: Rect.fromPoints(points.first, points[1]),
      points: points,
    );
    doc.addAnnotation(
      highlight(const [Offset(2, 10), Offset(38, 10), Offset(2, 11)]),
    );
    doc.addAnnotation(highlight(const [Offset(2, 28), Offset(18, 28)]));
    doc.addAnnotation(highlight(const [Offset(10, 20), Offset(10, 38)]));
    final pixels = await _rgba(await doc.renderPng(), 40);
    _expectNear(pixels(10, 10), [255, 235, 153]);
    _expectNear(pixels(30, 10), [102, 82, 0]);
    _expectNear(pixels(2, 28), [255, 235, 153]);
    _expectNear(pixels(10, 28), [255, 223, 92]);
    _expectNear(pixels(10, 2), [255, 255, 255]);
  });

  test('荧光笔与编号使用独立默认样式，修改后随偏好往返且不影响普通画笔', () {
    // 边界：荧光笔未调整时为黄色 16pt，而非普通画笔的红色 3pt；编号默认红色且支持颜色、不支持粗细。
    final defaults = DrawingPreferences();
    final highlighter = defaults.styleFor(
      ScreenshotTool.brush,
      brushMode: ShapeMode.highlighter,
    );
    expect(highlighter.color, DrawingMetrics.highlighterColor);
    expect(highlighter.strokeWidth, DrawingMetrics.highlighterWidth);
    expect(
      defaults.styleFor(ScreenshotTool.step).color,
      const Color(0xFFFF3B30),
    );
    expect(supportsDrawingColor(ScreenshotTool.step, ShapeMode.solid), isTrue);
    expect(supportsStrokeWidth(ScreenshotTool.step), isFalse);
    expect(
      supportsDrawingColor(ScreenshotTool.brush, ShapeMode.highlighter),
      isTrue,
    );

    final edited = defaults
        .copyWith(
          tool: ScreenshotTool.brush,
          brushMode: ShapeMode.highlighter,
          style: const DrawingStyle(color: Color(0xFF34C759), strokeWidth: 12),
        )
        .copyWith(
          tool: ScreenshotTool.step,
          style: const DrawingStyle(color: Color(0xFF007AFF)),
        );
    final restored = DrawingPreferences.fromMap(edited.toMap());
    expect(restored.brushMode, ShapeMode.highlighter);
    final restoredHighlighter = restored.styleFor(ScreenshotTool.brush);
    expect(restoredHighlighter.color, const Color(0xFF34C759));
    expect(restoredHighlighter.strokeWidth, 12);
    final solid = restored.styleFor(
      ScreenshotTool.brush,
      brushMode: ShapeMode.solid,
    );
    expect(solid.color, const Color(0xFFFF3B30));
    expect(solid.strokeWidth, 3);
    expect(
      restored.styleFor(ScreenshotTool.step).color,
      const Color(0xFF007AFF),
    );
  });

  testWidgets('编号工具连续单击放置标记不触发双击复制，拖动在松开处放置，撤销移除最后一个', (tester) async {
    // 边界：两次单击间不推进时间，若仍识别双击会复制并关闭截图；拖动从 (300,200) 到 (340,200)，
    // 标记圆心在松开处，起点附近保持原图；⌘Z 只移除最后放置的标记。
    final channel = await _pumpEditor(tester, 'test/step-tool');
    await tester.tap(find.byKey(const Key(ScreenshotActions.step)));
    await tester.pumpAndSettle();
    for (final x in [100.0, 160.0, 220.0]) {
      await tester.tapAt(Offset(x, 100));
      await tester.pump();
    }
    await tester.dragFrom(const Offset(300, 200), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    expect(channel.copies, isEmpty);

    var pixels = await _copyPixels(tester, channel);
    for (final x in [90, 150, 210]) {
      expect(pixels(x, 100), [255, 59, 48], reason: '标记 x=$x');
    }
    expect(pixels(330, 200), [255, 59, 48]);
    expect(pixels(290, 200), [255, 255, 255]);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    pixels = await _copyPixels(tester, channel);
    expect(pixels(330, 200), [255, 255, 255]);
    expect(pixels(210, 100), [255, 59, 48]);
    // 等待复制反馈计时结束，避免遗留计时器。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('画笔第二行选择荧光笔后按默认黄色 16pt 半透明绘制', (tester) async {
    // 边界：16pt 轨迹半宽 8px，距中线 6px 已高亮、11px 仍为原图；高亮像素为白底 40% 黄色。
    final channel = await _pumpEditor(tester, 'test/highlighter');
    await tester.tap(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.pumpAndSettle();
    final mode = find.byKey(
      const Key('${ScreenshotActions.brushPrefix}highlighter'),
    );
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key(ScreenshotActions.palette)), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.width)), findsOneWidget);
    await tester.dragFrom(const Offset(80, 120), const Offset(300, 0));
    await tester.pumpAndSettle();

    final pixels = await _copyPixels(tester, channel);
    _expectNear(pixels(200, 120), [255, 235, 153]);
    _expectNear(pixels(200, 126), [255, 235, 153]);
    expect(pixels(200, 131), [255, 255, 255]);
    await tester.pump(const Duration(seconds: 2));
  });
}

/// 截图编辑测试通道及其收到的复制图片。
typedef _Editor = ({MethodChannel channel, List<Uint8List> copies});

/// tester 为测试驱动，name 为通道名；以 640×480 白色截图装载编辑器，返回通道与复制记录。
Future<_Editor> _pumpEditor(WidgetTester tester, String name) async {
  tester.view.physicalSize = const Size(640, 480);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final png = await tester.runAsync(() => _png(640, 480));
  final channel = MethodChannel(name);
  final copies = <Uint8List>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == MethodNames.getScreenshot) {
      return {
        'id': 'annotate',
        'bytes': png,
        'width': 640,
        'height': 480,
        'capturedAt': 0,
      };
    }
    if (call.method == MethodNames.copyScreenshot) {
      copies.add((call.arguments as Map)['bytes'] as Uint8List);
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(ScreenshotApp(channel: channel));
  await tester.pumpAndSettle();
  return (channel: channel, copies: copies);
}

/// tester 为测试驱动，editor 为编辑器通道；点击复制并返回导出图的像素读取函数。
Future<List<int> Function(int x, int y)> _copyPixels(
  WidgetTester tester,
  _Editor editor,
) async {
  final copy = find.byKey(const Key(ScreenshotActions.copy));
  await tester.ensureVisible(copy);
  // 导出与 PNG 解码使用真实图像线程。
  final pixels = await tester.runAsync(() async {
    await tester.tap(copy);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return _rgba(editor.copies.last, 640);
  });
  await tester.pumpAndSettle();
  return pixels!;
}

/// width/height 为像素尺寸，blackFrom 为从该列起涂黑（缺省全白）；返回合成 PNG。
Future<Uint8List> _png(int width, int height, {int? blackFrom}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
  if (blackFrom != null) {
    canvas.drawRect(
      Rect.fromLTWH(
        blackFrom.toDouble(),
        0,
        width.toDouble(),
        height.toDouble(),
      ),
      Paint()..color = const Color(0xFF000000),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

/// bytes 为 PNG，width 为图像宽度；返回按坐标读取 RGB 的函数。
Future<List<int> Function(int x, int y)> _rgba(
  Uint8List bytes,
  int width,
) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  final raw = data!.buffer.asUint8List();
  return (x, y) => raw.sublist((y * width + x) * 4, (y * width + x) * 4 + 3);
}

/// circle 为编号标记外接正方形，pixels 为像素读取函数；返回圆内（内缩 2px 避开抗锯齿边）每个像素的列号与 RGB。
Iterable<({int x, List<int> rgb})> _inside(
  Rect circle,
  List<int> Function(int x, int y) pixels,
) sync* {
  for (var x = circle.left.toInt(); x < circle.right; x++) {
    for (var y = circle.top.toInt(); y < circle.bottom; y++) {
      if ((Offset(x + 0.5, y + 0.5) - circle.center).distance <
          circle.width / 2 - 2) {
        yield (x: x, rgb: pixels(x, y));
      }
    }
  }
}

/// rgb 为像素；返回是否接近白色（数字白字）。
bool _light(List<int> rgb) => rgb.every((value) => value > 200);

/// rgb 为像素；返回是否接近黑色（数字黑字）。
bool _dark(List<int> rgb) => rgb.every((value) => value < 60);

/// actual/expected 为 RGB；在 PNG 往返与混合舍入的 ±2 误差内断言一致。
void _expectNear(List<int> actual, List<int> expected) {
  for (var i = 0; i < 3; i++) {
    expect(
      (actual[i] - expected[i]).abs(),
      lessThanOrEqualTo(2),
      reason: '实际 $actual，期望 $expected',
    );
  }
}
