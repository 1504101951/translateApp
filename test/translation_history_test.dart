import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/history/translation_history.dart';

/// 无参数；验证真实 SQLite 的排序、分页、持久化与已有数据保留。
void main() {
  test('同毫秒的重复原文独立保存，分页期间新增记录不挤动后续页', () {
    // 12 条跨越 10 条边界；相同时间和原文验证 ID 次序与不去重。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(database);
    for (var i = 0; i < 12; i++) {
      store.insert(
        sourceText: 'same source',
        translatedText: 't$i',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        providerId: 'model-service',
        model: 'example-model',
        completedAt: 1000,
        sourceLabel: 'Safari',
      );
    }
    final first = store.page();
    expect(first, hasLength(10));
    expect(first.first.translatedText, 't11');
    expect(first.last.translatedText, 't2');
    expect(first.first.sourceLabel, 'Safari');
    expect(first.first.model, 'example-model');
    store.insert(
      sourceText: 'new',
      translatedText: '新',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 1001,
      sourceLabel: '截图',
    );
    final second = store.page(before: first.last.cursor);
    expect(second.map((item) => item.translatedText), ['t1', 't0']);
    expect(store.page(before: second.last.cursor), isEmpty);
    expect(store.page().first.sourceLabel, '截图');
  });

  test('关闭并重开数据库后保留记录及关闭开关，重新启用后可继续记录', () {
    // 磁盘库模拟重启；关闭记录不能删除原有结果或在重启后自动开启。
    final directory = Directory.systemTemp.createTempSync(
      'translation-history-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/history.sqlite';
    var database = sqlite3.open(path);
    var store = TranslationHistoryStore(database);
    store.insert(
      sourceText: 'Hello',
      translatedText: '你好',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 1000,
      sourceLabel: 'Safari',
    );
    store.recordingEnabled = false;
    database.close();
    database = sqlite3.open(path);
    addTearDown(database.close);
    store = TranslationHistoryStore(database);
    expect(store.recordingEnabled, isFalse);
    store.insert(
      sourceText: 'ignored',
      translatedText: 'ignored',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 2000,
    );
    expect(store.page().single.sourceText, 'Hello');
    expect(store.page().single.sourceLabel, 'Safari');
    expect(store.page().single.detectedLanguage, 'en');
    expect(store.page().single.targetLanguage, 'zh-CN');
    expect(store.page().single.providerId, 'google');
    expect(store.page().single.completedAt, 1000);
    store.recordingEnabled = true;
    store.insert(
      sourceText: 'Hello',
      translatedText: '你好',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 3000,
    );
    expect(store.page(), hasLength(2));
  });

  test('新增来源字段保留已有记录和关闭偏好，不猜测旧记录来源', () {
    // 使用已交付的数据库结构，验证扩展字段时没有清库或覆盖用户设置。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    database.execute('''
      CREATE TABLE translation_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT, source_text TEXT NOT NULL,
        translated_text TEXT NOT NULL, detected_language TEXT NOT NULL,
        target_language TEXT NOT NULL, provider_id TEXT NOT NULL,
        model TEXT, completed_at INTEGER NOT NULL
      );
      INSERT INTO translation_history VALUES(1, 'old', '旧译文', 'en', 'zh-CN', 'google', NULL, 1000);
      CREATE TABLE history_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO history_meta VALUES('recording', '0');
    ''');
    final store = TranslationHistoryStore(database);
    expect(store.page().single.translatedText, '旧译文');
    expect(store.page().single.sourceLabel, isNull);
    expect(store.recordingEnabled, isFalse);
  });
}
