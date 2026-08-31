import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/overlay/overlay_probe.dart';

void main() {
  testWidgets('probe overlay counts taps', (tester) async {
    var hidden = false;
    await tester.pumpWidget(
      MaterialApp(
        home: OverlayProbe(onHide: () => hidden = true),
      ),
    );

    expect(find.text('点击次数 0'), findsOneWidget);
    await tester.tap(find.text('点击'));
    await tester.pump();
    expect(find.text('点击次数 1'), findsOneWidget);

    await tester.tap(find.text('隐藏'));
    await tester.pump();
    expect(hidden, isTrue);
  });
}
