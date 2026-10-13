import 'translation_types.dart';

/// texts 为同一批次的段落原文。返回“[编号] 原文”逐行排列的文本，编号从 1 开始；
/// 段落内的换行改为空格，保证一行只对应一个段落。
String numberedBatchText(List<String> texts) => [
  for (final (index, text) in texts.indexed)
    '[${index + 1}] ${text.replaceAll(RegExp(r'[\r\n]+'), ' ')}',
].join('\n');

/// 把模型按“[编号] 译文”逐行输出的流式文本归属到批次内的段落。
///
/// 行首编号有效且首次出现时切换到该段落；其余行算作当前段落的续行。
/// 第一个有效编号之前的文本不属于任何段落，直接丢弃。
class NumberedBatchParser {
  /// count 为批次内的段落数，有效编号为 1 至 count。
  NumberedBatchParser(this.count);

  final int count;
  static final _marker = RegExp(r'^\[(\d{1,4})\]');
  static final _partialMarker = RegExp(r'^\[\d{0,4}$');
  final _seen = <int>{};
  var _buffer = '';
  int? _index;
  // 当前行是否已经判定归属；行首可能是不完整的编号时保持未判定。
  var _decided = false;
  // 当前段落是否已有非空译文；用于去掉编号后的前导空白。
  var _started = false;
  // 续行前需要补回的换行。
  var _breakPending = false;

  /// chunk 为模型新增的文本。返回已能确定归属的增量，index 为批次内下标。
  List<BatchItemUpdate> add(String chunk) {
    _buffer += chunk;
    return _drain(end: false);
  }

  /// 无参数；流结束时调用。返回尚未提交的最后一段增量。
  List<BatchItemUpdate> finish() => _drain(end: true);

  /// end 为真表示不会再有新文本，行首的不完整编号按普通文本处理。
  List<BatchItemUpdate> _drain({required bool end}) {
    final updates = <BatchItemUpdate>[];
    while (true) {
      if (!_decided) {
        if (_buffer.isEmpty) break;
        final marker = _marker.firstMatch(_buffer);
        // 行首只到“[12”时还分不清是编号还是译文，等后续文本。
        if (marker == null && !end && _partialMarker.hasMatch(_buffer)) break;
        final index = marker == null ? null : int.parse(marker[1]!) - 1;
        if (index != null && index >= 0 && index < count && _seen.add(index)) {
          _index = index;
          _started = false;
          _breakPending = false;
          _buffer = _buffer.substring(marker!.end);
        }
        _decided = true;
      }
      final newline = _buffer.indexOf('\n');
      _emit(newline < 0 ? _buffer : _buffer.substring(0, newline), updates);
      if (newline < 0) {
        _buffer = '';
        break;
      }
      _buffer = _buffer.substring(newline + 1);
      _decided = false;
      _breakPending = _started;
    }
    return updates;
  }

  /// piece 为当前行已到达的文本，updates 为本次输出；没有当前段落时丢弃。
  void _emit(String piece, List<BatchItemUpdate> updates) {
    final index = _index;
    if (index == null) return;
    var text = _started ? piece : piece.trimLeft();
    if (text.isEmpty) return;
    if (_breakPending) {
      text = '\n$text';
      _breakPending = false;
    }
    _started = true;
    updates.add(BatchItemUpdate(index, text));
  }
}
