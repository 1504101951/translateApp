import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/settings/mcp_platforms.dart';
import 'package:translate_app/src/settings/settings_app.dart';

/// 内存中的平台服务：替代真实 CLI 与配置文件，只用于驱动界面状态；
/// 平台服务自身的命令与文件行为由 mcp_platforms_test.dart 用真实进程验证。
class _FakeMcpService extends McpPlatformService {
  _FakeMcpService(String helperPath) : super(helperPath: helperPath, home: '/');

  /// 各平台当前状态；缺省为未安装。
  final states = <String, McpInstallState>{
    'grok': McpInstallState.missing,
    'codex': McpInstallState.pathChanged,
  };

  /// 安装时抛出的错误原文，按平台设置。
  final failures = <String, String>{};

  @override
  Future<McpInstallState> detect(McpPlatform platform) async =>
      states[platform.id] ?? McpInstallState.notInstalled;

  @override
  Future<void> install(McpPlatform platform) async {
    final failure = failures[platform.id];
    if (failure != null) throw McpPlatformException(failure);
    states[platform.id] = McpInstallState.installed;
  }

  @override
  Future<void> remove(McpPlatform platform) async {
    states[platform.id] = McpInstallState.notInstalled;
  }
}

/// 验证设置窗口的 MCP 页（#96「设置」、#67「设置 MCP 页（#96）」）：MCP 导航段、开关自动保存、
/// helper 路径与配置复制、按注册表渲染的平台状态与按钮可用性、安装失败原文、删除二次确认。
void main() {
  const helperPath =
      '/Applications/TranslateApp.app/Contents/MacOS/translateapp-mcp';
  const channel = MethodChannel(ChannelNames.settings);

  /// 作用：挂载设置窗口并切到指定分段。
  /// 参数 tester：测试驱动；section：分段标题；saved：收集 saveSettings 草稿；clipboard：收集剪贴板文本；
  /// service：平台服务。
  Future<void> open(
    WidgetTester tester, {
    String section = 'MCP',
    List<Map<String, Object?>>? saved,
    List<String>? clipboard,
    _FakeMcpService? service,
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
          saved?.add(draft);
          return {...draft, 'revision': ++revision};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard?.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    // 窗口足够高，MCP 页全部分组同时布局，便于直接点击。
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsApp(createMcpService: (path) => service ?? _FakeMcpService(path)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(section));
    await tester.pumpAndSettle();
  }

  Finder mcpSwitch() => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is NativeGlassSwitchTile && w.title == '允许 agent 截图',
    ),
    matching: find.byType(NativeGlassSwitch),
  );

  /// 作用：返回平台行内按钮的可用状态。参数 tester：测试驱动；key：按钮键。返回：是否可点击。
  bool enabled(WidgetTester tester, String key) =>
      tester.widget<TextButton>(find.byKey(ValueKey(key))).onPressed != null;

  Finder rowText(String id, String text) => find.descendant(
    of: find.byKey(ValueKey('mcp-platform-$id')),
    matching: find.text(text),
  );

  testWidgets('MCP 与通用、翻译、截图平级，截图页不再包含 MCP 内容', (tester) async {
    await open(tester, section: '截图');
    expect(find.text('MCP 接口'), findsNothing);
    expect(find.text('允许 agent 截图'), findsNothing);

    await tester.tap(find.text('MCP'));
    await tester.pumpAndSettle();
    expect(find.text('MCP 接口'), findsOneWidget);
    expect(find.text('接入平台'), findsOneWidget);
    expect(find.text('截图目录'), findsNothing);
  });

  testWidgets('开关默认关闭并经自动保存提交', (tester) async {
    final saved = <Map<String, Object?>>[];
    await open(tester, saved: saved);
    expect(tester.widget<NativeGlassSwitch>(mcpSwitch()).value, isFalse);

    await tester.tap(mcpSwitch());
    await tester.pumpAndSettle();
    expect(saved.last[PreferenceKeys.mcpEnabled], isTrue);
    expect(tester.widget<NativeGlassSwitch>(mcpSwitch()).value, isTrue);
  });

  testWidgets('开关关闭时显示完整路径并可复制客户端配置，「已复制」保持 1000ms', (tester) async {
    final clipboard = <String>[];
    await open(tester, clipboard: clipboard);

    final path = find.byKey(const ValueKey('mcp-helper-path'));
    expect(tester.widget<SelectableText>(path).data, helperPath);
    final copy = find.byKey(const ValueKey('mcp-copy-config'));
    final width = tester.getSize(copy).width;
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

  testWidgets('平台列表按注册表渲染，状态决定按钮文字与可用性，行最小高 60', (tester) async {
    await open(tester);

    for (final platform in mcpPlatforms) {
      expect(
        find.byKey(ValueKey('mcp-platform-${platform.id}')),
        findsOneWidget,
      );
    }
    // 边界依据：#67 平台行最小高 60。
    expect(
      tester
          .getSize(find.byKey(const ValueKey('mcp-platform-claude-code')))
          .height,
      greaterThanOrEqualTo(60),
    );
    // 未检测到 CLI：两个按钮都不可用。
    expect(rowText('grok', '未检测到 grok CLI'), findsOneWidget);
    expect(enabled(tester, 'mcp-install-grok'), isFalse);
    expect(enabled(tester, 'mcp-remove-grok'), isFalse);
    // 未安装：只可安装。
    expect(rowText('claude-code', '未安装'), findsOneWidget);
    expect(enabled(tester, 'mcp-install-claude-code'), isTrue);
    expect(enabled(tester, 'mcp-remove-claude-code'), isFalse);
    // 路径已变化：可重新安装或删除。
    expect(rowText('codex', '路径已变化'), findsOneWidget);
    expect(rowText('codex', '重新安装'), findsOneWidget);
    expect(enabled(tester, 'mcp-remove-codex'), isTrue);
  });

  testWidgets('安装后重新检测；配置文件式平台提示重启；失败原文显示在行下方', (tester) async {
    late _FakeMcpService service;
    await open(
      tester,
      service: service = _FakeMcpService(helperPath)
        ..failures['claude-code'] = 'claude: permission denied',
    );

    await tester.tap(find.byKey(const ValueKey('mcp-install-claude-desktop')));
    await tester.pumpAndSettle();
    expect(rowText('claude-desktop', '已安装'), findsOneWidget);
    expect(rowText('claude-desktop', '重启 Claude 后生效'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-install-claude-code')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('mcp-error-claude-code')))
          .data,
      'claude: permission denied',
    );
    expect(rowText('claude-code', '未安装'), findsOneWidget);

    // 下次操作开始时清除上次失败原文。
    service.failures.clear();
    await tester.tap(find.byKey(const ValueKey('mcp-install-claude-code')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-error-claude-code')), findsNothing);
    expect(rowText('claude-code', '已安装'), findsOneWidget);
  });

  testWidgets('删除前二次确认：取消不删除，确认后删除并重新检测', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('mcp-remove-codex')));
    await tester.pumpAndSettle();
    expect(
      find.text('从 Codex（CLI 与桌面 App 共用） 删除 TranslateApp？'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(rowText('codex', '路径已变化'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-remove-codex')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(rowText('codex', '未安装'), findsOneWidget);
    expect(enabled(tester, 'mcp-remove-codex'), isFalse);
  });
}
