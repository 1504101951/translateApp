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
    await tester.tap(find.text('自动显示翻译按钮'));
    await tester.pumpAndSettle();
    revision = 1;
    await messenger.handlePlatformMessage(
      'translateapp/settings',
      codec.encodeMethodCall(const MethodCall('refreshSettings')),
      (_) {},
    );
    await tester.pumpAndSettle();
    // 草稿仍保留中文和关闭的开关，不用检查通道调用次数代替用户结果。
    expect(find.text('简体中文'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
      isFalse,
    );
    await tester.scrollUntilVisible(find.text('重新加载设置'), 300);
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
      isTrue,
    );
  });
}
