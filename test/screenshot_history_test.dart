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

  test('拼接与拆分结果不受记录开关限制，按给定顺序从上到下排列且身份不重复', () {
    // 边界：开关保持默认关闭仍要写入；同一时刻生成的三段需按列表顺序显示，第二次生成不覆盖第一次；
    // 已有 99 条时再加 3 条，按 100 条上限删除最早的 2 条。
    store.add([fakePng(1, 10), fakePng(2, 10), fakePng(3, 10)], now);
    expect([for (final record in store.list()) record.width], [1, 2, 3]);
    store.add([fakePng(4, 10)], now);
    expect(store.list(), hasLength(4));
    expect(store.list().first.width, 4);
    expect(store.list().every((record) => record.exists), isTrue);

    store.clear();
    store.recordingEnabled = true;
    for (var i = 0; i < 99; i++) {
      store.record(
        captureId: 'old-$i',
        png: fakePng(100 + i, 1),
        capturedAt: now - 1000 + i,
        now: now,
      );
    }
    store.add([fakePng(1, 1), fakePng(2, 1), fakePng(3, 1)], now);
    final widths = [for (final record in store.list()) record.width];
    expect(widths, hasLength(100));
    expect(widths.take(3), [1, 2, 3]);
    expect(widths, isNot(contains(100)));
    expect(widths, isNot(contains(101)));
    expect(widths.last, 102);
  });
}
