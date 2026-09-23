import 'package:sqlite3/sqlite3.dart';

/// 分页位置；时间与自增 ID 一起保证同毫秒记录及新增记录不会造成重复分页。
typedef HistoryCursor = ({int completedAt, int id});

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
    this.sourceLabel,
  });

  final int id;
  final String sourceText;
  final String translatedText;
  final String detectedLanguage;
  final String targetLanguage;
  final String providerId;
  final String? model;
  final int completedAt;

  /// 来源应用显示名称或「截图」；未记录来源的已有数据为空，不推断其来源。
  final String? sourceLabel;

  /// 无参数；返回供下一页查询使用的稳定时间/ID 游标。
  HistoryCursor get cursor => (completedAt: completedAt, id: id);

  /// map 为主引擎返回的完整历史字段；返回用于卡片展示的记录。
  factory TranslationRecord.fromMap(Map<Object?, Object?> map) =>
      TranslationRecord(
        id: map['id'] as int,
        sourceText: map['sourceText'] as String,
        translatedText: map['translatedText'] as String,
        detectedLanguage: map['detectedLanguage'] as String,
        targetLanguage: map['targetLanguage'] as String,
        providerId: map['providerId'] as String,
        completedAt: map['completedAt'] as int,
        model: map['model'] as String?,
        sourceLabel: map['sourceLabel'] as String?,
      );
}

/// SQLite 翻译历史；只在整篇成功后写入。database 由调用方提供以便测试用内存库。
class TranslationHistoryStore {
  TranslationHistoryStore(this.database, {this.onChanged}) {
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
    // 本地已有历史不能因新增来源字段丢失；只扩展表结构，不伪造旧记录的来源。
    final columns = database.select('PRAGMA table_info(translation_history)');
    if (!columns.any((column) => column['name'] == 'source_label')) {
      database.execute(
        'ALTER TABLE translation_history ADD COLUMN source_label TEXT',
      );
    }
    database.execute('''CREATE INDEX IF NOT EXISTS history_completed_order
      ON translation_history(completed_at DESC, id DESC)''');
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

  /// 成功落库后的变更信号，不包含原文等隐私内容。
  final void Function()? onChanged;

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
    String? sourceLabel,
  }) {
    if (!recordingEnabled) return;
    database.execute(
      '''INSERT INTO translation_history(
        source_text, translated_text, detected_language, target_language, provider_id, model, completed_at, source_label
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        sourceText,
        translatedText,
        detectedLanguage,
        targetLanguage,
        providerId,
        model,
        completedAt,
        sourceLabel,
      ],
    );
    onChanged?.call();
  }

  /// before 为上一页末条位置，首屏为空；limit 为正数；返回完成时间倒序记录。
  List<TranslationRecord> page({HistoryCursor? before, int limit = 10}) {
    if (limit < 1) throw ArgumentError.value(limit, 'limit', '必须为正数');
    // 使用稳定游标，浏览过程中新增翻译不会挤动 OFFSET 导致重复或漏项。
    final rows = database.select(
      '''SELECT id, source_text, translated_text, detected_language, target_language, provider_id, model, completed_at, source_label
         FROM translation_history
         ${before == null ? '' : 'WHERE (completed_at, id) < (?, ?)'}
         ORDER BY completed_at DESC, id DESC LIMIT ?''',
      [
        if (before != null) ...[before.completedAt, before.id],
        limit,
      ],
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
          sourceLabel: row['source_label'] as String?,
        ),
    ];
  }
}
