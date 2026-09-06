import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';
import 'package:translate_app/src/settings/app_settings.dart';

/// 无参数；验证截图导出可见结果、取消边界以及独立快捷键配置，无返回值。
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
  });

  testWidgets('截图预览导出：取消无副作用，失败保留图片，组合部分成功准确显示', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 使用本地合成像素，测试不会读取屏幕或系统剪贴板。
    final bytes = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 2, 2),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(2, 2);
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      picture.dispose();
      return data;
    }))!;
    const channel = MethodChannel('test/screenshot');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? outputPath;
    String? saveError;
    bool copyError = false;
    Object clipboard = '原剪贴板';
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getScreenshot':
          return {
            'id': 'shot',
            'bytes': bytes,
            'capturedAt': 1788662400000,
            'width': 2,
            'height': 2,
            'directory': '',
          };
        case 'saveScreenshot':
          if (saveError != null) {
            throw PlatformException(code: 'save_failed', message: saveError);
          }
          return outputPath;
        case 'copyScreenshot':
          if (copyError) {
            throw PlatformException(code: 'copy_failed', message: '剪贴板不可用');
          }
          clipboard = bytes;
          return null;
        case 'chooseDirectory':
          return '/tmp/screenshots';
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    // 系统保存面板返回 null 表示取消，组合动作不能提前覆盖剪贴板。
    await tester.tap(find.text('复制并保存'));
    await tester.pumpAndSettle();
    expect(clipboard, '原剪贴板');
    expect(find.text('已复制并保存'), findsNothing);
    saveError = '目录不可写';
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('目录不可写'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    saveError = null;
    outputPath = '/tmp/截图.png';
    copyError = true;
    await tester.tap(find.text('复制并保存'));
    await tester.pumpAndSettle();
    expect(find.text('已保存，但复制失败：剪贴板不可用'), findsOneWidget);
    expect(find.text('在 Finder 中显示'), findsOneWidget);
    copyError = false;
    await tester.tap(find.text('复制并保存'));
    await tester.pumpAndSettle();
    expect(find.text('已复制并保存'), findsOneWidget);
    expect(clipboard, bytes);
    await tester.tap(find.text('固定目录…'));
    await tester.pumpAndSettle();
    expect(find.text('/tmp/screenshots'), findsOneWidget);
    // 原生关闭事件移除原图，导出按钮也必须禁用。
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('screenshotChanged', {
          'directory': '/tmp/screenshots',
          'screenAccess': true,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '复制图片'))
          .onPressed,
      isNull,
    );
  });
}
