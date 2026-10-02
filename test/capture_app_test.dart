import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/capture/capture_app.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';

/// 无参数；验证工具状态、实际选区与媒体结果中的输入输出和边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object?> state;

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
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.setCapturePaused) {
        final paused = (call.arguments as Map)['paused'] == true;
        state = {...state, 'phase': paused ? 'paused' : state['kind']};
      }
      if (call.method == MethodNames.stopCapture &&
          ['recording', 'scrolling', 'paused'].contains(state['phase'])) {
        state = {...state, 'phase': 'finalizing'};
      }
      if (call.method == MethodNames.cancelCapture) {
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

  testWidgets('两种采集共用四个独立气泡，上方提示且暂停放弃保持契约', (tester) async {
    // 320×84包含36pt上方提示空间；验证四个独立材料及两种内容的暂停、放弃、结束边界。
    tester.view.physicalSize = const Size(320, 84);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final kind in ['recording', 'scrolling']) {
      await tester.pumpWidget(const SizedBox.shrink());
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
      final label = kind == 'recording' ? '录制：1:05' : '长截图：512 像素';
      expect(find.byType(AppKitView), findsNWidgets(4));
      for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) {
        expect(tooltip.preferBelow, isFalse);
      }
      expect(find.text(label), findsOneWidget);
      // 84pt高面板只保留36pt提示区；长错误文字必须限制在气泡外，首击操作始终可命中。
      await notify(tester, {
        ...state,
        'error': '相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。',
      });
      final feedback = find.byKey(const Key('toolbar-feedback-bubble'));
      final feedbackRect = tester.getRect(feedback);
      expect(feedbackRect.height, greaterThanOrEqualTo(28));
      for (final action in ['暂停', '结束', '放弃']) {
        final button = find.byTooltip(action);
        expect(button.hitTestable(), findsOneWidget);
        expect(feedbackRect.overlaps(tester.getRect(button)), isFalse);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(feedback, findsNothing);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停 · $label'), findsOneWidget);
      expect(find.byTooltip('开始'), findsOneWidget);
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
      await tester.tap(find.byTooltip('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('视频结果等比显示源逻辑尺寸且四个操作在右侧纵向排列', (tester) async {
    // 1706×868源像素来自2倍屏，1200×900视口足以按853×434逻辑尺寸完整显示。
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'video-result',
      'phase': 'videoReady',
      'duration': 9.45,
      'width': 1706,
      'height': 868,
      'previewScale': 2.0,
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    final video = find.byWidgetPredicate(
      (widget) =>
          widget is AppKitView &&
          widget.viewType == ChannelNames.captureVideoPreview,
    );
    expect(tester.getSize(video), const Size(853, 434));
    expect(find.byType(IconButton), findsNWidgets(4));
    // 右侧四操作的32pt命中区保持12pt间距，且完整位于视口、不覆盖媒体。
    final viewport = Offset.zero & const Size(1200, 900);
    final media = tester.getRect(video);
    Rect? previous;
    for (final action in ['播放视频', '保存 MP4', '导出 GIF', '关闭当前采集']) {
      expect(find.byTooltip(action).hitTestable(), findsOneWidget);
      final button = tester.getRect(find.byTooltip(action));
      expect(viewport.contains(button.topLeft), isTrue);
      expect(viewport.contains(button.bottomRight), isTrue);
      expect(media.overlaps(button), isFalse);
      expect(button.left, greaterThan(media.right));
      if (previous != null) {
        expect(button.left, previous.left);
        expect(button.top - previous.bottom, 12);
      }
      previous = button;
    }
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'NativeGlassWindowPage',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('受限视频窗口为工具栏保留完整外边距且不裁剪媒体', (tester) async {
    // 原生窗口在右侧预留72pt；超大视频应等比缩小，并保留8pt上下外边距。
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'large-video',
      'phase': 'videoReady',
      'duration': 5.0,
      'width': 3840,
      'height': 2160,
      'previewScale': 1.0,
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    final media = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppKitView &&
            widget.viewType == ChannelNames.captureVideoPreview,
      ),
    );
    expect(media.width / media.height, closeTo(16 / 9, 0.001));
    expect(media.top, greaterThanOrEqualTo(8));
    for (final action in ['播放视频', '保存 MP4', '导出 GIF', '关闭当前采集']) {
      final rect = tester.getRect(find.byTooltip(action));
      expect(rect.left, greaterThan(media.right));
      expect(rect.right, lessThanOrEqualTo(892));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(rect.bottom, lessThanOrEqualTo(592));
      expect(find.byTooltip(action).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭与Escape单击放弃，转换中仍能关闭', (tester) async {
    // 关闭即丢弃会话；覆盖转换中关闭以及默认窗口最小尺寸73×196pt。
    tester.view.physicalSize = const Size(73, 196);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'closing-result',
      'phase': 'videoReady',
      'duration': 3.0,
      'width': 32,
      'height': 1000,
      'previewScale': 1.0,
    };
    final resultState = Map<String, Object?>.of(state);
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭当前采集'));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
    expect(tester.takeException(), isNull);
    // 新结果按一次Escape即可清理；不要求第二次键盘或确认输入。
    await notify(tester, resultState);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
    tester.view.physicalSize = const Size(900, 600);
    await notify(tester, {
      ...resultState,
      'id': 'closing-conversion',
      'phase': 'converting',
      'progress': 0.5,
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭当前采集'));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GIF直接导出全视频，取消和保存反馈在工具栏外仅停留一秒', (tester) async {
    // 非整数源时长由原生元数据决定；结果页不再要求用户重复输入尺寸和片段。
    state = {
      'id': 'video',
      'phase': 'videoReady',
      'previewScale': 1.0,
      'duration': 1.234567,
      'width': 640,
      'height': 480,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.exportRecordingGIF) {
        state = {...state, 'phase': 'converting', 'progress': 0.5};
      }
      if (call.method == MethodNames.cancelGIFExport) {
        state = {...state, 'phase': 'videoReady', 'error': 'GIF转换已取消，源视频保持不变。'};
      }
      if (call.method == MethodNames.saveRecording) {
        state = {
          ...state,
          'error': null,
          'savedPath': '/截图/视频/2026-10-01/录屏.mp4',
        };
      }
      return state;
    });
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('导出 GIF'));
    await tester.pumpAndSettle();
    expect(find.text('正在转换 50%'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('取消转换'));
    await tester.pump();
    final bubble = find.byKey(const Key('toolbar-feedback-bubble'));
    expect(find.textContaining('源视频保持不变'), findsOneWidget);
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      final target = find.byTooltip(button.tooltip!);
      expect(tester.getRect(bubble).overlaps(tester.getRect(target)), isFalse);
      expect(target.hitTestable(), findsOneWidget);
    }
    await tester.pump(const Duration(milliseconds: 999));
    expect(bubble, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(bubble, findsNothing);
    await tester.tap(find.byTooltip('保存 MP4'));
    await tester.pump();
    expect(find.text('已保存 MP4'), findsOneWidget);
    expect(
      tester.getRect(bubble).overlaps(tester.getRect(find.byTooltip('保存 MP4'))),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(bubble, findsNothing);
    expect(find.byTooltip('播放视频').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('截图组动态目标行沿用裁剪区域，取消准备保留编辑', (tester) async {
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
        selected = call.arguments as Map;
        return null;
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
        expect(find.byTooltip('全屏'), findsOneWidget);
        expect(find.byTooltip('窗口'), findsOneWidget);
        final targetRow = find.byKey(const Key('recording-targets-row'));
        expect(targetRow, findsOneWidget);
        expect(
          find.descendant(of: targetRow, matching: find.byType(AppKitView)),
          findsNWidgets(5),
        );
        // 原生Esc收起目标行后保留冻结帧和裁剪；再次展开仍可启动同一个选区。
        await messenger.handlePlatformMessage(
          selectionChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(MethodNames.escapePressed),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('recording-targets-row')), findsNothing);
        expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
        await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('当前选区'));
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

  testWidgets('窗口目标增加应用图标行，切换清空选择且长列表可滚动访问', (tester) async {
    // 320pt窄屏与25个应用超过可见行宽；验证真实控件选择、命中与提交目标，不检查下游调用次数。
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_selectionImage);
    const sourceChannel = MethodChannel('test/application-toolbar');
    final semantics = tester.ensureSemantics();
    Map? submitted;
    messenger.setMockMethodCallHandler(sourceChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'apps',
          'captureDisplayX': -100,
          'captureDisplayY': -50,
          'bytes': png,
          'width': 320,
          'height': 240,
          'canCaptureMedia': true,
          'displayWidth': 320,
          'displayHeight': 600,
          'toolbarSafeX': 0,
          'toolbarSafeY': 24,
          'toolbarSafeWidth': 320,
          'toolbarSafeHeight': 528,
        };
      }
      if (call.method == MethodNames.captureSources) {
        return [
          for (var index = 0; index < 25; index++)
            {
              'applicationID': 'app.$index',
              'name': index == 0 ? '当前应用' : '应用$index',
              if (index != 1) 'icon': png,
              'windows': [
                {'x': -60.0, 'y': -30.0, 'width': 120.0, 'height': 80.0},
              ],
            },
        ];
      }
      if (call.method == MethodNames.prepareCapture) {
        submitted = call.arguments as Map;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sourceChannel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: sourceChannel));
    await tester.pumpAndSettle();
    final canvasBefore = tester.getRect(
      find.byKey(const Key('screenshot-canvas')),
    );
    await tester.tap(find.byTooltip('录制'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('窗口'));
    await tester.pumpAndSettle();
    final apps = find.byKey(const Key('recording-applications-row'));
    expect(apps, findsOneWidget);
    expect(find.byTooltip('当前应用').hitTestable(), findsOneWidget);
    expect(find.byTooltip('应用1'), findsOneWidget);
    expect(
      find.descendant(of: apps, matching: find.byIcon(Icons.apps)),
      findsOneWidget,
    );

    /// 无参数；返回当前开始按钮，用真实启用状态验证目标选择边界。
    IconButton startButton() => tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '开始录制',
      ),
    );
    expect(startButton().onPressed, isNull);
    await tester.tap(find.byTooltip('当前应用'));
    await tester.pumpAndSettle();
    expect(startButton().onPressed, isNotNull);
    expect(tester.getSemantics(find.byTooltip('当前应用')).label, contains('当前应用'));
    // 负坐标显示器上的应用窗口仍映射到当前显示画布；整个画布为实际录制区域。
    final preview =
        tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((widget) => widget.painter)
                .singleWhere(
                  (painter) => painter.runtimeType.toString() == '_DimPainter',
                )
            as dynamic;
    expect(preview.cropDisplay, canvasBefore);
    expect(preview.showHandles, isFalse);
    expect(preview.windows, [
      Rect.fromLTWH(
        canvasBefore.left + canvasBefore.width / 8,
        canvasBefore.top + canvasBefore.height / 12,
        canvasBefore.width * 3 / 8,
        canvasBefore.height / 3,
      ),
    ]);
    final safe = const Rect.fromLTWH(0, 24, 320, 528);
    for (final row in [apps, find.byKey(const Key('recording-targets-row'))]) {
      final rect = tester.getRect(row);
      expect(safe.contains(rect.topLeft), isTrue);
      expect(safe.contains(rect.bottomRight), isTrue);
    }
    await tester.drag(apps, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('应用24').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('应用24'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始录制'));
    await tester.pumpAndSettle();
    expect(submitted?['kind'], 'application');
    expect(submitted?['applicationID'], 'app.24');
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    final fullscreen =
        tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((widget) => widget.painter)
                .singleWhere(
                  (painter) => painter.runtimeType.toString() == '_DimPainter',
                )
            as dynamic;
    expect(fullscreen.cropDisplay, canvasBefore);
    expect(fullscreen.windows, isNull);

    expect(apps, findsNothing);
    await tester.tap(find.byTooltip('窗口'));
    await tester.pumpAndSettle();
    expect(apps, findsOneWidget);
    expect(startButton().onPressed, isNull);
    expect(
      tester.getRect(find.byKey(const Key('screenshot-canvas'))),
      canvasBefore,
    );
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('长图结果保留来源逻辑宽度并等比滚动，只提供保存复制放弃', (tester) async {
    // 200×2000像素来自2x屏幕，逻辑宽100、高1000；800×600视口不能放大或压扁，右侧只有三枚操作。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(
      () => _selectionImage(width: 200, height: 2000),
    );
    String? copiedId;
    String? savedName;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getCaptureState) return state;
      if (call.method == MethodNames.copyScreenshot) {
        copiedId = (call.arguments as Map)['id'] as String;
        return state;
      }
      if (call.method == MethodNames.saveScreenshot) {
        savedName = (call.arguments as Map)['name'] as String;
        state = {...state, 'savedPath': '/截图/2026-10-02/$savedName'};
        return state;
      }
      return state;
    });
    state = {
      'id': 'long-image',
      'phase': 'imageReady',
      'kind': 'scrolling',
      'width': 200,
      'height': 2000,
      'previewScale': 2.0,
      'imageBytes': png,
      'warning': '相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。',
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pump();
    final preview = find.byKey(const Key('long-image-preview'));
    expect(tester.getSize(preview), const Size(100, 1000));
    expect(find.textContaining('相邻画面缺少稳定的重叠内容'), findsOneWidget);
    expect(find.byTooltip('复制图片'), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
    tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('long-image-scroll')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .jumpTo(400);
    await tester.pump();
    expect(tester.getSize(preview), const Size(100, 1000));
    // 视口上边距8pt，滚动400后预览顶边为-392，源逻辑尺寸不变。
    expect(tester.getTopLeft(preview).dy, -392);
    Rect? previous;
    for (final action in ['保存', '复制', '放弃']) {
      expect(find.byTooltip(action).hitTestable(), findsOneWidget);
      final button = tester.getRect(find.byTooltip(action));
      expect(button.left, greaterThan(tester.getRect(preview).right));
      if (previous != null) {
        expect(button.left, previous.left);
        expect(button.top - previous.bottom, 12);
      }
      previous = button;
    }
    await tester.tap(find.byTooltip('复制'));
    await tester.pump();
    expect(copiedId, 'long-image');
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('相邻画面缺少稳定的重叠内容'), findsNothing);
    await tester.tap(find.byTooltip('保存'));
    await tester.pump();
    expect(savedName, startsWith('截图_'));
    expect(savedName, endsWith('.png'));
    expect(find.text('已保存截图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('媒体结果图片不能作为屏幕选区启动采集', (tester) async {
    // 没有冻结帧身份的图片仍可留在编辑器里，但两个采集入口必须保持禁用。
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

  testWidgets('全屏选区准备按钮使用独立材料且保持可点，开始提交源像素并防重复', (tester) async {
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
          'canCaptureMedia': true,
          'cropActive': true,
        };
      }
      if (call.method == MethodNames.prepareCapture) {
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
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    final confirm = find.byTooltip('开始录制');
    expect(confirm, findsOneWidget);
    final targetRow = find.byKey(const Key('recording-targets-row'));
    expect(
      find.descendant(of: targetRow, matching: find.byType(AppKitView)),
      findsNWidgets(5),
    );
    final screen =
        Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final tooltip in ['开始录制', '取消录制']) {
      final rect = tester.getRect(find.byTooltip(tooltip));
      expect(screen.contains(rect.topLeft), isTrue);
      expect(screen.contains(rect.bottomRight), isTrue);
      expect(rect.size, const Size(32, 32));
      expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
    }
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

/// width/height为源像素尺寸；返回真实PNG，供冻结画面和长图结果验证。
Future<Uint8List> _selectionImage({int width = 320, int height = 240}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
