import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/overlay/dictionary_definition.dart';

/// 无参数；验证 macOS 词典纯文本释义按词条、词性、义项、例句与未识别片段拆行（#135）。
void main() {
  const headword = DefinitionLineKind.headword;
  const pos = DefinitionLineKind.partOfSpeech;
  const sense = DefinitionLineKind.sense;
  const example = DefinitionLineKind.example;
  const plain = DefinitionLineKind.plain;

  test('英汉词典：词条与音标、字母编号词性、义项、例句各成一行，同行中英文不拆开', () {
    // 边界：样本取自 macOS 英汉词典 pot 的真实输出片段；▸ 紧贴前文无空格仍要拆分；
    // 「‹ball›C. intransitive verb」中词性前是 › 而非空白；例句行去掉 ▸。
    const text =
        'pot 1 | BrE pɒt, AmE pɑt | A. noun ① Cooking (container for cooking) 锅 guō'
        '▸ pots and pans 锅碗瓢盆▸ for the pot 用于烹饪的 ② (container) 罐 guàn '
        'B. transitive verb ① (in snooker) 击…入袋 jī… rù dài ‹ball›'
        'C. intransitive verb ① (make pottery) 制作陶器 zhìzuò táoqì';
    expect(parseDefinition(text), const [
      DefinitionLine(headword, 'pot 1', phonetic: 'BrE pɒt, AmE pɑt'),
      DefinitionLine(pos, 'A. noun'),
      DefinitionLine(sense, '① Cooking (container for cooking) 锅 guō'),
      DefinitionLine(example, 'pots and pans 锅碗瓢盆'),
      DefinitionLine(example, 'for the pot 用于烹饪的'),
      DefinitionLine(sense, '② (container) 罐 guàn'),
      DefinitionLine(pos, 'B. transitive verb'),
      DefinitionLine(sense, '① (in snooker) 击…入袋 jī… rù dài ‹ball›'),
      DefinitionLine(pos, 'C. intransitive verb'),
      DefinitionLine(sense, '① (make pottery) 制作陶器 zhìzuò táoqì'),
    ]);
  });

  test('英汉词典：没有字母编号的单一词性与分节标题单独成行', () {
    // 边界：take-off 的词性只有「noun」，是词条段后第一个不含中文的短片段；
    // PHRASAL VERBS 标题后的短语条目没有分隔符号，整体保留为一行原文。
    const text =
        'take-off | BrE ˈteɪkɒf, AmE ˈteɪkˌɔf | noun ① Aviation 起飞 qǐfēi'
        '▸ take-off speed 起飞速度 ② Sport 起跳 qǐtiào '
        'PHRASAL VERBS pot on transitive verb [pot sth on] 把…移栽到大花盆';
    expect(parseDefinition(text), const [
      DefinitionLine(
        headword,
        'take-off',
        phonetic: 'BrE ˈteɪkɒf, AmE ˈteɪkˌɔf',
      ),
      DefinitionLine(pos, 'noun'),
      DefinitionLine(sense, '① Aviation 起飞 qǐfēi'),
      DefinitionLine(example, 'take-off speed 起飞速度'),
      DefinitionLine(sense, '② Sport 起跳 qǐtiào'),
      DefinitionLine(pos, 'PHRASAL VERBS'),
      DefinitionLine(plain, 'pot on transitive verb [pot sth on] 把…移栽到大花盆'),
    ]);
  });

  test('汉语词典：没有词条段时首段原样保留，义项编号仍分行', () {
    // 边界：「苹果」整段没有 | 与编号，只有一行原文；「瞤」含 ①② 时编号前的头部保留为原文行。
    const apple = '苹果 píngguǒ 名 落叶乔木，叶子椭圆形。果实也叫苹果，圆形，味甜。';
    expect(parseDefinition(apple), const [DefinitionLine(plain, apple)]);
    expect(parseDefinition('瞤 rún （瞤）〈文〉①动 眼皮跳动。 ②动 肌肉抽搐。'), const [
      DefinitionLine(plain, '瞤 rún （瞤）〈文〉'),
      DefinitionLine(sense, '①动 眼皮跳动。'),
      DefinitionLine(sense, '②动 肌肉抽搐。'),
    ]);
  });

  test('未识别格式不丢内容：普通句子与句中大写缩写保持一行', () {
    // 边界：句中的「NATO」不是已知分节标题，「U.S.」的大写字母后不是「. 小写词」，都不触发分行。
    const text = 'Member of NATO since 1949, allied with the U.S. on defense.';
    expect(parseDefinition(text), const [DefinitionLine(plain, text)]);
  });
}
