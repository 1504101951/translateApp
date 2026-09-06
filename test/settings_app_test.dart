import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/settings_app.dart';

/// 无参数；验证真实表单在菜单刷新时保留草稿，并阻止过期设置覆盖。
void main() {
  testWidgets('菜单更新不会覆盖未保存编辑，显式重新加载才替换表单', (tester) async {
    const channel = MethodChannel('translateapp/settings');
    const codec = StandardMethodCodec();
    var revision = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'systemStatus') return {'accessibility': true};
      if (call.method == 'getSettings') {
        return {
          'primaryLanguage': revision == 0 ? 'zh-CN' : 'ja',
          'secondaryLanguage': 'en',
          'revision': revision,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅使用快捷键'));
    await tester.pumpAndSettle();
    revision = 1;
    await messenger.handlePlatformMessage(
      'translateapp/settings',
      codec.encodeMethodCall(const MethodCall('refreshSettings')),
      (_) {},
    );
    await tester.pumpAndSettle();
    // 草稿仍保留中文和开启的仅快捷键开关，不用检查通道调用次数代替用户结果。
    expect(find.text('简体中文'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
      isTrue,
    );
    await tester.scrollUntilVisible(find.text('重新加载设置'), 300);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('重新加载设置'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(find.text('日本語'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
      isFalse,
    );
  });

  testWidgets('录制数字组合后显示真实快捷键，取消保留当前组合', (tester) async {
    const channel = MethodChannel('translateapp/settings');
    var cancel = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'systemStatus') return {'accessibility': true};
      if (call.method == 'getSettings') return {'revision': 0};
      if (call.method == 'recordShortcut') {
        return cancel ? null : {'keyCode': 18, 'modifiers': 4352, 'label': '1'};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
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
    const channel = MethodChannel('translateapp/settings');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    var credentialIds = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'systemStatus') return {'accessibility': true};
      if (call.method == 'getSettings') {
        return {...state, 'credentialIds': credentialIds};
      }
      if (call.method == 'testService') {
        // 测试连接不得使主偏好提前包含新服务。
        expect(state['services'], isNull);
        return '你好，世界。';
      }
      if (call.method == 'saveSettings') {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        final credentials = draft.remove('credentials') as Map;
        final services = draft['services'] as List;
        credentialIds = services
            .map((e) => (e as Map)['id'] as String)
            .toList();
        if (services.isNotEmpty) {
          expect(credentials[credentialIds.single], {
            'apiKey': 'test-key',
            'appId': 'test-app',
          });
          expect((services.single as Map).containsKey('apiKey'), false);
        }
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, 'credentialIds': credentialIds};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请填写 API Key／密钥，百度翻译还需要 App ID。'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '百度 App ID'),
      'test-app',
    );
    await tester.enterText(find.widgetWithText(TextField, '百度密钥'), 'test-key');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接成功：你好，世界。'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('百度翻译'), findsWidgets);
    final selector = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          w.decoration.labelText == '默认翻译服务',
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('百度翻译').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('仅使用快捷键'), 250);
    await tester.tap(find.text('仅使用快捷键'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存设置'), 350);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(state['defaultServiceId'], credentialIds.single);
    expect(state['automatic'], false);
    expect(find.text('已保存，下次翻译立即生效。'), findsOneWidget);
    await tester.scrollUntilVisible(find.byTooltip('删除 百度翻译'), -350);
    await tester.tap(find.byTooltip('删除 百度翻译'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存设置'), 350);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(state['services'], isEmpty);
    expect(state['defaultServiceId'], 'unofficial-google');
  });
}
