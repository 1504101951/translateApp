import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/settings/settings_app.dart';

/// 无参数；验证真实编辑得到的持久化状态、并发边界及本地校验失败后的修正。
void main() {
  testWidgets('保存期间继续修改时，旧回包不覆盖新选择', (tester) async {
    // 第一笔事务未完成时再改变另一字段；最终配置必须同时包含两次编辑。
    final gate = Completer<void>();
    var first = true;
    var saved = <String, Object?>{'revision': 0};
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        if (first) {
          first = false;
          await gate.future;
        }
        saved = {...draft, 'revision': (saved['revision'] as int) + 1};
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    // 持久化事务仍挂起：后台保存也不能出现文字或占位。
    expect(find.text('正在自动保存…'), findsNothing);
    expect(find.text('已自动保存'), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], true);
    expect(saved[PreferenceKeys.glassAppearance], 'dark');
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('保存设置'), findsNothing);
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      true,
    );
  });

  testWidgets('无效语言组合保留草稿，修正后自动保存', (tester) async {
    // 主次语言相同是业务不允许的真实边界；不伪造底层异常或丢弃错误输入。
    var saved = <String, Object?>{
      ...AppSettings(primaryLanguage: 'zh-CN', secondaryLanguage: 'en').toMap(),
      'revision': 0,
    };
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        saved = {...draft, 'revision': (saved['revision'] as int) + 1};
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    final primary = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '主要语言',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(primary);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'English'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('重试自动保存'), 200);
    await tester.tap(find.text('重试自动保存'));
    await tester.pumpAndSettle();
    expect(find.text('主要语言和次要语言必须不同。'), findsOneWidget);
    expect(saved[PreferenceKeys.primaryLanguage], 'zh-CN');
    final secondary = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '次要语言（可选）',
      ),
      matching: find.byType(TextButton),
    );
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(secondary);
    await tester.pumpAndSettle();
    await tester.tap(secondary);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '日本語'));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.primaryLanguage], 'en');
    expect(saved[PreferenceKeys.secondaryLanguage], 'ja');
    expect(find.text('主要语言和次要语言必须不同。'), findsNothing);
  });
  testWidgets('延迟返回的加载快照不回退已自动保存的设置版本', (tester) async {
    // 状态查询跨越一次完整保存，是旧快照覆盖新草稿的真实异步边界。
    final statusGate = Completer<void>();
    var delayStatus = false;
    var saved = <String, Object?>{'revision': 0};
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        if (delayStatus) {
          delayStatus = false;
          await statusGate.future;
        }
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return {...saved};
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        // 检查保存版本与模拟持久化状态一致，而非只检查调用次数。
        expect(draft['revision'], saved['revision']);
        saved = {...draft, 'revision': (saved['revision'] as int) + 1};
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    delayStatus = true;
    final loading = messenger.handlePlatformMessage(
      ChannelNames.settings,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall(MethodNames.refreshSettings),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], true);
    statusGate.complete();
    await loading;
    await tester.pumpAndSettle();
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      true,
    );
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], false);
    expect(find.text('重新加载设置'), findsNothing);
  });
}
