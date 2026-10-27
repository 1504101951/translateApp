import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';

/// 无参数；验证截图编辑器的取色、标尺与确认截图动作（#111）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('取色：悬停显示指针处色值，单击复制源像素的 #RRGGBB', (tester) async {
    // 边界：截图左半为 #3366CC、右半为白色；悬停与单击在左半，复制值必须等于源像素；
    // 移到右半时标签跟随为 #FFFFFF；取色与标尺默认位于截图的子级行。
    final editor = await _pumpEditor(tester, 'test/eyedropper');
    await tester.tap(find.byKey(const Key(ScreenshotActions.eyedropper)));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(100, 200));
    await mouse.moveTo(const Offset(101, 200));
    // 源像素解码使用真实图像线程。
    await tester.runAsync(() => Future<void>.delayed(_decode));
    await tester.pump();
    expect(find.byKey(const Key('eyedropper-label')), findsOneWidget);
    expect(find.text('#3366CC'), findsOneWidget);
    await mouse.moveTo(const Offset(500, 200));
    await tester.pump();
    expect(find.text('#FFFFFF'), findsOneWidget);

    await tester.tapAt(const Offset(100, 200));
    await _settle(tester);
    expect(editor.texts, ['#3366CC']);
    expect(find.text('已复制 #3366CC'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('标尺：拖动显示长度与 Δx × Δy，测量线不进入导出，切换工具后清除', (tester) async {
    // 边界：从 (100,100) 拖到 (160,180)，Δ 为 60 × 80、长度恰为 100.0 像素（画布与截图 1:1）；
    // 画线前后导出的 PNG 字节完全相同；切回截图工具后标签消失。
    final editor = await _pumpEditor(tester, 'test/ruler');
    await _copy(tester, editor);
    await tester.tap(find.byKey(const Key(ScreenshotActions.ruler)));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(100, 100), const Offset(60, 80));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ruler-label')), findsOneWidget);
    expect(find.text('100.0 px（60 × 80）'), findsOneWidget);
    await _copy(tester, editor);
    expect(editor.copies, hasLength(2));
    expect(editor.copies.last, editor.copies.first);
    await tester.tap(find.byKey(const Key(ScreenshotActions.crop)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ruler-label')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('确认截图按设置执行：复制并保存先保存再复制并关闭，改为复制图片后只复制并关闭', (tester) async {
    // 边界：快照中的 screenshotConfirmAction 为 copyAndSave 时，确认依次发出保存、复制、关闭；
    // 工具栏变更通知把动作改为 copy 后，再次确认只新增复制与关闭，保存次数仍为 1。
    final editor = await _pumpEditor(
      tester,
      'test/confirm-action',
      confirmAction: 'copyAndSave',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();
    Future<void> confirm() => tester.runAsync(() async {
      await messenger.handlePlatformMessage(
        editor.channel.name,
        codec.encodeMethodCall(
          const MethodCall(MethodNames.confirmScreenshot, {'id': 'measure'}),
        ),
        (_) {},
      );
      await Future<void>.delayed(_decode);
    });
    await confirm();
    await tester.pumpAndSettle();
    expect(
      editor.calls.where(
        (method) => {
          MethodNames.saveScreenshot,
          MethodNames.copyScreenshot,
          MethodNames.closeScreenshot,
        }.contains(method),
      ),
      [
        MethodNames.saveScreenshot,
        MethodNames.copyScreenshot,
        MethodNames.closeScreenshot,
      ],
    );

    await messenger.handlePlatformMessage(
      editor.channel.name,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.screenshotToolbarChanged, {
          PreferenceKeys.screenshotConfirmAction: 'copy',
        }),
      ),
      (_) {},
    );
    await tester.pump(const Duration(seconds: 2));
    await confirm();
    await tester.pumpAndSettle();
    expect(
      editor.calls.where((method) => method == MethodNames.saveScreenshot),
      hasLength(1),
    );
    expect(editor.copies, hasLength(2));
    expect(_closes(editor), 2);
    await tester.pump(const Duration(seconds: 2));
  });
}

/// 等待真实图像线程完成解码或编码的时长。
const _decode = Duration(milliseconds: 200);

/// tester 为测试驱动；交替让出真实时间与推进帧，使在测试时钟里发起的图像编解码与后续通道调用完成，无返回值。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(_decode));
    await tester.pump();
  }
}

/// 截图编辑测试通道：方法调用顺序、复制图片与复制文字。
typedef _Editor = ({
  MethodChannel channel,
  List<String> calls,
  List<Uint8List> copies,
  List<String> texts,
});

/// editor 为编辑器通道；返回已请求关闭截图的次数。
int _closes(_Editor editor) => editor.calls
    .where((method) => method == MethodNames.closeScreenshot)
    .length;

/// tester 为测试驱动，name 为通道名，confirmAction 为快照中的确认动作（缺省不提供）；
/// 以左半 #3366CC、右半白色的 640×480 截图装载编辑器，返回记录通道调用的 [_Editor]。
Future<_Editor> _pumpEditor(
  WidgetTester tester,
  String name, {
  String? confirmAction,
}) async {
  tester.view.physicalSize = const Size(640, 480);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final png = await tester.runAsync(_png);
  final channel = MethodChannel(name);
  final calls = <String>[];
  final copies = <Uint8List>[];
  final texts = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call.method);
    final arguments = call.arguments as Map?;
    switch (call.method) {
      case MethodNames.getScreenshot:
        return {
          'id': 'measure',
          'bytes': png,
          'width': 640,
          'height': 480,
          'capturedAt': 0,
          PreferenceKeys.screenshotConfirmAction: ?confirmAction,
        };
      case MethodNames.copyScreenshot:
        copies.add(arguments!['bytes'] as Uint8List);
      case MethodNames.saveScreenshot:
        return '/tmp/截图.png';
      case MethodNames.copyText:
        texts.add(arguments!['text'] as String);
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(ScreenshotApp(channel: channel));
  await tester.pumpAndSettle();
  // 编辑器的源图解码使用真实图像线程，取色读取它的像素。
  await tester.runAsync(() => Future<void>.delayed(_decode));
  await tester.pump();
  return (channel: channel, calls: calls, copies: copies, texts: texts);
}

/// tester 为测试驱动，editor 为编辑器通道；点击复制并等待导出完成，无返回值。
Future<void> _copy(WidgetTester tester, _Editor editor) async {
  final copy = find.byKey(const Key(ScreenshotActions.copy));
  await tester.ensureVisible(copy);
  await tester.runAsync(() async {
    await tester.tap(copy);
    await Future<void>.delayed(_decode);
  });
  await tester.pumpAndSettle();
}

/// 无参数；返回 640×480、左半 #3366CC、右半白色的 PNG。
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 320, 480),
    Paint()..color = const Color(0xFF3366CC),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(640, 480);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}
