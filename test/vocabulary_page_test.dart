import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/history/vocabulary_page.dart';

/// 无参数；用假历史通道验证生词本分段的展示、删除、导出反馈与空列表状态。
void main() {
  testWidgets('生词条目显示单词、译文与释义，删除后消失，导出成功显示保存路径', (tester) async {
    const channel = MethodChannel('test/vocabulary-page');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 假主引擎：两条生词，删除即从列表移除；保存面板返回用户选择的路径。
    final rows = <Map<String, Object>>[
      {
        'word': 'serendipity',
        'translation': '机缘凑巧',
        'definition': 'noun 机缘凑巧',
        'addedAt': 2,
      },
      {
        'word': 'pear',
        'translation': '梨',
        'definition': 'noun 梨',
        'addedAt': 1,
      },
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.vocabularyList:
          return rows;
        case MethodNames.deleteVocabulary:
          rows.removeWhere(
            (row) => row['word'] == (call.arguments as Map)['word'],
          );
          return null;
        case MethodNames.vocabularyCsv:
          return '"pear","梨","noun 梨"\n';
        case MethodNames.saveTextFile:
          return '/Users/test/TranslateApp 生词本.csv';
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VocabularyPage(channel: channel, version: 0)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('serendipity'), findsOneWidget);
    expect(find.text('机缘凑巧'), findsOneWidget);
    expect(find.text('noun 梨'), findsOneWidget);

    await tester.tap(find.byTooltip('删除生词').first);
    await tester.pumpAndSettle();
    expect(find.text('serendipity'), findsNothing);
    expect(find.text('pear'), findsOneWidget);

    await tester.tap(find.text('导出 CSV'));
    await tester.pumpAndSettle();
    expect(find.text('已导出到 /Users/test/TranslateApp 生词本.csv'), findsOneWidget);

    // 边界：删到为空后显示空状态，导出按钮禁用。
    await tester.tap(find.byTooltip('删除生词'));
    await tester.pumpAndSettle();
    expect(find.text('生词本为空'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '导出 CSV'))
          .onPressed,
      isNull,
    );
  });
}
