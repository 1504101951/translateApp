/// 一次实时翻译会话的段落块缓存。
///
/// 键由调用方组合“服务＋语言方向＋段落原文”；逐字相同才算命中。
/// 按“键与译文字符数 × 2 字节”估算占用，超过预算时淘汰最久未用的条目。
/// 同一条目还记录该段落的临时错误次数和是否已判定不再发送。
class LiveBlockCache {
  /// budgetBytes 为内存预算，单位字节。
  LiveBlockCache({required this.budgetBytes});

  final int budgetBytes;
  // Map 保持插入顺序；每次使用都移到末尾，首个键即最久未用。
  final _entries = <String, _Entry>{};
  var _bytes = 0;

  /// 无参数；返回当前估算占用，单位字节。
  int get bytes => _bytes;

  /// key 为段落键。命中时返回译文并记为最近使用；未命中返回 null。
  String? translation(String key) => _touch(key)?.translation;

  /// key 为段落键，translation 为完整译文。写入后按预算淘汰最久未用的条目。
  void store(String key, String translation) {
    final entry = _take(key)..translation = translation;
    _put(key, entry);
  }

  /// key 为段落键；返回该段落在本次会话内的临时错误次数。
  int failures(String key) => _entries[key]?.failures ?? 0;

  /// key 为段落键；临时错误次数加一，无返回值。
  void noteFailure(String key) {
    final entry = _take(key)..failures += 1;
    _put(key, entry);
  }

  /// key 为段落键；返回该段落是否已判定不再发送。
  bool rejected(String key) => _entries[key]?.rejected ?? false;

  /// key 为段落键；标记该段落不再发送，无返回值。
  void reject(String key) {
    final entry = _take(key)..rejected = true;
    _put(key, entry);
  }

  /// 无参数；清空全部条目，无返回值。
  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  /// key 为段落键；存在时移到末尾并返回，不存在返回 null。
  _Entry? _touch(String key) {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry;
    return entry;
  }

  /// key 为段落键；取出已有条目并扣除其占用，没有则返回新条目。
  _Entry _take(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return _Entry();
    _bytes -= _cost(key, entry);
    return entry;
  }

  /// key/entry 为要写回的条目；放到末尾并淘汰到预算以内。
  void _put(String key, _Entry entry) {
    _entries[key] = entry;
    _bytes += _cost(key, entry);
    while (_bytes > budgetBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _bytes -= _cost(oldest, _entries.remove(oldest)!);
    }
  }

  /// key/entry 为一个条目；返回估算占用字节，中文按 2 字节计为上限。
  int _cost(String key, _Entry entry) =>
      (key.length + (entry.translation?.length ?? 0)) * 2;
}

class _Entry {
  String? translation;
  var failures = 0;
  var rejected = false;
}
