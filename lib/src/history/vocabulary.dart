import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import '../common/constants/method_names.dart';

/// 一条生词；word 为原文单词或短语，translation 为加入时的译文，definition 为词典释义，addedAt 为毫秒时间戳。
class VocabularyEntry {
  /// 各字段含义见类说明；创建不可变条目。
  const VocabularyEntry({
    required this.word,
    required this.translation,
    required this.definition,
    required this.addedAt,
  });

  /// map 为通道传输字典；返回生词条目。
  factory VocabularyEntry.fromMap(Map<Object?, Object?> map) => VocabularyEntry(
    word: map['word'] as String,
    translation: map['translation'] as String,
    definition: map['definition'] as String,
    addedAt: map['addedAt'] as int,
  );

  final String word;
  final String translation;
  final String definition;
  final int addedAt;

  /// 无参数；返回可经平台通道传输的字典。
  Map<String, Object> toMap() => {
    'word': word,
    'translation': translation,
    'definition': definition,
    'addedAt': addedAt,
  };
}

/// 生词本；与翻译历史共用主引擎的 SQLite，单词不区分大小写唯一（#102）。
class VocabularyStore {
  /// database 为主引擎数据库，onChanged 在增删成功后通知历史窗口刷新；创建表但不写入数据。
  VocabularyStore(this.database, {this.onChanged}) {
    database.execute('''
CREATE TABLE IF NOT EXISTS vocabulary (
  word TEXT PRIMARY KEY COLLATE NOCASE,
  translation TEXT NOT NULL,
  definition TEXT NOT NULL,
  added_at INTEGER NOT NULL
)''');
  }

  final Database database;

  /// 增删成功后的变更信号，不携带生词内容。
  final void Function()? onChanged;

  /// entry 为待加入条目；同一单词已存在时更新译文、释义与加入时间，无返回值。
  void add(VocabularyEntry entry) {
    database.execute(
      '''INSERT INTO vocabulary(word, translation, definition, added_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(word) DO UPDATE SET translation = excluded.translation,
           definition = excluded.definition, added_at = excluded.added_at''',
      [entry.word, entry.translation, entry.definition, entry.addedAt],
    );
    onChanged?.call();
  }

  /// word 为待删除单词（不区分大小写）；不存在时无变化，无返回值。
  void delete(String word) {
    database.execute('DELETE FROM vocabulary WHERE word = ?', [word]);
    onChanged?.call();
  }

  /// 无参数；返回按加入时间倒序的全部生词。
  List<VocabularyEntry> list() => [
    for (final row in database.select(
      'SELECT word, translation, definition, added_at FROM vocabulary ORDER BY added_at DESC, word',
    ))
      VocabularyEntry(
        word: row['word'] as String,
        translation: row['translation'] as String,
        definition: row['definition'] as String,
        addedAt: row['added_at'] as int,
      ),
  ];

  /// 无参数；返回 Anki 可直接导入的 CSV：UTF-8、无表头，列依次为单词、译文、释义。
  /// 每个字段都加双引号并把引号写成两个，换行保留在字段内，不会串列。
  String csv() => [
    for (final entry in list())
      [
        entry.word,
        entry.translation,
        entry.definition,
      ].map((field) => '"${field.replaceAll('"', '""')}"').join(','),
  ].map((line) => '$line\n').join();
}

/// vocabulary 为主引擎唯一生词本，call 为历史窗口的生词请求；返回条目列表、CSV 文本或 null。
Object? handleVocabularyRequest(VocabularyStore vocabulary, MethodCall call) {
  switch (call.method) {
    case MethodNames.vocabularyList:
      return [for (final entry in vocabulary.list()) entry.toMap()];
    case MethodNames.deleteVocabulary:
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      vocabulary.delete(map['word'] as String);
      return null;
    case MethodNames.vocabularyCsv:
      return vocabulary.csv();
    default:
      throw MissingPluginException('未知生词本操作：${call.method}');
  }
}
