import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/live_block_cache.dart';

void main() {
  test('占用恰好等于预算时保留全部条目，超出后淘汰最久未用的条目', () {
    // 作用：缓存按内存预算淘汰。
    // 边界：每条占用 (键 1 字符＋译文 4 字符)×2＝10 字节；预算 20 字节恰好放两条，第三条写入后最早的一条被淘汰。
    final cache = LiveBlockCache(budgetBytes: 20);
    cache.store('a', '1111');
    cache.store('b', '2222');
    expect(cache.bytes, 20);
    expect(cache.translation('a'), '1111');
    expect(cache.translation('b'), '2222');
    cache.store('c', '3333');
    expect(cache.bytes, 20);
    expect(cache.translation('a'), isNull);
    expect(cache.translation('b'), '2222');
    expect(cache.translation('c'), '3333');
  });

  test('命中会把条目记为最近使用，之后淘汰的是另一条', () {
    // 作用：淘汰顺序按最近使用而不是写入顺序。
    // 边界：a 先写入但在 c 写入前被读取，被淘汰的是 b。
    final cache = LiveBlockCache(budgetBytes: 20);
    cache.store('a', '1111');
    cache.store('b', '2222');
    expect(cache.translation('a'), '1111');
    cache.store('c', '3333');
    expect(cache.translation('a'), '1111');
    expect(cache.translation('b'), isNull);
  });

  test('失败次数与拒发标记按键记录，清空后全部归零', () {
    // 作用：同一段落的重试次数在会话内累计，会话结束时清零。
    // 边界：未记录的键为 0 次且未拒发；clear 之后占用为 0。
    final cache = LiveBlockCache(budgetBytes: 1000);
    expect(cache.failures('a'), 0);
    expect(cache.rejected('a'), isFalse);
    cache.noteFailure('a');
    cache.noteFailure('a');
    cache.reject('b');
    expect(cache.failures('a'), 2);
    expect(cache.rejected('b'), isTrue);
    expect(cache.translation('a'), isNull);
    cache.clear();
    expect(cache.failures('a'), 0);
    expect(cache.rejected('b'), isFalse);
    expect(cache.bytes, 0);
  });
}
