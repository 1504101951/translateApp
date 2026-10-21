import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/history/screenshot_history_page.dart';

/// 无参数；用假历史通道验证截图历史分段的缺失文件、删除、清空与开关空状态（#29）。
void main() {
  testWidgets('图片缺失的条目只能删除；清空后显示空状态，关闭记录后提示开启方式', (tester) async {
    // 边界：文件缺失是外部操作造成的唯一不一致状态，只保留删除；列表为空时清空按钮禁用。
    final directory = Directory.systemTemp.createTempSync('screenshot-page-');
    addTearDown(() => directory.deleteSync(recursive: true));
    // 1×1 透明 PNG，让存在的条目能正常解码缩略图。
    final existing = File('${directory.path}/a.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
        ),
      );
    const channel = MethodChannel('test/screenshot-history-page');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 假主引擎：一条存在、一条缺失的截图历史，删除、清空与开关直接改写这份状态。
    final rows = <Map<String, Object>>[
      {
        'id': 1,
        'path': existing.path,
        'width': 1,
        'height': 1,
        'capturedAt': 2,
        'exists': true,
      },
      {
        'id': 2,
        'path': '${directory.path}/missing.png',
        'width': 800,
        'height': 600,
        'capturedAt': 1,
        'exists': false,
      },
    ];
    var recording = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map?;
      switch (call.method) {
        case MethodNames.screenshotHistoryList:
          return rows;
        case MethodNames.screenshotHistoryRecording:
          return recording;
        case MethodNames.setScreenshotHistoryRecording:
          recording = arguments!['enabled'] as bool;
          return null;
        case MethodNames.deleteScreenshotHistory:
          rows.removeWhere((row) => row['id'] == arguments!['id']);
          return null;
        case MethodNames.clearScreenshotHistory:
          rows.clear();
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ScreenshotHistoryPage(channel: channel, version: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('800 × 600'), findsOneWidget);
    expect(find.text('图片文件已缺失'), findsOneWidget);
    expect(find.byTooltip('打开'), findsOneWidget);
    expect(find.byTooltip('复制图片'), findsOneWidget);
    expect(find.byTooltip('删除截图'), findsNWidgets(2));

    await tester.tap(find.byTooltip('删除截图').last);
    await tester.pumpAndSettle();
    expect(find.text('图片文件已缺失'), findsNothing);
    expect(find.text('1 × 1'), findsOneWidget);

    await tester.tap(find.text('清空截图历史'));
    await tester.pumpAndSettle();
    expect(find.text('暂无截图历史'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '清空截图历史'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(find.text('未开启记录截图历史；开启后复制、保存或贴图的截图会出现在这里。'), findsOneWidget);
  });
}
