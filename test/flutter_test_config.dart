import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// testMain 为 Flutter 测试入口；原生视图在原生测试验证，widget 测试只替代嵌入通道。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    // 只有 testWidgets 已建立绑定时才配置视图通道，纯 Dart HTTP 测试保留真实网络栈。
    if (BindingBase.debugBindingType() == null) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(ChannelNames.appearance),
          (_) async => {
            PreferenceKeys.glassAppearance: 'system',
            PreferenceKeys.glassOpacity: 0.8,
          },
        );
    // headless widget 环境没有 NSView，保留真实前景布局、焦点及业务状态验证。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
  });
  await testMain();
}
