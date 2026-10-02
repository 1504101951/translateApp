import 'dart:async';

import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/settings_app.dart';

/// 无参数；验证真实表单在菜单刷新时保留草稿，并阻止过期设置覆盖。
void main() {
  testWidgets('菜单更新不会覆盖未保存编辑，显式重新加载才替换表单', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    const codec = StandardMethodCodec();
    var revision = 0;
    final pending = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        await pending.future;
        if (draft['revision'] != revision) {
          throw PlatformException(
            code: ErrorCodes.settingsConflict,
            message: '设置版本冲突',
          );
        }
        return {...draft, 'revision': ++revision};
      }
      if (call.method == MethodNames.getSettings) {
        return {
          PreferenceKeys.primaryLanguage: revision == 0 ? 'zh-CN' : 'ja',
          PreferenceKeys.secondaryLanguage: 'en',
          'revision': revision,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    revision = 1;
    pending.complete();
    await messenger.handlePlatformMessage(
      ChannelNames.settings,
      codec.encodeMethodCall(const MethodCall(MethodNames.refreshSettings)),
      (_) {},
    );
    await tester.pumpAndSettle();
    // 草稿仍保留中文和开启的仅快捷键开关，不用检查通道调用次数代替用户结果。
    expect(find.text('简体中文'), findsOneWidget);
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isTrue,
    );
    await tester.scrollUntilVisible(find.text('重新加载设置'), 300);
    await tester.pumpAndSettle();
    expect(find.text('保存设置'), findsNothing);
    expect(find.text('重试自动保存'), findsNothing);
    await tester.tap(find.text('重新加载设置'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(find.text('日本語'), findsOneWidget);
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isFalse,
    );
  });

  testWidgets('录制数字组合后显示真实快捷键，取消保留当前组合', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    var cancel = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return {'revision': 0};
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        return {...draft, 'revision': (draft['revision'] as int) + 1};
      }
      if (call.method == MethodNames.recordShortcut) {
        return cancel ? null : {'keyCode': 18, 'modifiers': 4352, 'label': '1'};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    // 分段导航后热键更靠下；先滚入视口再录制，避免点到不可命中区域。
    await tester.scrollUntilVisible(find.byKey(const ValueKey('全局翻译快捷键')), 300);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('全局翻译快捷键')));
    await tester.pumpAndSettle();
    expect(find.text('⌃ ⌘ 1'), findsOneWidget);
    cancel = true;
    await tester.tap(find.byKey(const ValueKey('全局翻译快捷键')));
    await tester.pumpAndSettle();
    expect(find.text('⌃ ⌘ 1'), findsOneWidget);
  });
  testWidgets('添加服务、测试草稿、默认切换和删除通过保存形成实际状态', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    var credentialIds = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: credentialIds};
      }
      if (call.method == MethodNames.testService) {
        // 测试连接不得使主偏好提前包含新服务。
        expect(state[PreferenceKeys.services], isNull);
        return '你好，世界。';
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        final credentials = draft.remove('credentials') as Map;
        final services = draft[PreferenceKeys.services] as List;
        credentialIds = services
            .map((e) => (e as Map)['id'] as String)
            .toList();
        if (credentials.isNotEmpty && services.isNotEmpty) {
          expect(credentials[credentialIds.single], {
            'apiKey': 'test-key',
            'appId': 'test-app',
          });
          expect((services.single as Map).containsKey('apiKey'), false);
        }
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: credentialIds};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请填写 API Key／密钥，百度翻译还需要 App ID。'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('百度 App ID')), 'test-app');
    await tester.enterText(find.byKey(const ValueKey('百度密钥')), 'test-key');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接成功：你好，世界。'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('百度翻译'), findsWidgets);
    final selector = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '默认翻译服务',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '百度翻译'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('仅使用快捷键'), 250);
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.defaultServiceId], credentialIds.single);
    expect(state[PreferenceKeys.automatic], false);
    expect(find.text('已自动保存'), findsNothing);
    // 保存后视口在底部；向上拖回服务列表再删，避免 scrollUntilVisible 在边界抛错。
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('删除 百度翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除 百度翻译'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.services], isEmpty);
    expect(state[PreferenceKeys.defaultServiceId], 'unofficial-google');
  });

  testWidgets('设置分段：截图与翻译控件互斥，切换保留草稿', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true, 'loginItems': 'enabled'};
      }
      if (call.method == MethodNames.getSettings) {
        return {
          PreferenceKeys.primaryLanguage: 'zh-CN',
          PreferenceKeys.secondaryLanguage: 'en',
          'revision': 0,
          PreferenceKeys.screenshotSaveDirectory: '/tmp/shots',
        };
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        return {...draft, 'revision': (draft['revision'] as int) + 1};
      }
      if (call.method == MethodNames.chooseScreenshotDirectory) {
        return '/tmp/chosen';
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();

    // 默认通用段：登录/排除可见，翻译与截图控件不可见。
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('翻译'), findsOneWidget);
    expect(find.text('截图'), findsOneWidget);
    expect(find.text('排除应用'), findsOneWidget);
    expect(find.text('登录时启动'), findsOneWidget);
    expect(find.text('屏幕录制权限'), findsOneWidget);
    expect(find.text('翻译语言'), findsNothing);
    expect(find.text('截图目录'), findsNothing);

    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    expect(find.text('翻译语言'), findsOneWidget);
    expect(find.text('仅使用快捷键'), findsOneWidget);
    expect(find.byKey(const ValueKey('全局翻译快捷键')), findsOneWidget);
    expect(find.text('截图目录'), findsNothing);
    expect(find.text('排除应用'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('截图目录'), findsOneWidget);
    expect(find.text('/tmp/shots'), findsOneWidget);
    expect(find.byKey(const ValueKey('区域截图快捷键')), findsOneWidget);
    expect(find.text('屏幕录制权限'), findsNothing);
    expect(find.text('翻译语言'), findsNothing);
    expect(find.text('仅使用快捷键'), findsNothing);
    expect(find.text('排除应用'), findsNothing);

    await tester.tap(find.text('选择…'));
    await tester.pumpAndSettle();
    expect(find.text('/tmp/chosen'), findsOneWidget);

    // 配置入口在截图页底部默认收起；展开后仍在当前页，且只包含顶层工具。
    final section = find.byKey(const ValueKey('screenshot-toolbar-section'));
    expect(find.text('设置快捷键'), findsNothing);
    expect(
      tester.getTopLeft(section).dy,
      greaterThan(tester.getTopLeft(find.byKey(const ValueKey('区域截图快捷键'))).dy),
    );
    await tester.ensureVisible(section);
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图工具栏'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byKey(const ValueKey('toolbar-row-screenshot-tool-cursor')),
      findsOneWidget,
    );
    expect(find.text('增大字号'), findsNothing);
    expect(find.text('在 Finder 中显示'), findsNothing);
    await tester.tap(find.text('截图工具栏'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    expect(find.text('翻译语言'), findsOneWidget);
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isTrue,
    );
  });
  testWidgets('截图页保存GIF帧率与最大宽度，留空恢复原宽且非法值不保存', (tester) async {
    // 600是有效压缩上限；0非法、空值是不限制，保存后的重新加载必须保留用户选择。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        settings = {
          ...Map<String, Object?>.from(call.arguments as Map),
          'revision': (settings['revision'] as int) + 1,
        };
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('默认截图存放路径'), findsOneWidget);
    expect(find.text('每次询问'), findsNothing);
    expect(find.text('10 fps'), findsOneWidget);
    final width = find.byKey(const Key('gif-maximum-width'));
    await tester.ensureVisible(width);
    await tester.enterText(width, '600');
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifMaximumWidth], 600);
    await tester.tap(find.text('10 fps'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('15 fps'));
    await tester.tap(find.text('15 fps'));
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifFramesPerSecond], 15);
    await tester.enterText(width, '0');
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifMaximumWidth], 600);
    await tester.scrollUntilVisible(
      find.textContaining('最大宽度须为正整数'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('最大宽度须为正整数'), findsOneWidget);
    await tester.ensureVisible(width);
    await tester.enterText(width, '');
    await tester.pumpAndSettle();
    expect(settings.containsKey(PreferenceKeys.gifMaximumWidth), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('15 fps'), findsOneWidget);
    expect(tester.widget<TextField>(width).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
