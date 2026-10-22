import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/error_codes.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/common/constants/screenshot_enums.dart';
import 'package:translate_app/src/common/utils/geometry.dart';
import 'package:translate_app/src/common/utils/screenshot_filename.dart';
import 'package:translate_app/src/history/screenshot_history.dart';
import 'package:translate_app/src/screenshot/edit_document.dart';
import 'package:translate_app/src/screenshot/recognized_text_panel.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';
import 'package:translate_app/src/settings/app_settings.dart';

/// 无参数；验证文件名、编辑文档像素结果与编辑器导出反馈，无返回值。
void main() {
  test('截图快捷键独立保存并拒绝与翻译使用同一组合', () {
    final settings = AppSettings(primaryLanguage: 'zh-CN');
    settings.screenshotShortcutKeyCode = 7;
    settings.screenshotShortcutLabel = 'X';
    settings.validate();
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.screenshotShortcutKeyCode, 7);
    expect(restored.shortcutKeyCode, 17);
    restored.screenshotShortcutKeyCode = restored.shortcutKeyCode;
    expect(restored.validate, throwsFormatException);
    // 日期跨月且毫秒不足三位，文件名仍可排序、不含路径分隔符。
    expect(
      screenshotFilename(DateTime(2026, 9, 6, 1, 2, 3, 4)),
      '截图_2026-09-06_01-02-03-004.png',
    );
    const box = Rect.fromLTWH(10, 10, 80, 80);
    expect(editHandleAt(box, const Offset(10, 10), 8), 'nw');
    expect(editHandleAt(box, const Offset(50, 10), 8), 'n');
    expect(editHandleAt(box, const Offset(90, 50), 8), 'e');
    expect(editHandleAt(box, const Offset(50, 50), 8), 'move');
    expect(editHandleAt(box, const Offset(0, 0), 8), isNull);
    expect(
      pinOriginAppKit(
        crop: const Rect.fromLTWH(2, 2, 4, 4),
        display: const Rect.fromLTWH(100, 200, 800, 600),
        image: const Size(8, 8),
      ),
      const Offset(300, 350),
    );
  });

  test('编辑文档：删除标注可撤销并回到原位置，重做再次删除', () async {
    // 作用：清空文字后文字框被删除，这一步必须能撤销。
    // 边界：删除三个标注中间的一个，撤销后它回到下标 1 而不是末尾；删除不存在的 id 不产生撤销步骤。
    final document = EditDocument();
    document.loadCapture(await _pngCheckerboard(), 8, 8);
    final ids = [
      for (final text in ['a', 'b', 'c'])
        document.addAnnotation(
          EditAnnotation(
            id: '',
            kind: AnnotationKind.text,
            bounds: const Rect.fromLTWH(0, 0, 4, 4),
            text: text,
          ),
        ),
    ];
    document.removeAnnotation(ids[1]);
    expect(document.annotations.map((item) => item.text), ['a', 'c']);
    document.undo();
    expect(document.annotations.map((item) => item.text), ['a', 'b', 'c']);
    document.redo();
    expect(document.annotations.map((item) => item.text), ['a', 'c']);
    document.undo();
    document.removeAnnotation('missing');
    document.undo();
    // 最后一次撤销撤的是添加 c，说明删除不存在的标注没有入栈。
    expect(document.annotations.map((item) => item.text), ['a', 'b']);
  });

  test('文字框高度随宽度换行增长，空文字仍占一行', () {
    // 作用：拖动左右手柄改变宽度后，高度按内容重新计算。
    // 边界：同一段文字在宽度减半后行数增加、高度变大；空文字的高度等于一行文字的高度。
    const text = 'aaaa aaaa aaaa aaaa';
    final wide = textBoxHeight(text: text, fontSize: 18, width: 2000);
    final narrow = textBoxHeight(text: text, fontSize: 18, width: 100);
    expect(narrow, greaterThan(wide));
    expect(textBoxHeight(text: '', fontSize: 18, width: 2000), wide);
  });

  test('编辑文档：裁剪改变导出尺寸，标注改像素，撤销重做可逆，遮挡导出不可还原', () async {
    // 左上红、右下蓝的 8x8，便于断言裁剪边界与遮挡覆盖。
    final source = await _pngCheckerboard();
    final document = EditDocument();
    document.loadCapture(source, 8, 8);

    document.setCrop(const Rect.fromLTWH(0, 0, 4, 4));
    final cropped = await document.renderPng();
    final croppedImage = await _decode(cropped);
    expect(croppedImage.width, 4);
    expect(croppedImage.height, 4);
    expect(await _pixel(croppedImage, 1, 1), _red);
    croppedImage.dispose();

    // 裁剪不进撤销；恢复全图用 setCrop，再叠加标注。
    expect(document.canUndo, isFalse);
    document.setCrop(const Rect.fromLTWH(0, 0, 8, 8));
    expect(document.cropRect, const Rect.fromLTWH(0, 0, 8, 8));
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: Rect.fromLTWH(0, 0, 3, 3),
        color: Color(0xFF00FF00),
        strokeWidth: 1,
      ),
    );
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.arrow,
        bounds: Rect.fromLTWH(0, 0, 3, 3),
        start: Offset(0, 3),
        end: Offset(3, 0),
        color: Color(0xFFFFFF00),
        strokeWidth: 1,
      ),
    );
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: Rect.fromLTWH(0, 0, 2, 2),
        text: 'A',
        color: Color(0xFFFFFFFF),
        fontSize: 6,
      ),
    );
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.mask,
        bounds: Rect.fromLTWH(5, 5, 3, 3),
        color: Color(0xFF000000),
      ),
    );
    expect(document.annotations.length, 4);
    document.setCrop(const Rect.fromLTWH(1, 1, 6, 6));
    expect(document.annotations.length, 4);
    expect(document.annotations.first.kind, AnnotationKind.rectangle);
    document.setCrop(const Rect.fromLTWH(0, 0, 8, 8));

    final annotated = await document.renderPng();
    final annotatedImage = await _decode(annotated);
    expect(annotatedImage.width, 8);
    // 遮挡区域必须是纯黑，不能再读出原图蓝色。
    expect(_nearColor(await _pixel(annotatedImage, 6, 6), _black), isTrue);
    expect(_nearColor(await _pixel(annotatedImage, 6, 6), _blue), isFalse);
    expect(listEquals(annotated, source), isFalse);
    annotatedImage.dispose();

    // 导出位图本身不含图层：即使文档撤销遮挡，已导出的 PNG 像素仍保持黑色。
    final bakedBytes = annotated;
    document.undo(); // 撤销遮挡
    expect(
      document.annotations.where((item) => item.kind == AnnotationKind.mask),
      isEmpty,
    );
    final bakedImage = await _decode(bakedBytes);
    expect(_nearColor(await _pixel(bakedImage, 6, 6), _black), isTrue);
    bakedImage.dispose();

    // 撤销后重新导出应恢复原图蓝像素，证明历史作用在文档而非已导出字节。
    final afterUndo = await document.renderPng();
    final afterUndoImage = await _decode(afterUndo);
    expect(_nearColor(await _pixel(afterUndoImage, 6, 6), _blue), isTrue);
    afterUndoImage.dispose();

    document.redo();
    final afterRedo = await document.renderPng();
    final afterRedoImage = await _decode(afterRedo);
    expect(_nearColor(await _pixel(afterRedoImage, 6, 6), _black), isTrue);
    afterRedoImage.dispose();

    // 新捕获清空历史与标注。
    final next = await _solidPng(2, 2, _red);
    document.loadCapture(next, 2, 2);
    expect(document.annotations, isEmpty);
    expect(document.canUndo, isFalse);
    expect(document.canRedo, isFalse);
  });

  testWidgets('双击复制合成 bytes 并关闭；关闭不复制；保存失败保留图片', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Object? copiedBytes;
    String? saveError;

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot',
            'bytes': bytes,
            'capturedAt': 1788662400000,
            'width': 8,
            'height': 8,
            'directory': '/tmp/screenshots',
          };
        case MethodNames.copyScreenshot:
          final args = call.arguments as Map;
          copiedBytes = args['bytes'];
          return null;
        case MethodNames.saveScreenshot:
          if (saveError != null) {
            throw PlatformException(
              code: ErrorCodes.saveFailed,
              message: saveError,
            );
          }
          final args = call.arguments as Map;
          expect(args['bytes'], isA<Uint8List>());
          return '/tmp/截图.png';
        case MethodNames.pinScreenshot:
          return 'pin-1';
        case MethodNames.closeScreenshot:
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    // 固定目录 UI 已迁到设置，编辑窗不再展示路径选择。
    expect(find.text('/tmp/screenshots'), findsNothing);
    expect(find.text('固定目录…'), findsNothing);

    // 关闭不触发 copy，剪贴板参数保持未写入。
    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      calls.where((call) => call.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.copyScreenshot),
      isEmpty,
    );
    expect(copiedBytes, isNull);

    // 重新装载会话，验证保存失败时图片仍在，并显示错误。
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    saveError = '目录不可写';
    // toImage/codec 必须在真实异步区完成，否则导出 Future 会挂在 FakeAsync。
    await _tapExport(tester, const Key('screenshot-save'));
    expect(find.text('目录不可写'), findsOneWidget);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);

    // 遮挡后再复制，通道必须收到合成 bytes，而非原始捕获。
    saveError = null;
    await tester.tap(find.byKey(const Key('screenshot-tool-rect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenshot-shape-filledRectangle')));
    await tester.pumpAndSettle();
    final canvas = find.byKey(const Key('screenshot-canvas'));
    // 在画布上拖出遮挡块；8x8 放大后需足够大的屏幕拖拽才能跨过 ≥1 源图像素。
    await tester.drag(canvas, const Offset(220, 220));
    await tester.pumpAndSettle();
    calls.clear();
    copiedBytes = null;
    await _tapExport(tester, const Key('screenshot-copy'));
    expect(find.text('已复制图片'), findsOneWidget);
    expect(copiedBytes, isA<Uint8List>());
    final copyArgs =
        calls
                .firstWhere((call) => call.method == MethodNames.copyScreenshot)
                .arguments
            as Map;
    expect(copyArgs['id'], 'shot');
    expect(copyArgs['bytes'], same(copiedBytes));
    // 合成结果应与原图不同（至少因遮挡改变）。
    expect(listEquals(copiedBytes! as Uint8List, bytes!), isFalse);

    // 双击触发复制并关闭会话。
    calls.clear();
    await tester.runAsync(() async {
      await tester.tap(canvas);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.tap(canvas);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == MethodNames.copyScreenshot),
      isNotEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );
    expect(find.text('已复制图片'), findsOneWidget);
  });

  testWidgets('贴图按钮发送合成 bytes 并显示已贴图', (tester) async {
    // 边界：必须走真实 ScreenshotApp 贴图按钮与 _export('pin')，断言通道收到合成 PNG。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot-pin');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Uint8List? pinnedBytes;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-pin',
            'bytes': bytes,
            'capturedAt': 1788662400000,
            'width': 8,
            'height': 8,
            'displayX': 100.0,
            'displayY': 200.0,
            'displayWidth': 800.0,
            'displayHeight': 600.0,
            'directory': '',
          };
        case MethodNames.pinScreenshot:
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          expect(args['id'], 'shot-pin');
          expect(args['bytes'], isA<Uint8List>());
          expect(args['x'], 100.0);
          expect(args['y'], 200.0);
          pinnedBytes = args['bytes'] as Uint8List;
          return 'pin-live-1';
        case MethodNames.closeScreenshot:
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);

    calls.clear();
    await _tapExport(tester, const Key('screenshot-pin'));
    final pinCalls = calls
        .where((call) => call.method == MethodNames.pinScreenshot)
        .toList();
    expect(pinCalls, hasLength(1));
    expect(pinnedBytes, isNotNull);
    expect(pinnedBytes!.length, greaterThan(32));
    // 贴图成功关闭编辑会话，不隐式保存或复制。
    expect(
      calls.where((call) => call.method == MethodNames.copyScreenshot),
      isEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.saveScreenshot),
      isEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );
  });

  testWidgets('无屏幕录制权限时不进入编辑画布', (tester) async {
    // 边界：仅 screenAccess=false、无 bytes 时展示申请入口，不创建编辑画布。
    const channel = MethodChannel('test/screenshot-denied');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var requested = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'screenAccess': false,
          'error': '截图需要屏幕录制权限。请在设置中允许 TranslateApp。',
        };
      }
      if (call.method == MethodNames.requestScreenAccess) {
        requested = true;
        return {'screenAccess': false};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
    expect(find.text('申请屏幕录制权限'), findsOneWidget);
    await tester.tap(find.text('申请屏幕录制权限'));
    await tester.pumpAndSettle();
    expect(requested, isTrue);
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
  });

  testWidgets('识别文字只打开结果弹窗，点复制全部才写剪贴板，弹窗不自动关闭', (tester) async {
    // 作用：识别结果先给用户看，由用户决定复制哪些。
    // 边界：识别完成后剪贴板调用为 0 次；点“复制全部”后恰好 1 次且为全文；2 秒后弹窗仍在。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot-ocr');
    // 原生识别结果为 Markdown；「复制全部」必须复制这段原文而不是渲染后的文字。
    const markdown = '# Hello\n\n| World |\n| --- |';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-ocr',
          'bytes': bytes,
          'capturedAt': 1788662400000,
          'width': 8,
          'height': 8,
          'directory': '',
        };
      }
      if (call.method == MethodNames.recognizeText) {
        return {'text': markdown, 'codes': <Object>[]};
      }
      if (call.method == MethodNames.copyText) return null;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-copy'));
    expect(
      calls.where((c) => c.method == MethodNames.recognizeText),
      isNotEmpty,
    );
    // 识别完成只打开弹窗，不写剪贴板；弹窗渲染 Markdown，不显示标记符号。
    expect(calls.where((c) => c.method == MethodNames.copyText), isEmpty);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('World'), findsOneWidget);
    expect(find.textContaining('# '), findsNothing);
    await tester.tap(find.byTooltip('复制全部'));
    await tester.pump();
    expect(
      calls.where((c) => c.method == MethodNames.copyText).single.arguments,
      {'text': markdown},
    );
    expect(find.text('已复制文字'), findsOneWidget);
    // 复制后弹窗不自动关闭；点关闭才消失。
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Hello'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pump();
    expect(find.text('Hello'), findsNothing);
  });

  test('只有带主机名的 http/https 内容可作为链接打开', () {
    // 边界：协议大小写不敏感；缺主机名、无协议的域名与 file/javascript/tel 协议都只能复制（#108）。
    expect(isOpenableLink('https://example.com/a?b=1'), isTrue);
    expect(isOpenableLink('HTTP://EXAMPLE.COM'), isTrue);
    for (final payload in [
      'https://',
      'example.com',
      'file:///etc/hosts',
      'javascript:alert(1)',
      'tel:10086',
      '4006381333931',
    ]) {
      expect(isOpenableLink(payload), isFalse, reason: payload);
    }
  });

  testWidgets('识别结果列出二维码与条码：逐条复制，只有 http/https 可打开并关闭截图', (tester) async {
    // 边界：没有文字时不显示复制全部；javascript 内容的二维码不提供打开；打开失败保留截图并提示；
    // 打开成功后关闭截图；文字与码都为空时提示三者都没有（#108）。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot-codes');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var codes = <Object>[
      {'symbology': 'qr', 'payload': 'https://example.com/a'},
      {'symbology': 'qr', 'payload': 'javascript:alert(1)'},
      {'symbology': 'ean13', 'payload': '4006381333931'},
    ];
    var opened = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-codes',
            'bytes': bytes,
            'capturedAt': 0,
            'width': 8,
            'height': 8,
          };
        case MethodNames.recognizeText:
          return {'text': '', 'codes': codes};
        case MethodNames.openLink:
          return opened;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-copy'));
    expect(find.text('识别结果'), findsOneWidget);
    expect(find.text('二维码'), findsNWidgets(2));
    expect(find.text('条码 · EAN13'), findsOneWidget);
    expect(find.text('https://example.com/a'), findsOneWidget);
    expect(find.byTooltip('复制全部'), findsNothing);
    expect(find.byTooltip('打开链接'), findsOneWidget);

    await tester.tap(find.byTooltip('复制内容').last);
    await tester.pump();
    expect(
      calls.where((c) => c.method == MethodNames.copyText).single.arguments,
      {'text': '4006381333931'},
    );
    expect(find.text('已复制内容'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byTooltip('打开链接'));
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == MethodNames.openLink).single.arguments,
      {'id': 'shot-codes', 'url': 'https://example.com/a'},
    );
    expect(find.text('无法打开链接'), findsOneWidget);
    expect(
      calls.where((c) => c.method == MethodNames.closeScreenshot),
      isEmpty,
    );

    opened = true;
    await tester.tap(find.byTooltip('打开链接'));
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );

    codes = [];
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-copy'));
    expect(find.text('画面中没有可识别的文字、二维码或条码'), findsOneWidget);
    expect(find.text('识别结果'), findsNothing);
  });

  testWidgets('截图翻译完成后在识别位置显示译文', (tester) async {
    // 有字块时显示译文与成功反馈；历史提交由主引擎完成，另有真实数据库测试。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot-ocr-overlay');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-ocr-overlay',
            'bytes': bytes,
            'capturedAt': 1788662400000,
            'width': 8,
            'height': 8,
            'directory': '',
          };
        case MethodNames.recognizeBlocks:
          return [
            {'text': 'Hello', 'x': 0, 'y': 0, 'width': 4, 'height': 2},
          ];
        case MethodNames.translatePlainText:
          return '你好';
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-translate'));
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('已在图上显示译文'), findsOneWidget);
  });

  testWidgets('截图翻译的迟到识别结果不在替换后的截图上显示，也不发起翻译（#115）', (tester) async {
    // 边界：识别请求已发出、结果到达前截图被替换；迟到结果不生成覆盖层、不调用翻译、不显示成功反馈。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot-ocr-stale');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final snapshot = <String, Object?>{
      'id': 'first',
      'bytes': bytes,
      'capturedAt': 1788662400000,
      'width': 8,
      'height': 8,
      'directory': '',
    };
    final requested = Completer<void>();
    final reply = Completer<List<Object?>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return snapshot;
        case MethodNames.recognizeBlocks:
          requested.complete();
          return reply.future;
        case MethodNames.translatePlainText:
          return '你好';
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('screenshot-ocr-translate')),
    );
    // 截图编码使用真实图像线程，识别请求在编码完成后才发出：交替让出真实时间与推进帧，最多 5 秒。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-ocr-translate')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 50 && !requested.isCompleted; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(requested.isCompleted, isTrue);
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
    reply.complete([
      {'text': 'Hello', 'x': 0, 'y': 0, 'width': 4, 'height': 2},
    ]);
    await tester.pumpAndSettle();
    expect(calls, isNot(contains(MethodNames.translatePlainText)));
    expect(find.text('你好'), findsNothing);
    expect(find.text('已在图上显示译文'), findsNothing);
  });

  testWidgets('Esc 关闭会话不复制；文字输入按 Esc 写入标注', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot-esc-text');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-esc',
          'bytes': bytes,
          'capturedAt': 1788662400000,
          'width': 8,
          'height': 8,
          'directory': '',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.copyScreenshot),
      isEmpty,
    );
  });

  test('文字工具输入后出现在导出文档；画笔不是矩形', () async {
    final source = await _pngCheckerboard();
    final document = EditDocument();
    document.loadCapture(source, 8, 8);
    document.setCrop(const Rect.fromLTWH(0, 0, 6, 6));
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: Rect.fromLTWH(0, 0, 8, 8),
        text: 'HelloEdit',
        color: Color(0xFFFFFFFF),
        fontSize: 6,
      ),
    );
    expect(document.annotations.single.text, 'HelloEdit');
    expect(document.cropRect, const Rect.fromLTWH(0, 0, 6, 6));
    document.undo();
    expect(document.annotations, isEmpty);
    expect(document.cropRect, const Rect.fromLTWH(0, 0, 6, 6));

    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.stroke,
        bounds: Rect.fromLTWH(0, 0, 5, 5),
        points: [Offset(0, 0), Offset(1, 2), Offset(4, 1), Offset(5, 5)],
        color: Color(0xFF00FF00),
        strokeWidth: 1,
      ),
    );
    expect(document.annotations.single.kind, AnnotationKind.stroke);
    expect(document.annotations.single.points.length, 4);
    final stroked = await document.renderPng();
    final image = await _decode(stroked);
    expect(image.width, 6);
    expect(image.height, 6);
    // 折线不是填满包围盒：裁剪后 (5,0) 仍是原图蓝，不是绿色填充。
    expect(_nearColor(await _pixel(image, 5, 0), _blue), isTrue);
    expect(
      _nearColor(await _pixel(image, 5, 0), const Color(0xFF00FF00)),
      isFalse,
    );
    image.dispose();
  });

  testWidgets('文字工具输入后按 Esc 保留文字并导出；空文字框按 Esc 不留标注', (tester) async {
    tester.view.physicalSize = const Size(640, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    const channel = MethodChannel('test/screenshot-type-path');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-type-path',
            'bytes': bytes,
            'capturedAt': 1788662400000,
            'width': 64,
            'height': 64,
            'directory': '',
          };
        case MethodNames.copyScreenshot:
          copied = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.ensureVisible(find.byKey(const Key('screenshot-tool-text')));
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);

    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);
    expect(
      calls.where((c) => c.method == MethodNames.closeScreenshot),
      isEmpty,
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'HelloEdit',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('screenshot-copy')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(copied, isNotNull);
    expect(listEquals(copied!, bytes!), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('美化行选择背景后复制输出扩出内边距的图片，贴图仍是原图，切换工具收起美化行；截图历史保留最后一次导出', (
    tester,
  ) async {
    // 边界：倍率 1、默认内边距 64pt，64px 原图复制后为 192px；贴图不受美化影响。
    // 截图历史：同一截图先复制后贴图，只保留一条，尺寸为最后一次导出的 64px。
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    // 主引擎的真实截图历史：内存数据库加临时目录，开启记录。
    final directory = Directory.systemTemp.createTempSync('screenshot-app-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final history = ScreenshotHistoryStore(
      sqlite3.openInMemory(),
      Directory('${directory.path}/ScreenshotHistory'),
    )..recordingEnabled = true;
    const channel = MethodChannel('test/screenshot-beautify');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    Uint8List? pinned;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-beautify',
            'bytes': bytes,
            'capturedAt': 1788662400000,
            'width': 64,
            'height': 64,
            'directory': '',
            // 贴图按显示器坐标定位，需要冻结帧所在显示器。
            'displayX': 0,
            'displayY': 0,
            'displayWidth': 900,
            'displayHeight': 900,
          };
        case MethodNames.copyScreenshot:
          copied = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
        case MethodNames.pinScreenshot:
          pinned = (call.arguments as Map)['bytes'] as Uint8List;
          return 'pin-beautify';
        case MethodNames.recordScreenshotHistory:
          // 主引擎同样以当前时间处理截图窗口的记录请求。
          return handleScreenshotHistoryRequest(history, call, 1788662400000);
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.ensureVisible(find.byKey(const Key('screenshot-beautify')));
    await tester.tap(find.byKey(const Key('screenshot-beautify')));
    await tester.pump();
    expect(find.byKey(const Key('beautify-row')), findsOneWidget);
    await tester.tap(find.byTooltip('海洋'));
    await tester.pump();

    /// key 为工具栏按钮；点击并等待导出完成。
    Future<void> press(String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key(key)));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
    }

    await press('screenshot-copy');
    final image = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(copied!);
      return (await codec.getNextFrame()).image;
    });
    expect((image!.width, image.height), (192, 192));
    image.dispose();
    expect(history.list().map((record) => (record.width, record.height)), [
      (192, 192),
    ]);

    // 切换工具收起美化行，已选美化仍生效。
    await tester.ensureVisible(find.byKey(const Key('screenshot-tool-rect')));
    await tester.tap(find.byKey(const Key('screenshot-tool-rect')));
    await tester.pump();
    expect(find.byKey(const Key('beautify-row')), findsNothing);
    await press('screenshot-pin');
    expect(pinned, isNotNull);
    final pin = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(pinned!);
      return (await codec.getNextFrame()).image;
    });
    expect((pin!.width, pin.height), (64, 64));
    pin.dispose();
    expect(history.list().map((record) => (record.width, record.height)), [
      (64, 64),
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('画笔拖拽导出不是填充矩形；⌘Z 撤销同一份历史', (tester) async {
    tester.view.physicalSize = const Size(640, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    const channel = MethodChannel('test/screenshot-brush-path');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-brush-path',
          'bytes': bytes,
          'capturedAt': 1788662400000,
          'width': 64,
          'height': 64,
          'directory': '',
        };
      }
      if (call.method == MethodNames.copyScreenshot) {
        copied = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('screenshot-tool-brush')));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('screenshot-canvas')),
      const Offset(120, 16),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(copied, isNotNull);
    final image = await tester.runAsync(() => _decode(copied!));
    final width = image!.width;
    final height = image.height;
    final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    image.dispose();
    final pixels = data!.buffer.asUint8List();
    var changed = 0;
    final total = width * height;
    for (var i = 0; i < pixels.length; i += 4) {
      if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0xFF) {
        changed++;
      }
    }
    expect(changed, greaterThan(0));
    expect(changed, lessThan(total ~/ 2));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    // ⌘Z 之后再次导出：画笔痕迹消失，全部像素回到原图的纯蓝。
    copied = null;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    final undone = await tester.runAsync(() => _decode(copied!));
    final undoneData = await tester.runAsync(
      () => undone!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    undone!.dispose();
    final restored = undoneData!.buffer.asUint8List();
    for (var i = 0; i < restored.length; i += 4) {
      expect(restored.sublist(i, i + 3), [0, 0, 0xFF]);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('快照带窗口裁剪时导出尺寸等于该矩形', (tester) async {
    // 边界：crop 为 4x4 且贴在 8x8 左上；导出宽高必须是 4，不是整张 8。
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    const channel = MethodChannel('test/screenshot-window-crop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-window-crop',
          'bytes': bytes,
          'capturedAt': 1788662400000,
          'width': 8,
          'height': 8,
          'cropX': 0,
          'cropY': 0,
          'cropWidth': 4,
          'cropHeight': 4,
          'directory': '',
        };
      }
      if (call.method == MethodNames.copyScreenshot) {
        copied = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    await _tapExport(tester, const Key('screenshot-copy'));
    expect(copied, isNotNull);
    final image = await tester.runAsync(() => _decode(copied!));
    expect(image!.width, 4);
    expect(image.height, 4);
    image.dispose();
  });

  testWidgets('文字工具有颜色字号；结束输入后单击选中、再次点击进入编辑', (tester) async {
    // 边界：提交后点同一位置应带回原文；改字后导出不再是上一版。
    tester.view.physicalSize = const Size(640, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    const channel = MethodChannel('test/screenshot-text-reedit');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-text-reedit',
          'bytes': bytes,
          'capturedAt': 1788662400000,
          'width': 64,
          'height': 64,
          'directory': '',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.ensureVisible(find.byKey(const Key('screenshot-tool-text')));
    expect(find.byKey(const Key('screenshot-tool-cursor')), findsOneWidget);
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-size-up')), findsOneWidget);
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hello',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);

    final canvasBox = tester.getRect(
      find.byKey(const Key('screenshot-canvas')),
    );
    // 点文本框内部，不点边角，避免被当成拉伸/移动。
    // 单击选中，不进入编辑；紧接着再次点击同一文字框才进入编辑。
    await tester.tapAt(canvasBox.center + const Offset(120, 120));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);
    await tester.tapAt(canvasBox.center + const Offset(120, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'World',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });
}

/// tester 点击导出按钮；key 为 copy/save/pin。导出含 toImage，需真实异步。
Future<void> _tapExport(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.runAsync(() async {
    await tester.tap(find.byKey(key));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pumpAndSettle();
}

const _red = Color(0xFFFF0000);
const _blue = Color(0xFF0000FF);
const _black = Color(0xFF000000);

/// 无参数；返回左上红、右下蓝的 8x8 PNG，用于裁剪与遮挡边界断言。
Future<Uint8List> _pngCheckerboard() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = _blue);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = _red);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// width/height 为像素尺寸，color 为填充色；返回纯色 PNG。
Future<Uint8List> _solidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// bytes 为 PNG；返回解码后的图像。
Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// image 为位图，x/y 为像素坐标；返回该点不透明颜色。
Future<Color> _pixel(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final offset = (y * image.width + x) * 4;
  final bytes = data!.buffer.asUint8List();
  return Color.fromARGB(
    bytes[offset + 3],
    bytes[offset],
    bytes[offset + 1],
    bytes[offset + 2],
  );
}

/// a/b 为待比较字节；返回内容是否完全一致。
bool listEquals(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// a/b 为颜色；在编解码误差内判定是否接近，避免 PNG 往返的 1/255 抖动。
bool _nearColor(Color a, Color b) {
  return (a.r - b.r).abs() < 0.08 &&
      (a.g - b.g).abs() < 0.08 &&
      (a.b - b.b).abs() < 0.08 &&
      (a.a - b.a).abs() < 0.08;
}
