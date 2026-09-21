import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/history/history_app.dart';
import 'package:translate_app/src/history/translation_history.dart';

/// 无参数；用真实 SQLite 驱动窗口，验证卡片顺序、跨页浏览与保存失败反馈。
void main() {
  const channel = MethodChannel('test/history-window');
  late Database database;
  late TranslationHistoryStore store;

  setUp(() {
    database = sqlite3.openInMemory();
    store = TranslationHistoryStore(database);
    // 仅替代原生转发层；查询、游标和开关均使用真实数据库结果。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          try {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case MethodNames.historyRecording:
                return store.recordingEnabled;
              case MethodNames.setHistoryRecording:
                store.recordingEnabled = args['enabled'] as bool;
                return null;
              case MethodNames.historyPage:
                final before = args['before'] as Map?;
                return [
                  for (final item in store.page(
                    before: before == null
                        ? null
                        : (
                            completedAt: before['completedAt'] as int,
                            id: before['id'] as int,
                          ),
                  ))
                    {
                      'id': item.id,
                      'sourceText': item.sourceText,
                      'translatedText': item.translatedText,
                      'detectedLanguage': item.detectedLanguage,
                      'targetLanguage': item.targetLanguage,
                      'providerId': item.providerId,
                      'model': item.model,
                      'completedAt': item.completedAt,
                      'sourceLabel': item.sourceLabel,
                    },
                ];
              default:
                throw MissingPluginException(call.method);
            }
          } on SqliteException catch (error) {
            throw PlatformException(
              code: 'history_storage',
              message: error.message,
            );
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    database.close();
  });

  testWidgets('来源与本地日期组成标题，译文在原文上方，滚动可读第三页', (tester) async {
    // 23 条跨越两次 10 条边界；520×640 与实际历史窗口一致。
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 23; i++) {
      store.insert(
        sourceText: 'source-$i',
        translatedText: '译文-$i',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        providerId: 'google',
        completedAt: DateTime(2026, 9, 19, 9, 30, i).millisecondsSinceEpoch,
        sourceLabel: i == 22 ? '截图' : 'Safari',
      );
    }
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.text('截图'), findsOneWidget);
    expect(find.text('2026-09-19 09:30'), findsWidgets);
    expect(
      tester.getTopLeft(find.text('译文-22')).dy,
      lessThan(tester.getTopLeft(find.text('source-22')).dy),
    );
    await tester.scrollUntilVisible(
      find.text('source-0'),
      400,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
    expect(find.text('source-0'), findsOneWidget);
    expect(find.text('译文-0'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('已显示全部历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长文及窄窗口可阅读，关闭记录保留卡片，存储失败不伪装保存成功', (tester) async {
    // 320pt 约束验证标题换行；只读 SQLite 真实触发保存失败，不能乐观切换开关。
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.insert(
      sourceText: '原文第一段\n\n${'long text ' * 60}',
      translatedText: '完整译文\n保留换行',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 1000,
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.text('未记录来源'), findsOneWidget);
    database.execute('PRAGMA query_only = ON');
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      isTrue,
    );
    expect(find.textContaining('readonly'), findsOneWidget);
    database.execute('PRAGMA query_only = OFF');
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(store.recordingEnabled, isFalse);
    expect(find.text('已暂停记录；已有历史仍保留。'), findsOneWidget);
    expect(find.text('完整译文\n保留换行'), findsOneWidget);
    expect(store.page(), hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
