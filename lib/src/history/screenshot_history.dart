import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import '../common/constants/method_names.dart';

/// 一条截图历史；path 为历史目录内的 PNG，exists 标记文件是否仍在（#29）。
class ScreenshotRecord {
  /// 各字段为数据库行与文件状态；创建不可变记录。
  const ScreenshotRecord({
    required this.id,
    required this.path,
    required this.width,
    required this.height,
    required this.capturedAt,
    required this.exists,
  });

  /// map 为通道传输字典；返回截图历史记录。
  factory ScreenshotRecord.fromMap(Map<Object?, Object?> map) =>
      ScreenshotRecord(
        id: map['id'] as int,
        path: map['path'] as String,
        width: map['width'] as int,
        height: map['height'] as int,
        capturedAt: map['capturedAt'] as int,
        exists: map['exists'] as bool,
      );

  final int id;
  final String path;
  final int width;
  final int height;
  final int capturedAt;
  final bool exists;

  /// 无参数；返回可经平台通道传输的字典。
  Map<String, Object> toMap() => {
    'id': id,
    'path': path,
    'width': width,
    'height': height,
    'capturedAt': capturedAt,
    'exists': exists,
  };
}

/// 截图历史；元数据与翻译历史共用 SQLite，图片只写入 directory，清理不触碰用户另存的截图（#29）。
class ScreenshotHistoryStore {
  /// database 为主引擎数据库，directory 为历史图片目录，onChanged 在写入或删除后通知历史窗口；建表但不写数据。
  ScreenshotHistoryStore(this.database, this.directory, {this.onChanged}) {
    database.execute('''
CREATE TABLE IF NOT EXISTS screenshot_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  capture_id TEXT NOT NULL UNIQUE,
  file_name TEXT NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  captured_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS history_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
    // 默认关闭；仅在缺少开关记录时写入，保留用户已有选择。
    database.execute('''
INSERT INTO history_meta(key, value) VALUES('screenshotRecording', '0')
ON CONFLICT(key) DO NOTHING
''');
  }

  /// 最多保留的截图条数。
  static const maxEntries = 100;

  /// 只保留截图时间在此时长内的记录。
  static const retention = Duration(days: 30);

  final Database database;
  final Directory directory;

  /// 写入或删除后的变更信号，不携带图片内容。
  final void Function()? onChanged;

  /// 无参数；返回是否记录新截图，默认关闭。
  bool get recordingEnabled =>
      database
          .select(
            "SELECT value FROM history_meta WHERE key = 'screenshotRecording'",
          )
          .first['value'] ==
      '1';

  set recordingEnabled(bool value) {
    database.execute(
      "INSERT INTO history_meta(key, value) VALUES('screenshotRecording', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [value ? '1' : '0'],
    );
  }

  /// captureId 为截图身份，png 为导出图，capturedAt/now 为截图与当前毫秒时间。
  /// 开关关闭时忽略；同一截图再次导出时覆盖为最后一次；写入后按条数与时长清理，无返回值。
  void record({
    required String captureId,
    required Uint8List png,
    required int capturedAt,
    required int now,
  }) {
    if (!recordingEnabled) return;
    final (width, height) = pngSize(png);
    directory.createSync(recursive: true);
    final fileName = '$captureId.png';
    // 先写临时文件再改名，读取方不会看到写了一半的图片。
    final temporary = File('${directory.path}/.$fileName.tmp')
      ..writeAsBytesSync(png, flush: true);
    temporary.renameSync('${directory.path}/$fileName');
    database.execute(
      '''INSERT INTO screenshot_history(capture_id, file_name, width, height, captured_at) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(capture_id) DO UPDATE SET width = excluded.width, height = excluded.height''',
      [captureId, fileName, width, height, capturedAt],
    );
    _prune(now);
    onChanged?.call();
  }

  /// 无参数；返回按截图时间倒序的全部记录，并标记图片文件是否仍存在。
  List<ScreenshotRecord> list() => [
    for (final row in database.select(
      'SELECT id, file_name, width, height, captured_at FROM screenshot_history ORDER BY captured_at DESC, id DESC',
    ))
      ScreenshotRecord(
        id: row['id'] as int,
        path: '${directory.path}/${row['file_name']}',
        width: row['width'] as int,
        height: row['height'] as int,
        capturedAt: row['captured_at'] as int,
        exists: File('${directory.path}/${row['file_name']}').existsSync(),
      ),
  ];

  /// id 为记录主键；删除记录及其历史目录内的图片，无返回值。
  void delete(int id) {
    _remove(
      database.select(
        'SELECT id, file_name FROM screenshot_history WHERE id = ?',
        [id],
      ),
    );
    onChanged?.call();
  }

  /// 无参数；删除全部截图历史及其图片，无返回值。
  void clear() {
    _remove(database.select('SELECT id, file_name FROM screenshot_history'));
    onChanged?.call();
  }

  /// now 为当前毫秒时间；删除超过保留时长或超出条数的旧记录及图片，无返回值。
  void _prune(int now) {
    _remove(
      database.select(
        '''SELECT id, file_name FROM screenshot_history
           WHERE captured_at < ? OR id NOT IN (
             SELECT id FROM screenshot_history ORDER BY captured_at DESC, id DESC LIMIT ?
           )''',
        [now - retention.inMilliseconds, maxEntries],
      ),
    );
  }

  /// rows 为待删除的 id 与文件名；只删除历史目录内的文件，文件已缺失时只删记录，无返回值。
  void _remove(ResultSet rows) {
    for (final row in rows) {
      final file = File('${directory.path}/${row['file_name']}');
      if (file.existsSync()) file.deleteSync();
      database.execute('DELETE FROM screenshot_history WHERE id = ?', [
        row['id'],
      ]);
    }
  }

  /// png 为 PNG 字节；返回 IHDR 中的像素宽高（PNG 签名后第 16–23 字节，大端）。
  static (int, int) pngSize(Uint8List png) {
    final data = ByteData.sublistView(png);
    return (data.getUint32(16), data.getUint32(20));
  }
}

/// store 为主引擎唯一截图历史，call 为截图窗口或历史窗口的请求，now 为当前毫秒时间；返回列表、开关或 null。
Object? handleScreenshotHistoryRequest(
  ScreenshotHistoryStore store,
  MethodCall call,
  int now,
) {
  final map = Map<Object?, Object?>.from(call.arguments as Map? ?? const {});
  switch (call.method) {
    case MethodNames.recordScreenshotHistory:
      store.record(
        captureId: map['id'] as String,
        png: map['bytes'] as Uint8List,
        capturedAt: map['capturedAt'] as int,
        now: now,
      );
      return null;
    case MethodNames.screenshotHistoryList:
      return [for (final record in store.list()) record.toMap()];
    case MethodNames.deleteScreenshotHistory:
      store.delete(map['id'] as int);
      return null;
    case MethodNames.clearScreenshotHistory:
      store.clear();
      return null;
    case MethodNames.screenshotHistoryRecording:
      return store.recordingEnabled;
    case MethodNames.setScreenshotHistoryRecording:
      store.recordingEnabled = map['enabled'] == true;
      return null;
    default:
      throw MissingPluginException('未知截图历史操作：${call.method}');
  }
}
