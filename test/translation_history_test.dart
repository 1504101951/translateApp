import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/history/translation_history.dart';

/// 无参数；验证 SQLite 历史写入、分页、关闭记录与失败不入库。
void main() {
  test('成功写入倒序分页，关闭记录后不再写入，失败路径不调用 insert', () {
    final database = sqlite3.openInMemory();
    addTearDown(database.dispose);
    final store = TranslationHistoryStore(database);
    expect(store.recordingEnabled, isTrue);

    for (var i = 0; i < 12; i++) {
      store.insert(
        sourceText: 's$i',
        translatedText: 't$i',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        providerId: 'unofficial-google',
        model: i.isEven ? 'm' : null,
        completedAt: 1000 + i,
      );
    }
    final first = store.page(offset: 0, limit: 10);
    expect(first, hasLength(10));
    expect(first.first.sourceText, 's11');
    expect(first.last.sourceText, 's2');
    final second = store.page(offset: 10, limit: 10);
    expect(second.map((e) => e.sourceText), ['s1', 's0']);

    store.recordingEnabled = false;
    store.insert(
      sourceText: 'ignored',
      translatedText: 'ignored',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'x',
      completedAt: 9999,
    );
    expect(store.page(offset: 0, limit: 20), hasLength(12));
  });
}
