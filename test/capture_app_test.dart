import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/capture/capture_app.dart';
import 'package:translate_app/src/capture/gif_options.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';

/// 无参数；验证工具状态、实际选区与媒体结果中的输入输出和边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object?> state;
  late bool discardConfirmed;

  /// next为原生已发生的状态；模拟平台边界通知并渲染当前帧，无返回值。
  Future<void> notify(WidgetTester tester, Map<String, Object?> next) async {
    state = next;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(MethodNames.captureStateChanged, state),
      ),
      (_) {},
    );
    await tester.pump();
  }

  setUp(() {
    state = {'id': 'session', 'phase': 'idle'};
    discardConfirmed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.setCapturePaused) {
        final paused = (call.arguments as Map)['paused'] == true;
        state = {...state, 'phase': paused ? 'paused' : state['kind']};
      }
      if (call.method == MethodNames.stopCapture &&
          ['recording', 'scrolling', 'paused'].contains(state['phase'])) {
        state = {...state, 'phase': 'finalizing'};
      }
      if (call.method == MethodNames.cancelCapture && discardConfirmed) {
        state = {'id': 'new-session', 'phase': 'idle'};
      }
      return state;
    });
    // Widget测试只替换系统平台视图边界；媒体生命周期由原生测试覆盖。
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  test('GIF输入边界与有界帧数遵循实际片段时长', () {
    // 60秒×30fps恰好1800帧；多0.01秒需要第1801帧，应提示缩短。
    const exact = GifOptions(start: 0, end: 60, fps: 30, width: 640);
    expect(exact.validate(duration: 61, sourceWidth: 640), isNull);
    expect(exact.frameCount, 1800);
    expect(
      const GifOptions(
        start: 0,
        end: 60.01,
        fps: 30,
        width: 640,
      ).validate(duration: 61, sourceWidth: 640),
      contains('1800'),
    );
    for (final options in [
      const GifOptions(start: 0, end: 0, fps: 10, width: 640),
      const GifOptions(start: -0.1, end: 1, fps: 10, width: 640),
      const GifOptions(start: double.nan, end: 1, fps: 10, width: 640),
      const GifOptions(start: 0, end: double.infinity, fps: 10, width: 640),
      const GifOptions(start: 0, end: 1.01, fps: 10, width: 640),
      const GifOptions(start: 0, end: 1, fps: 31, width: 640),
      const GifOptions(start: 0, end: 1, fps: 0, width: 640),
      const GifOptions(start: 0, end: 1, fps: 10, width: 641),
      const GifOptions(start: 0, end: 1, fps: 10, width: 0),
    ]) {
      expect(options.validate(duration: 1, sourceWidth: 640), isNotNull);
    }
    const partial = GifOptions(start: 0.21, end: 0.84, fps: 10, width: 320);
    expect(partial.frameCount, 7);
    // 0.8-0.2存在二进制浮点余量，半开片段只能采样0.2到0.7共六帧。
    expect(
      const GifOptions(start: 0.2, end: 0.8, fps: 10, width: 32).frameCount,
      6,
    );
  });

  testWidgets('两种采集共用三按钮，暂停恢复保留内容且放弃确认可取消', (tester) async {
    // 320×48为最小悬浮条；两种内容均验证暂停→恢复、取消放弃→保留、结束→锁定和确认放弃→空闲。
    tester.view.physicalSize = const Size(320, 48);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final kind in ['recording', 'scrolling']) {
      await tester.pumpWidget(const SizedBox.shrink());
      discardConfirmed = false;
      state = {
        'id': kind,
        'kind': kind,
        'phase': kind,
        'elapsed': 65.0,
        'height': 512,
      };
      await tester.pumpWidget(const CaptureApp(channel: channel));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNWidgets(3));
      final label = kind == 'recording' ? '录制 1:05' : '长截图 512 像素';
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停 · $label'), findsOneWidget);
      expect(find.byTooltip('开始'), findsOneWidget);
      await tester.tap(find.byTooltip('放弃'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停 · $label'), findsOneWidget);
      await tester.tap(find.byTooltip('开始'));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.byTooltip('结束'));
      await tester.pumpAndSettle();
      expect(find.text('正在完成采集…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.stop))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.pause))
            .onPressed,
        isNull,
      );
      discardConfirmed = true;
      await tester.tap(find.byTooltip('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('GIF参数按需展开，进度保留草稿且非法片段禁用导出', (tester) async {
    // 非整数结束时间保持源精度；同一会话的进度与取消不得重置用户输入。
    state = {
      'id': 'video',
      'phase': 'videoReady',
      'duration': 1.234567,
      'width': 640,
      'height': 480,
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppKitView &&
            widget.viewType == ChannelNames.captureVideoPreview,
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('导出 GIF…'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, '1.234567');
    await tester.ensureVisible(fields.at(0));
    await tester.enterText(fields.at(0), '0.4');
    await tester.enterText(fields.at(1), '0.2');
    await tester.pump();
    final export = find.widgetWithText(FilledButton, '导出 GIF');
    expect(tester.widget<FilledButton>(export).onPressed, isNull);
    expect(find.textContaining('开始 < 结束'), findsOneWidget);
    await tester.enterText(fields.at(1), '1.2');
    await tester.pump();
    expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
    await notify(tester, {...state, 'phase': 'converting', 'progress': 0.5});
    expect(find.text('正在转换 50%'), findsOneWidget);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '0.4');
    expect(tester.widget<FilledButton>(export).onPressed, isNull);
    await notify(tester, {
      ...state,
      'phase': 'videoReady',
      'error': 'GIF转换已取消，源视频保持不变。',
    });
    expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
    // 取消提示位于结果页顶部；数值编辑已滚动页面，先回到提示所在视口。
    await tester.drag(find.byType(ListView), const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(find.textContaining('源视频保持不变'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('截图组入口沿用用户重新裁剪的区域，录制菜单保留三种目标', (tester) async {
    // 从320×240中框选中央160×120；录制确认与长截图直启均保留当前区域。
    final png = await tester.runAsync(_selectionImage);
    const selectionChannel = MethodChannel('test/toolbar-capture');
    Map? selected;
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'toolbar-selection',
          'bytes': png,
          'width': 320,
          'height': 240,
          'canCaptureMedia': true,
        };
      }
      if (call.method == MethodNames.prepareCapture) {
        final arguments = call.arguments as Map;
        if (arguments['scrolling'] == true) {
          selected = arguments;
          return <String, Object?>{};
        }
        return {'selectionOnly': arguments['kind'] == 'region'};
      }
      if (call.method == MethodNames.confirmCaptureRegion) {
        selected = call.arguments as Map;
      }
      if (call.method == MethodNames.closeScreenshot) {
        // 模拟真实关闭后的空快照，防止菜单取消意外销毁编辑画面却被测试忽略。
        await messenger.handlePlatformMessage(
          selectionChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(
              MethodNames.screenshotChanged,
              <String, Object?>{},
            ),
          ),
          (_) {},
        );
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    for (final scrolling in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
      await tester.dragFrom(
        canvas.topLeft + Offset(canvas.width / 4, canvas.height / 4),
        Offset(canvas.width / 2, canvas.height / 2),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('截图'), findsOneWidget);
      final attributes = find.byKey(const Key('screenshot-attributes-row'));
      expect(
        find.descendant(of: attributes, matching: find.byTooltip('录制')),
        findsOneWidget,
      );
      if (scrolling) {
        await tester.tap(find.byKey(const Key(ScreenshotActions.scrolling)));
      } else {
        await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
        await tester.pumpAndSettle();
        expect(find.text('全屏…'), findsOneWidget);
        expect(find.text('窗口…'), findsOneWidget);
        // 三级菜单必须拥有自己的材料面，不能借用触发器的材料作用域后变透明。
        final menu = find
            .ancestor(
              of: find.text('当前选区'),
              matching: find.byType(NativeGlassSurface),
            )
            .first;
        expect(
          find.descendant(of: menu, matching: find.byType(AppKitView)),
          findsOneWidget,
        );
        // 原生Esc取消菜单后保留冻结帧和裁剪；再次打开后仍可启动同一个选区。
        await messenger.handlePlatformMessage(
          selectionChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(MethodNames.escapePressed),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
        expect(find.text('当前选区'), findsNothing);
        expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
        await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('当前选区'));
      }
      await tester.pumpAndSettle();
      if (!scrolling) await tester.tap(find.byTooltip('开始录制'));
      await tester.pumpAndSettle();
      expect(selected!['x'], closeTo(80, 1));
      expect(selected!['y'], closeTo(60, 1));
      expect(selected!['width'], closeTo(160, 1));
      expect(selected!['height'], closeTo(120, 1));
      expect(find.byTooltip('开始长截图'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('媒体结果图片不能作为屏幕选区启动采集', (tester) async {
    // 结果图片仍能裁剪编辑，但它没有真实冻结帧身份，两个采集入口必须保持禁用。
    final png = await tester.runAsync(_selectionImage);
    const selectionChannel = MethodChannel('test/image-capture-boundary');
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'image-result',
          'bytes': png,
          'width': 320,
          'height': 240,
          'canCaptureMedia': false,
        };
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    await tester.pumpAndSettle();
    for (final action in [
      ScreenshotActions.record,
      ScreenshotActions.scrolling,
    ]) {
      expect(
        tester.widget<IconButton>(find.byKey(Key(action))).onPressed,
        isNull,
      );
    }
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
  });

  testWidgets('直接框选只显示开始与取消，确认使用源像素并锁住未完成操作', (tester) async {
    // 320×240冻结画面置于更大视口；输出仍是源图像素，异步确认不可重复提交。
    final png = await tester.runAsync(_selectionImage);
    const selectionChannel = MethodChannel('test/capture-selection');
    final completion = Completer<void>();
    Map? selected;
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'selection',
          'bytes': png,
          'width': 320,
          'height': 240,
          'selectionOnly': true,
          'cropActive': true,
        };
      }
      if (call.method == MethodNames.confirmCaptureRegion) {
        if (selected != null) {
          throw PlatformException(code: '选区已经失效');
        }
        selected = call.arguments as Map;
        await completion.future;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    await tester.pumpAndSettle();
    final confirm = find.byTooltip('开始录制');
    expect(confirm, findsOneWidget);
    expect(find.byTooltip('保存图片'), findsNothing);
    expect(find.byTooltip('固定区域'), findsNothing);
    await tester.tap(confirm);
    await tester.pump();
    final confirmButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '开始录制',
    );
    expect(tester.widget<IconButton>(confirmButton).onPressed, isNull);
    await tester.tap(confirm);
    expect(selected, containsPair('x', 0.0));
    expect(selected, containsPair('y', 0.0));
    expect(selected, containsPair('width', 320.0));
    expect(selected, containsPair('height', 240.0));
    expect(selected!.containsKey('automatic'), isFalse);
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.text('选区已经失效'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 无参数；创建真实320×240 PNG作为冻结选区输入，返回编码字节并释放图像资源。
Future<Uint8List> _selectionImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 320, 240),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 240);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
