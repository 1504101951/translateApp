import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/settings/permission_wizard_app.dart';

/// 无参数；验证单页双权限与「进入应用」可点条件。
void main() {
  testWidgets('同一页两个授权按钮，都成功后进入应用才可点', (tester) async {
    // 边界：缺权限时进入应用不可点；两项都真之后才关窗。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = false;
    var screen = false;
    var finished = false;
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.permissionWizardStatus:
          return {
            'accessibility': accessibility,
            'screenAccess': screen,
            'finishedOrSkipped': finished,
          };
        case MethodNames.openAccessibility:
          accessibility = true;
          return null;
        case MethodNames.requestScreenAccess:
          screen = true;
          return {'screenAccess': true};
        case MethodNames.finishPermissionWizard:
          finished = true;
          return null;
        case MethodNames.closePermissionWizard:
          closed = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('授权辅助功能'), findsOneWidget);
    expect(find.text('申请录屏权限'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('授权辅助功能'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('申请录屏权限'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNotNull,
    );
    expect(closed, isFalse);

    await tester.tap(find.text('进入应用'));
    await tester.pump();
    expect(finished, isTrue);
    expect(closed, isTrue);
  });

  testWidgets('稍后可结束向导；系统回调授权后进入应用变可点但不自动关窗', (tester) async {
    // 边界：permissionStatusChanged 只刷新状态；关窗必须点进入应用或稍后。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = true;
    var screen = false;
    var finished = false;
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.permissionWizardStatus:
          return {
            'accessibility': accessibility,
            'screenAccess': screen,
            'finishedOrSkipped': finished,
          };
        case MethodNames.finishPermissionWizard:
          finished = true;
          return null;
        case MethodNames.closePermissionWizard:
          closed = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('申请录屏权限'), findsOneWidget);

    screen = true;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall(MethodNames.permissionStatusChanged),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
    expect(closed, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('稍后'));
    await tester.pump();
    expect(finished, isTrue);
    expect(closed, isTrue);
  });
}
