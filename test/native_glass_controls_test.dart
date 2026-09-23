import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';

/// 验证Spec的尺寸与真实交互边界；使用实际布局，不检查配置文件字符串。
void main() {
  testWidgets('真实外观分段的绘制像素在鼠标悬停前后保持一致', (tester) async {
    // 比较整段像素而非外层反馈容器，覆盖TextButton自身Ink高亮。
    final boundary = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: NativeGlassTheme.data(Brightness.light),
      home: Scaffold(body: RepaintBoundary(key: boundary, child:
        NativeGlassSegments<String>(value: 'light', options: const {
          'system': '跟随系统', 'light': '浅色', 'dark': '深色'}, onChanged: (_) {}))),
    ));
    await tester.pumpAndSettle();
    Future<List<int>> pixels() async {
      final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List().toList();
    }
    final before = await tester.runAsync(pixels);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(tester.getCenter(find.text('跟随系统')));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(pixels), before);
    await mouse.removePointer();
  });

  testWidgets('分段按钮悬停无高亮，按下反馈且释放选择生效', (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => NativeGlassSegments<int>(
              value: selected,
              options: const {0: '第一项', 1: '第二项'},
              onChanged: (v) => update(() => selected = v),
            ),
          ),
        ),
      ),
    );
    // 对实际反馈层的颜色做对照，不能把鼠标进入误画成第二个已选项。
    List<Color?> colors() => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .map((w) => (w.decoration as ShapeDecoration?)?.color)
        .toList();
    final before = colors();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    final target = tester.getCenter(find.text('第二项'));
    await mouse.moveTo(target);
    await tester.pumpAndSettle();
    expect(colors(), before);
    await mouse.down(target);
    await tester.pumpAndSettle();
    expect(colors(), isNot(before));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(colors(), before);
    await mouse.removePointer();
  });

  testWidgets('短按钮轮廓28pt且透明边缘可点击，输入32pt', (tester) async {
    // 32pt命中高度和28pt轮廓之间各2pt必须仍触发动作，不产生整行背景。
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  onPressed: () => presses++,
                  child: const Text('操作'),
                ),
              ),
              const NativeGlassField(label: '名称', child: TextField()),
            ],
          ),
        ),
      ),
    );
    final button = find.byType(TextButton);
    expect(tester.getSize(button).height, 28);
    expect(tester.getSize(button).width, 64);
    final bounds = tester.getRect(button);
    await tester.tapAt(Offset(bounds.center.dx, bounds.top - 1));
    expect(presses, 1);
    expect(tester.getSize(find.byType(TextField)).height, 32);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长当前值和菜单项换行完整展示，键盘能选择', (tester) async {
    // 长中文超过240pt选择器宽度，必须增长高度而不裁切，菜单在320pt内。
    const longName = '用于验收长中文内容能够完整展示的翻译服务名称';
    var selected = 'long';
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 520,
            child: StatefulBuilder(
              builder: (context, setState) => NativeGlassDropdown<String>(
                label: '默认翻译服务',
                value: selected,
                items: const {'long': longName, 'short': '短名称'},
                onChanged: (value) => setState(() => selected = value),
              ),
            ),
          ),
        ),
      ),
    );
    final trigger = find.byType(TextButton);
    expect(tester.getSize(trigger).width, lessThanOrEqualTo(240));
    expect(tester.getSize(trigger).height, greaterThan(28));
    final paragraph = tester.renderObject<RenderParagraph>(find.text(longName));
    expect(paragraph.didExceedMaxLines, isFalse);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final shortOption = find.widgetWithText(MenuItemButton, '短名称');
    expect(shortOption, findsOneWidget);
    await tester.tap(shortOption);
    await tester.pumpAndSettle();
    expect(selected, 'short');
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    // 打开时当前值获得焦点，向上选择前一项后回车提交。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'long');
    expect(tester.takeException(), isNull);
  });

  testWidgets('开关键盘反转状态且焦点不缩小滑块', (tester) async {
    // 16pt滑块在未聚焦和键盘聚焦后都保持尺寸，32pt命中高度不变。
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NativeGlassSwitch(
              label: '启用',
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(NativeGlassSwitch)), const Size(36, 32));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(value, true);
    final thumb = find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox && widget.width == 16 && widget.height == 16,
    );
    expect(tester.getSize(thumb), const Size(16, 16));
    expect(tester.takeException(), isNull);
  });
}
