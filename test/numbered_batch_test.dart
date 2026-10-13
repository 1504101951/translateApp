import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/numbered_batch.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// chunks 为模型依次输出的文本片段，count 为批次段落数。
/// 返回各下标累计得到的译文；没有译文的下标不出现。
Map<int, String> _parse(List<String> chunks, int count) {
  final parser = NumberedBatchParser(count);
  final result = <int, String>{};
  void take(List<BatchItemUpdate> updates) {
    for (final update in updates) {
      result[update.index] = (result[update.index] ?? '') + update.addition;
    }
  }

  chunks.map(parser.add).forEach(take);
  take(parser.finish());
  return result;
}

void main() {
  test('段落内的换行改为空格后逐行编号', () {
    // 作用：一行只对应一个段落，换行才能作为段落边界。
    // 边界：原文含 \r\n 时合并为一个空格。
    expect(numberedBatchText(['a\r\nb', 'c']), '[1] a b\n[2] c');
  });

  test('编号被拆在两个片段之间时仍能归属，增量在行内逐步给出', () {
    // 作用：流式文本的切分位置不影响归属。
    // 边界：片段在“[”“1”“]”之间、以及换行与下一个编号之间断开。
    final parser = NumberedBatchParser(2);
    expect(parser.add('['), isEmpty);
    expect(parser.add('1'), isEmpty);
    final first = parser.add('] 你');
    expect(first.single.index, 0);
    expect(first.single.addition, '你');
    expect(parser.add('好\n[').single.addition, '好');
    final second = parser.add('2] 世界');
    expect(second.single.index, 1);
    expect(second.single.addition, '世界');
    expect(parser.finish(), isEmpty);
  });

  test('乱序、缺号、前言与续行按规则归属', () {
    // 作用：模型不严格遵守格式时不把译文归到错误的段落。
    // 边界：首个编号之前的文本丢弃；编号 2 缺失则下标 1 没有译文；
    // 不以编号开头的行是上一段的续行；“[注]”不是编号。
    expect(
      _parse(['好的，以下是译文：\n[3] 丙\n[1] 甲\n续行\n[注] 说明\n'], 3),
      {2: '丙', 0: '甲\n续行\n[注] 说明'},
    );
  });

  test('越界或重复的编号当作普通文本', () {
    // 作用：无效编号不能切换到不存在的段落，也不能覆盖已有段落。
    // 边界：批次只有 2 段时“[3]”越界；第二次出现的“[1]”算作当前段落的续行。
    expect(_parse(['[1] 甲\n[3] 丙\n[2] 乙\n[1] 重复'], 2), {
      0: '甲\n[3] 丙',
      1: '乙\n[1] 重复',
    });
  });

  test('流结束时行首的不完整编号按普通文本提交', () {
    // 作用：结尾的“[1”不会被一直扣住。
    // 边界：finish 之前不输出，finish 时作为当前段落的续行输出。
    final parser = NumberedBatchParser(1);
    expect(parser.add('[1] 甲\n[1').single.addition, '甲');
    expect(parser.finish().single.addition, '\n[1');
  });
}
