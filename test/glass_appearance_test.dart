import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/settings/settings_app.dart';

/// 核验广播到真实设置页面的主题/材料更新与草稿保留，不测方法被调用次数。
void main() {
  testWidgets('透明度两端经过表单校验后成功保存并重新加载', (tester) async {
    // 0% 与 80% 是用户可选边界；验证实际滑块到持久化状态，覆盖浮点换算误差。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var saved = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.saveSettings) {
        saved = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials')
          ..['revision'] = (saved['revision'] as int) + 1;
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    expect(find.text('保存设置'), findsNothing);
    final slider = find.byType(Slider);
    for (final transparency in [0.8, 0.0]) {
      final bounds = tester.getRect(slider);
      await tester.tapAt(
        Offset(
          transparency == 0.8 ? bounds.right - 1 : bounds.left + 1,
          bounds.center.dy,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        saved[PreferenceKeys.glassOpacity],
        transparency == 0.8 ? 0.2 : 1.0,
      );
      // 成功仅体现为持久化结果，不显示成功/进行中反馈或改变布局。
      expect(find.text('已自动保存'), findsNothing);
      expect(find.text('正在自动保存…'), findsNothing);
      await tester.scrollUntilVisible(slider, -200);
      await tester.pumpAndSettle();
      expect(
        find.text('玻璃透明度 ${(transparency * 100).round()}%'),
        findsOneWidget,
      );
    }
  });

  testWidgets('保存外观广播更新材料与明暗，不覆盖未保存表单', (tester) async {
    // 用户正在录入草稿时，另一个引擎发布视觉更新；文字和材料必须同步且草稿不丢。
    const channel = MethodChannel(ChannelNames.settings);
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return {'revision': 0};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    tester.widget<Slider>(slider).onChanged!(0.6);
    await tester.pump();
    expect(find.text('玻璃透明度 60%'), findsOneWidget);
    await messenger.handlePlatformMessage(
      ChannelNames.appearance,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.appearanceChanged, {
          PreferenceKeys.glassAppearance: 'dark',
          PreferenceKeys.glassOpacity: 0.2,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Slider));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(Theme.of(context).colorScheme.onSurface, Colors.white);
    expect(find.text('玻璃透明度 60%'), findsOneWidget);
    final materials = tester.widgetList<AppKitView>(find.byType(AppKitView));
    expect(materials, isNotEmpty);
    expect(
      materials.every((view) => (view.creationParams as Map)['opacity'] == 0.2),
      isTrue,
    );
    await messenger.handlePlatformMessage(
      ChannelNames.appearance,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.appearanceChanged, {
          PreferenceKeys.glassAppearance: 'light',
          PreferenceKeys.glassOpacity: 1.0,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(Theme.of(context).brightness, Brightness.light);
    expect(Theme.of(context).colorScheme.onSurface, Colors.black);
    expect(find.text('玻璃透明度 60%'), findsOneWidget);
  });
}
