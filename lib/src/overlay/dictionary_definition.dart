import 'package:flutter/material.dart';

/// 词典释义行的种类，决定字号、颜色与缩进（#135）。
enum DefinitionLineKind { headword, partOfSpeech, sense, example, plain }

/// 词典释义拆分后的一行；phonetic 只在词条行出现。
class DefinitionLine {
  /// kind 为行种类，text 为显示文字，phonetic 为词条行的音标。
  const DefinitionLine(this.kind, this.text, {this.phonetic});
  final DefinitionLineKind kind;
  final String text;
  final String? phonetic;

  /// other 为比较对象；返回种类、文字与音标是否都相同。
  @override
  bool operator ==(Object other) =>
      other is DefinitionLine &&
      other.kind == kind &&
      other.text == text &&
      other.phonetic == phonetic;

  /// 无参数；返回与 == 一致的哈希值。
  @override
  int get hashCode => Object.hash(kind, text, phonetic);

  /// 无参数；返回便于测试失败时阅读的描述。
  @override
  String toString() => 'DefinitionLine($kind, $text, $phonetic)';
}

/// 英汉词典首段「词条 | 音标 |」。
final _header = RegExp(r'^([^|]+)\|([^|]+)\|');

/// 分段位置：义项编号 ①–⑳ 与例句符号 ▸ 之前；「大写字母. 小写词」词性之前（前面为开头、空白或 ›）；
/// 已知分节标题之前。
final _boundary = RegExp(
  '(?=[①-⑳▸])'
  r'|(?<=^|[\s›])(?=[A-Z]\. [a-z])'
  r'|(?<=^|\s)(?=(?:PHRASAL VERBS|PHRASES|IDIOMS|DERIVATIVES)\b)',
);

/// 分节标题与其后正文。
final _section = RegExp(
  r'^(PHRASAL VERBS|PHRASES|IDIOMS|DERIVATIVES)\s+(.+)$',
  dotAll: true,
);

/// 中日韩文字；含有它的片段不是英文词性。
final _cjk = RegExp('[㐀-鿿]');

/// definition 为 macOS 词典返回的整段纯文本；返回按词条、词性、义项、例句拆分的行，
/// 无法识别的片段按原文作为 plain 行，不丢内容。
///
/// 已知限制：规则按 macOS 自带英汉词典与现代汉语词典的符号格式编写（「|」分隔词条与音标、
/// 「A. noun」词性、①–⑳ 义项、▸ 例句、全大写分节标题）；换用其他词典或出现新符号格式时只部分分行，
/// 届时再补规则。
List<DefinitionLine> parseDefinition(String definition) {
  final text = definition.trim();
  final lines = <DefinitionLine>[];
  var rest = text;
  // 英汉词典以「词条 | 音标 |」开头；汉语词典没有该段，整段交给后续分段。
  final header = _header.firstMatch(text);
  if (header != null) {
    lines.add(
      DefinitionLine(
        DefinitionLineKind.headword,
        header[1]!.trim(),
        phonetic: header[2]!.trim(),
      ),
    );
    rest = text.substring(header.end);
  }
  final segments = rest
      .split(_boundary)
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final section = _section.firstMatch(segment);
    if (section != null) {
      // 分节标题单独一行，其后的短语条目保持原文。
      lines
        ..add(DefinitionLine(DefinitionLineKind.partOfSpeech, section[1]!))
        ..add(DefinitionLine(DefinitionLineKind.plain, section[2]!.trim()));
      continue;
    }
    final kind = switch (segment) {
      _ when segment.startsWith('▸') => DefinitionLineKind.example,
      _ when RegExp('^[①-⑳]').hasMatch(segment) => DefinitionLineKind.sense,
      _ when RegExp(r'^[A-Z]\. [a-z]').hasMatch(segment) =>
        DefinitionLineKind.partOfSpeech,
      // 有词条段且第一个片段是不含中文的短词组（如「noun」）时视为无字母编号的词性。
      _
          when header != null &&
              index == 0 &&
              !_cjk.hasMatch(segment) &&
              segment.split(' ').length <= 3 =>
        DefinitionLineKind.partOfSpeech,
      _ => DefinitionLineKind.plain,
    };
    // 例句行去掉 ▸ 符号，以缩进区分。
    final shown = kind == DefinitionLineKind.example
        ? segment.substring(1).trim()
        : segment;
    lines.add(DefinitionLine(kind, shown));
  }
  return lines;
}

/// 按 #67「词典释义分行」样式逐行显示词典释义，整栏可选择复制。
class DictionaryDefinitionView extends StatelessWidget {
  /// definition 为词典返回的原文，渲染前经 parseDefinition 拆行。
  const DictionaryDefinitionView({super.key, required this.definition});
  final String definition;

  /// context 提供主题颜色；返回按行种类排版的释义列。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /// size/line 为字号与行高（pt），color 为文字颜色，weight 为字重；返回对应文字样式。
    TextStyle style(
      double size,
      double line,
      Color color, [
      FontWeight? weight,
    ]) => TextStyle(
      fontSize: size,
      height: line / size,
      color: color,
      fontWeight: weight,
    );

    // parseDefinition 把整段纯文本拆成词条、词性、义项、例句与未识别行。
    final lines = parseDefinition(definition);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in lines)
            switch (line.kind) {
              DefinitionLineKind.headword => Text.rich(
                TextSpan(
                  text: line.text,
                  style: style(14, 22, colors.onSurface, FontWeight.w500),
                  children: [
                    const WidgetSpan(child: SizedBox(width: 6)),
                    TextSpan(
                      text: line.phonetic,
                      style: style(12, 22, colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              DefinitionLineKind.partOfSpeech => Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(line.text, style: style(12, 20, colors.primary)),
              ),
              DefinitionLineKind.sense => Padding(
                padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
                child: Text(line.text, style: style(13, 20, colors.onSurface)),
              ),
              DefinitionLineKind.example => Padding(
                padding: const EdgeInsets.only(left: 24, top: 1, bottom: 1),
                child: Text(
                  line.text,
                  style: style(12, 18, colors.onSurfaceVariant),
                ),
              ),
              DefinitionLineKind.plain => Text(
                line.text,
                style: style(13, 20, colors.onSurface),
              ),
            },
        ],
      ),
    );
  }
}
