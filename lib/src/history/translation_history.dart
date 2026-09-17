import 'package:sqlite3/sqlite3.dart';

/// 一条完整成功的翻译记录。
class TranslationRecord {
  const TranslationRecord({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.detectedLanguage,
    required this.targetLanguage,
    required this.providerId,
    required this.completedAt,
    this.model,
  });

  final int id;
  final String sourceText;
  final String translatedText;
  final String detectedLanguage;
  final String targetLanguage;
  final String providerId;
  final String? model;
  final int completedAt;
}

/// SQLite 翻译历史；只在整篇成功后写入。database 由调用方提供以便测试用内存库。
class TranslationHistoryStore {
  TranslationHistoryStore(this.database) {
    database.execute('''
CREATE TABLE IF NOT EXISTS translation_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_text TEXT NOT NULL,
  translated_text TEXT NOT NULL,
  detected_language TEXT NOT NULL,
  target_language TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  model TEXT,
  completed_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS history_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
    final existing = database.select(
      "SELECT value FROM history_meta WHERE key = 'recording'",
    );
    if (existing.isEmpty) {
      database.execute(
        "INSERT INTO history_meta(key, value) VALUES('recording', '1')",
      );
    }
  }

  final Database database;

  /// 无参数；默认开启记录。
  bool get recordingEnabled {
    final rows = database.select(
      "SELECT value FROM history_meta WHERE key = 'recording'",
    );
    return rows.first['value'] == '1';
  }

  set recordingEnabled(bool value) {
    database.execute(
      "INSERT INTO history_meta(key, value) VALUES('recording', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [value ? '1' : '0'],
    );
  }

  /// 成功翻译写入一条；recording 关闭时忽略。
  void insert({
    required String sourceText,
    required String translatedText,
    required String detectedLanguage,
    required String targetLanguage,
    required String providerId,
    String? model,
    required int completedAt,
  }) {
    if (!recordingEnabled) return;
    database.execute(
      '''INSERT INTO translation_history(
        source_text, translated_text, detected_language, target_language, provider_id, model, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [
        sourceText,
        translatedText,
        detectedLanguage,
        targetLanguage,
        providerId,
        model,
        completedAt,
      ],
    );
  }

  /// offset 为已加载条数，limit 默认 10；按完成时间倒序。
  List<TranslationRecord> page({int offset = 0, int limit = 10}) {
    final rows = database.select(
      '''SELECT id, source_text, translated_text, detected_language, target_language, provider_id, model, completed_at
         FROM translation_history ORDER BY completed_at DESC, id DESC LIMIT ? OFFSET ?''',
      [limit, offset],
    );
    return [
      for (final row in rows)
        TranslationRecord(
          id: row['id'] as int,
          sourceText: row['source_text'] as String,
          translatedText: row['translated_text'] as String,
          detectedLanguage: row['detected_language'] as String,
          targetLanguage: row['target_language'] as String,
          providerId: row['provider_id'] as String,
          model: row['model'] as String?,
          completedAt: row['completed_at'] as int,
        ),
    ];
  }
}
