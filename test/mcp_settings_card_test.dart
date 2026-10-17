import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/settings/settings_app.dart';

/// 验证截图设置页的「MCP 接口」卡片（#96「设置」、#67「截图页 MCP 接口卡片（#96）」）：
/// 卡片位置、开关经自动保存提交、开关关闭时路径与复制照常可用、复制内容与「已复制」反馈时长。
void main() {
  const helperPath =
      '/Applications/TranslateApp.app/Contents/MacOS/translateapp-mcp';
  const channel = MethodChannel(ChannelNames.settings);

  /// 作用：挂载设置窗口并切到截图页。
  /// 参数 tester：测试驱动；saved：收集 saveSettings 提交的草稿；clipboard：收集写入剪贴板的文本。
  Future<void> openScreenshotPage(
    WidgetTester tester, {
    required List<Map<String, Object?>> saved,
    required List<String> clipboard,
  }) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var revision = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return {'revision': revision};
        case MethodNames.mcpHelperPath:
          return helperPath;
        case MethodNames.saveSettings:
          final draft = Map<String, Object?>.from(call.arguments as Map);
          saved.add(draft);
          return {...draft, 'revision': ++revision};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    // 窗口足够高，截图页全部分组同时布局，便于比较位置并直接点击。
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
  }

  Finder mcpSwitch() => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is NativeGlassSwitchTile && w.title == '允许 agent 截图',
    ),
    matching: find.byType(NativeGlassSwitch),
  );

  testWidgets('卡片位于区域截图快捷键之后、截图工具栏之前，开关默认关闭并经自动保存提交', (tester) async {
    final saved = <Map<String, Object?>>[];
    await openScreenshotPage(tester, saved: saved, clipboard: []);

    final card = find.text('MCP 接口');
    expect(
      tester.getTopLeft(card).dy,
      greaterThan(tester.getTopLeft(find.byKey(const ValueKey('区域截图快捷键'))).dy),
    );
    expect(
      tester.getTopLeft(card).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('screenshot-toolbar-section')),
            )
            .dy,
      ),
    );
    expect(tester.widget<NativeGlassSwitch>(mcpSwitch()).value, isFalse);

    await tester.ensureVisible(mcpSwitch());
    await tester.tap(mcpSwitch());
    await tester.pumpAndSettle();
    expect(saved.last[PreferenceKeys.mcpEnabled], isTrue);
    expect(tester.widget<NativeGlassSwitch>(mcpSwitch()).value, isTrue);
  });

  testWidgets('开关关闭时显示完整路径并可复制客户端配置，「已复制」保持 1000ms', (tester) async {
    final clipboard = <String>[];
    await openScreenshotPage(tester, saved: [], clipboard: clipboard);

    final path = find.byKey(const ValueKey('mcp-helper-path'));
    expect(tester.widget<SelectableText>(path).data, helperPath);
    final copy = find.byKey(const ValueKey('mcp-copy-config'));
    final width = tester.getSize(copy).width;
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pump();

    final config = jsonDecode(clipboard.single) as Map<String, Object?>;
    expect(config, {
      'mcpServers': {
        'translateapp': {'command': helperPath, 'args': <Object?>[]},
      },
    });
    expect(find.text('已复制'), findsOneWidget);
    // 反馈文字切换不改变按钮宽度。
    expect(tester.getSize(copy).width, width);

    // 边界依据：#96 待确认值 1000ms；999ms 仍显示，1000ms 恢复。
    await tester.pump(const Duration(milliseconds: 999));
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('已复制'), findsNothing);
  });
}
