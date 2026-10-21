import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';

/// 无参数；验证截图编辑器的取色、标尺、上传与确认截图动作（#111）。
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

  testWidgets('上传：未配置只提示不发送；确认弹窗显示目标，取消不发送，确认后复制链接', (tester) async {
    // 边界：uploadTarget 为 null 时不出现弹窗、不发出 uploadScreenshot；有目标时弹窗正文含「主机/存储桶」，
    // 点「取消」仍不发送；点「上传」发送导出图并把返回的链接写入剪贴板。
    final editor = await _pumpEditor(tester, 'test/upload');
    final upload = find.byKey(const Key(ScreenshotActions.upload));
    await tester.ensureVisible(upload);
    await tester.tap(upload);
    await tester.pumpAndSettle();
    expect(find.text('未配置上传目标，请在「设置 → 截图 → 上传分享」中填写。'), findsOneWidget);
    expect(find.text('上传截图'), findsNothing);
    expect(editor.uploads, isEmpty);

    editor.target.value = 's3.example.com/shots';
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(upload);
    await tester.pumpAndSettle();
    expect(find.text('将上传到 s3.example.com/shots，并复制分享链接。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(editor.uploads, isEmpty);

    await tester.tap(upload);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '上传'));
    await _settle(tester);
    expect(editor.uploads, hasLength(1));
    expect(editor.uploads.single, isNotEmpty);
    expect(editor.texts, ['https://cdn.example.com/shot.png']);
    expect(find.text('已上传，链接已复制'), findsOneWidget);
    expect(_closes(editor), 0);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('确认截图按设置执行：复制并保存先保存再复制并关闭，改为上传后按上传处理', (tester) async {
    // 边界：快照中的 screenshotConfirmAction 为 copyAndSave 时，确认依次发出保存、复制、关闭；
    // 工具栏变更通知把动作改为 upload 后，确认走上传，未配置目标只提示且不关闭。
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
          PreferenceKeys.screenshotConfirmAction: 'upload',
        }),
      ),
      (_) {},
    );
    await tester.pump(const Duration(seconds: 2));
    await confirm();
    await tester.pumpAndSettle();
    expect(find.text('未配置上传目标，请在「设置 → 截图 → 上传分享」中填写。'), findsOneWidget);
    expect(_closes(editor), 1);
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

/// 截图编辑测试通道：方法调用顺序、复制图片、上传图片、复制文字与可改写的上传目标。
typedef _Editor = ({
  MethodChannel channel,
  List<String> calls,
  List<Uint8List> copies,
  List<Uint8List> uploads,
  List<String> texts,
  ValueNotifier<String?> target,
});

/// editor 为编辑器通道；返回已请求关闭截图的次数。
int _closes(_Editor editor) => editor.calls
    .where((method) => method == MethodNames.closeScreenshot)
    .length;

/// tester 为测试驱动，name 为通道名，confirmAction 为快照中的确认动作（缺省不提供）；
/// 以左半 #3366CC、右半白色的 640×480 截图装载编辑器，返回记录通道调用的 [_Editor]。
/// 上传目标初始为 null，uploadScreenshot 返回固定链接。
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
  final uploads = <Uint8List>[];
  final texts = <String>[];
  final target = ValueNotifier<String?>(null);
  addTearDown(target.dispose);
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
      case MethodNames.uploadTarget:
        return target.value;
      case MethodNames.uploadScreenshot:
        uploads.add(arguments!['bytes'] as Uint8List);
        return 'https://cdn.example.com/shot.png';
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(ScreenshotApp(channel: channel));
  await tester.pumpAndSettle();
  // 编辑器的源图解码使用真实图像线程，取色读取它的像素。
  await tester.runAsync(() => Future<void>.delayed(_decode));
  await tester.pump();
  return (
    channel: channel,
    calls: calls,
    copies: copies,
    uploads: uploads,
    texts: texts,
    target: target,
  );
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
