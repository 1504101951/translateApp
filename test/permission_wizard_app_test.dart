import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/permission_wizard_app.dart';

/// 无参数；验证向导按状态展示步骤，授权后前进，跳过可结束。
void main() {
  testWidgets('缺辅助功能时先显示该步，授权后进入录屏，跳过结束', (tester) async {
    const channel = MethodChannel('translateapp/settings');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = false;
    var screen = false;
    var finished = false;
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'permissionWizardStatus':
          return {
            'accessibility': accessibility,
            'screenAccess': screen,
            'finishedOrSkipped': finished,
          };
        case 'openAccessibility':
          accessibility = true;
          return null;
        case 'requestScreenAccess':
          screen = true;
          return {'screenAccess': true};
        case 'finishPermissionWizard':
          finished = true;
          return null;
        case 'closePermissionWizard':
          closed = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('允许读取选中文字'), findsOneWidget);
    await tester.tap(find.text('授权'));
    await tester.pump();
    await tester.pump();
    expect(find.text('允许截取屏幕'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pump();
    expect(finished, isTrue);
    expect(closed, isTrue);
  });

  testWidgets('稍后跳过辅助功能后停留在录屏，刷新不会退回', (tester) async {
    // 边界：稍后只跳过当前步；系统回调仍报未授权辅助功能时，不得退回第一步。
    const channel = MethodChannel('translateapp/settings');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = false;
    var screen = false;
    var finished = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'permissionWizardStatus':
          return {
            'accessibility': accessibility,
            'screenAccess': screen,
            'finishedOrSkipped': finished,
          };
        case 'finishPermissionWizard':
          finished = true;
          return null;
        case 'closePermissionWizard':
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('允许读取选中文字'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pump();
    expect(find.text('允许截取屏幕'), findsOneWidget);
    expect(find.text('申请录屏权限'), findsOneWidget);

    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('permissionStatusChanged'),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.text('允许截取屏幕'), findsOneWidget);
    expect(find.text('允许读取选中文字'), findsNothing);
  });

  testWidgets('已跳过标记不能在缺权限时关掉向导', (tester) async {
    // 边界：finishedOrSkipped=true 但 TCC 未授权，必须停在辅助功能，不能自动关窗。
    const channel = MethodChannel('translateapp/settings');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'permissionWizardStatus':
          return {
            'accessibility': false,
            'screenAccess': false,
            'finishedOrSkipped': true,
          };
        case 'closePermissionWizard':
          closed = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('允许读取选中文字'), findsOneWidget);
    expect(closed, isFalse);
  });

  testWidgets('系统回调录屏已授权后关闭向导', (tester) async {
    // 边界：辅助功能已有、录屏后到；permissionStatusChanged 必须结束向导，不必先关掉窗口。
    const channel = MethodChannel('translateapp/settings');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = true;
    var screen = false;
    var finished = false;
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'permissionWizardStatus':
          return {
            'accessibility': accessibility,
            'screenAccess': screen,
            'finishedOrSkipped': finished,
          };
        case 'finishPermissionWizard':
          finished = true;
          return null;
        case 'closePermissionWizard':
          closed = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('允许截取屏幕'), findsOneWidget);

    screen = true;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('permissionStatusChanged'),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
    expect(finished, isTrue);
    expect(closed, isTrue);
  });
}
