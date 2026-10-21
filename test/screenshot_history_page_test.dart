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

  testWidgets('勾选决定拼接、拆分与比较是否可用；结果加入历史后清空勾选，比较显示差异摘要', (tester) async {
    // 边界：缺失图片不可勾选；1 张只能拆分，2 张可拼接与比较，3 张只能拼接；
    // 拼接按截图时间先后传路径；比较差异为 0 与非 0 时摘要不同（#109）。
    // 窗口足够高，五张卡片全部构建，缺失图片的卡片也在可见范围内。
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'screenshot-compose-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    Map<String, Object> row(int id, int capturedAt, {bool exists = true}) {
      final path = '${directory.path}/$id.png';
      if (exists) File(path).writeAsBytesSync(pixel);
      return {
        'id': id,
        'path': path,
        'width': 1,
        'height': 1,
        'capturedAt': capturedAt,
        'exists': exists,
      };
    }

    // 假主引擎与原生：列表倒序；加入历史时把每张结果追加为新记录；比较返回给定差异。
    final rows = [row(3, 30), row(2, 20), row(1, 10), row(9, 5, exists: false)];
    List<Object?>? stitched;
    var different = 0;
    const channel = MethodChannel('test/screenshot-compose');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map?;
      switch (call.method) {
        case MethodNames.screenshotHistoryList:
          return rows;
        case MethodNames.screenshotHistoryRecording:
          return false;
        case MethodNames.stitchScreenshots:
          stitched = arguments!['paths'] as List<Object?>;
          return Uint8List.fromList(pixel);
        case MethodNames.addScreenshotHistory:
          for (final _ in arguments!['images'] as List) {
            rows.insert(0, row(100 + rows.length, 99));
          }
          return null;
        case MethodNames.compareScreenshots:
          return {
            'mask': Uint8List.fromList(pixel),
            'different': different,
            'total': 4,
          };
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

    /// label 为操作按钮文字；返回该按钮当前是否可用。
    bool enabled(String label) =>
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed !=
        null;
    final boxes = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(boxes.last).onChanged, isNull);
    expect(find.text('已选 0 张'), findsOneWidget);
    expect(
      [enabled('拼接'), enabled('拆分'), enabled('比较')],
      [false, false, false],
    );

    await tester.tap(boxes.at(0));
    await tester.pump();
    expect([enabled('拼接'), enabled('拆分'), enabled('比较')], [false, true, false]);
    await tester.tap(boxes.at(2));
    await tester.pump();
    expect([enabled('拼接'), enabled('拆分'), enabled('比较')], [true, false, true]);
    await tester.tap(boxes.at(1));
    await tester.pump();
    expect(find.text('已选 3 张'), findsOneWidget);
    expect([enabled('拼接'), enabled('拆分'), enabled('比较')], [true, false, false]);

    await tester.tap(find.widgetWithText(TextButton, '拼接'));
    await tester.pumpAndSettle();
    expect(find.text('拼接 3 张截图'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '拼接'));
    await tester.pumpAndSettle();
    expect(stitched, [
      '${directory.path}/1.png',
      '${directory.path}/2.png',
      '${directory.path}/3.png',
    ]);
    expect(find.text('已生成拼接图'), findsOneWidget);
    expect(find.text('已选 0 张'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(5));

    // 新结果排在最前；勾选原来的第 3 张与第 1 张比较。
    for (final index in [1, 3]) {
      await tester.tap(find.byType(Checkbox).at(index));
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(TextButton, '比较'));
    await tester.pumpAndSettle();
    expect(find.text('两张截图像素完全一致'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pumpAndSettle();
    different = 1;
    await tester.tap(find.widgetWithText(TextButton, '比较'));
    await tester.pumpAndSettle();
    expect(find.text('差异像素 1 / 总像素 4（25.00%）'), findsOneWidget);
  });
}
