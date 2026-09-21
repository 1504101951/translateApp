import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/settings/settings_app.dart';
import 'package:translate_app/src/settings/service_config.dart';

/// 验证用户六项修订的可见行为，边界为520×500最小设置窗口与滚动后导航可达。
void main() {
  testWidgets('导航滚动后仍固定，权限仅在通用，新建服务为四类', (tester) async {
    tester.view.physicalSize = const Size(520, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getSettings) return {'revision': 0};
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true, 'screenAccess': true};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    final navigation = find.byKey(const ValueKey('settings-fixed-navigation'));
    final before = tester.getRect(navigation);
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(tester.getRect(navigation), before);
    expect(find.text('辅助功能权限'), findsOneWidget);
    expect(find.text('屏幕录制权限'), findsOneWidget);
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('屏幕录制权限'), findsNothing);
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('添加服务'), 150);
    await tester.tap(find.text('添加服务'));
    await tester.pumpAndSettle();
    final selector = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '服务类型',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(4));
    for (final label in ['谷歌翻译', '百度翻译', 'OpenAI', 'Anthropic']) {
      expect(find.widgetWithText(MenuItemButton, label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色分段选中仍为白字，背景覆盖76×28', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.dark),
        home: Scaffold(
          body: NativeGlassSegments<String>(
            value: 'dark',
            options: const {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final selected = find.widgetWithText(TextButton, '深色');
    expect(tester.getSize(selected), const Size(76, 28));
    final paragraph = tester.widget<RichText>(
      find.descendant(of: selected, matching: find.byType(RichText)),
    );
    expect(paragraph.text.style!.color, Colors.white);
  });

  testWidgets('开关标题区域悬停不绘制整行背景', (tester) async {
    // 比较真实绘制像素；指针位于标题而非36pt开关，hover不得改变该行背景。
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: NativeGlassSwitchTile(
              title: '登录时启动',
              value: true,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final beforePixels = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return pixels;
    });
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(tester.getCenter(find.text('登录时启动').first));
    await tester.pumpAndSettle();
    final afterPixels = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return pixels;
    });
    expect(
      afterPixels!.buffer.asUint8List(),
      orderedEquals(beforePixels!.buffer.asUint8List()),
    );
    await mouse.removePointer();
  });

  testWidgets('开关只有按钮响应，标题和空白不改变状态', (tester) async {
    // 36×32按钮外全部不应提交编辑；键盘焦点仍须允许切换。
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => NativeGlassSwitchTile(
              title: '仅使用快捷键',
              subtitle: '说明文字',
              value: enabled,
              onChanged: (value) => update(() => enabled = value),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('仅使用快捷键').first);
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    await tester.tapAt(const Offset(400, 30));
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 200));
    await mouse.moveTo(tester.getCenter(find.byType(NativeGlassSwitch)));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await mouse.moveTo(tester.getCenter(find.text('仅使用快捷键').first));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    await mouse.removePointer();
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
  });

  testWidgets('默认窗口单服务无需滚动且服务操作之间保留8pt空白', (tester) async {
    // 560×720为原生默认内容尺寸，单服务是常见设置路径；更多服务允许滚动。
    tester.view.physicalSize = const Size(560, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) return <String, Object?>{};
      if (call.method == MethodNames.getSettings) {
        return {
          'revision': 0,
          'services': [
            const ServiceConfig(
              id: 'saved',
              kind: 'openai',
              name: 'OpenAI',
              baseUrl: 'https://api.openai.com',
              model: 'gpt-test',
            ).toMap(),
          ],
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    final edit = tester.getRect(
      find.widgetWithIcon(IconButton, Icons.edit_outlined),
    );
    final delete = tester.getRect(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(edit.size, const Size(32, 32));
    expect(delete.left - edit.right, 8);
    expect(find.text('当翻译文本识别为主要语言时，会自动翻译成次要语言'), findsOneWidget);
    expect(find.text('点击录制；录制完成后自动保存；检查系统保留组合和可识别的全局占用。'), findsNothing);
    expect(find.byKey(const ValueKey('全局翻译快捷键')).hitTestable(), findsOneWidget);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, 0);
  });

  test('展示名称调整不改写持久化配置或自定义名称', () {
    // 已存默认名映射到产品名称；端点、ID与原始name仍原样序列化。
    const service = ServiceConfig(
      id: 'saved',
      kind: 'openai',
      name: 'OpenAI-compatible',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-v4-flash',
    );
    expect(service.displayName, 'OpenAI');
    expect(service.toMap()['name'], 'OpenAI-compatible');
    final custom = ServiceConfig.fromMap({...service.toMap(), 'name': '工作翻译'});
    expect(custom.displayName, '工作翻译');
    final existing = ServiceConfig.fromMap({
      ...service.toMap(),
      'kind': 'deepseek',
    });
    expect(existing.validate, returnsNormally);
    expect(existing.toMap()['id'], 'saved');
  });
}
