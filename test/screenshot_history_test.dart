import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/history/screenshot_history.dart';

/// width/height 为像素尺寸；返回只含 PNG 签名与 IHDR 宽高的最小字节，足够存储层解析尺寸。
Uint8List fakePng(int width, int height) {
  final data = ByteData(33);
  for (final (index, byte) in [137, 80, 78, 71, 13, 10, 26, 10].indexed) {
    data.setUint8(index, byte);
  }
  data.setUint32(8, 13);
  data.setUint32(16, width);
  data.setUint32(20, height);
  return data.buffer.asUint8List();
}

/// 无参数；用内存 SQLite 与临时目录验证截图历史的开关、覆盖、清理与缺失文件（#29）。
void main() {
  late Directory directory;
  late ScreenshotHistoryStore store;
  const day = 24 * 60 * 60 * 1000;
  const now = 100 * day;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('screenshot-history-');
    store = ScreenshotHistoryStore(
      sqlite3.openInMemory(),
      Directory('${directory.path}/ScreenshotHistory'),
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('默认不记录；开启后写入图片与尺寸，同一截图再次导出只保留最后一次', () {
    // 边界：开关默认值为关闭；同一 captureId 的第二次导出尺寸不同，必须覆盖而不是新增。
    store.record(
      captureId: 'a',
      png: fakePng(10, 20),
      capturedAt: now,
      now: now,
    );
    expect(store.list(), isEmpty);
    store.recordingEnabled = true;
    store.record(
      captureId: 'a',
      png: fakePng(10, 20),
      capturedAt: now,
      now: now,
    );
    store.record(
      captureId: 'a',
      png: fakePng(30, 40),
      capturedAt: now,
      now: now,
    );
    final records = store.list();
    expect(records, hasLength(1));
    expect((records.single.width, records.single.height), (30, 40));
    expect(records.single.exists, isTrue);
    expect(File(records.single.path).readAsBytesSync(), fakePng(30, 40));
  });

  test('超过 100 条删除最早的记录及图片，超过 30 天的记录在下次写入时删除', () {
    // 边界：第 101 条触发按条数清理；恰好 30 天内保留，30 天外一毫秒删除。
    store.recordingEnabled = true;
    store.record(
      captureId: 'old',
      png: fakePng(1, 1),
      capturedAt: now - 30 * day - 1,
      now: now - 30 * day,
    );
    store.record(
      captureId: 'edge',
      png: fakePng(1, 1),
      capturedAt: now - 30 * day,
      now: now - 30 * day,
    );
    store.record(
      captureId: 'fresh',
      png: fakePng(1, 1),
      capturedAt: now,
      now: now,
    );
    final paths = store.list().map((r) => r.path).toList();
    expect(paths.map((p) => p.split('/').last), ['fresh.png', 'edge.png']);
    expect(File('${store.directory.path}/old.png').existsSync(), isFalse);
    for (var i = 0; i < 100; i++) {
      store.record(
        captureId: 'n$i',
        png: fakePng(1, 1),
        capturedAt: now + i + 1,
        now: now + i + 1,
      );
    }
    final kept = store.list();
    expect(kept, hasLength(100));
    expect(kept.last.path.split('/').last, 'n0.png');
    expect(File('${store.directory.path}/edge.png').existsSync(), isFalse);
    expect(File('${store.directory.path}/fresh.png').existsSync(), isFalse);
  });

  test('图片被移走时标记缺失仍可删除；清空删除全部历史图片', () {
    // 边界：文件缺失是外部操作导致的唯一不一致状态，列表不能因此失败。
    store.recordingEnabled = true;
    store.record(captureId: 'a', png: fakePng(1, 1), capturedAt: now, now: now);
    store.record(
      captureId: 'b',
      png: fakePng(1, 1),
      capturedAt: now + 1,
      now: now + 1,
    );
    final missing = store.list().last;
    File(missing.path).deleteSync();
    expect(store.list().last.exists, isFalse);
    store.delete(missing.id);
    expect(store.list().map((r) => r.path.split('/').last), ['b.png']);
    store.clear();
    expect(store.list(), isEmpty);
    expect(store.directory.listSync().whereType<File>(), isEmpty);
  });
}
