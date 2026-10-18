import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';

/// 识别结果 Markdown 中的一个块（#96「其他约定」4、#67「识别文字弹窗 Markdown 渲染（#96）」）。
/// 只覆盖原生 OCR 生成的四种结构；其他内容按段落原样保留，不丢字。
sealed class MarkdownBlock {
  const MarkdownBlock();
}

/// `# ` 开头的标题；text 不含井号。
class MarkdownHeading extends MarkdownBlock {
  const MarkdownHeading(this.text);
  final String text;
}

/// 连续非空行组成的段落；text 保留行内换行。
class MarkdownParagraph extends MarkdownBlock {
  const MarkdownParagraph(this.text);
  final String text;
}

/// 连续 `- ` 开头的行组成的列表；items 不含列表符号。
class MarkdownList extends MarkdownBlock {
  const MarkdownList(this.items);
  final List<String> items;
}

/// 连续 `|` 开头的行组成的表格；rows 首行为表头，已去掉分隔行并还原 `\|`，各行补齐到相同列数。
class MarkdownTable extends MarkdownBlock {
  const MarkdownTable(this.rows);
  final List<List<String>> rows;
}

/// 作用：把识别结果 Markdown 拆成块。
/// 参数 source：原生 OCR 返回的 Markdown 原文。
/// 返回：按原文顺序排列的块；空行分隔段落，其余无法识别的行并入段落。
List<MarkdownBlock> parseMarkdownBlocks(String source) {
  final blocks = <MarkdownBlock>[];
  final paragraph = <String>[];
  final list = <String>[];
  final table = <String>[];

  // 结束当前累积的结构；同一时刻最多一种结构在累积。
  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(MarkdownParagraph(paragraph.join('\n')));
    }
    if (list.isNotEmpty) blocks.add(MarkdownList(List.of(list)));
    if (table.isNotEmpty) blocks.add(MarkdownTable(_tableRows(table)));
    paragraph.clear();
    list.clear();
    table.clear();
  }

  for (final raw in source.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flush();
    } else if (line.startsWith('# ')) {
      flush();
      blocks.add(MarkdownHeading(line.substring(2).trim()));
    } else if (line.startsWith('- ')) {
      if (list.isEmpty) flush();
      list.add(line.substring(2).trim());
    } else if (line.startsWith('|')) {
      if (table.isEmpty) flush();
      table.add(line);
    } else {
      if (paragraph.isEmpty) flush();
      paragraph.add(line);
    }
  }
  flush();
  return blocks;
}

/// 作用：解析表格行。参数 lines：`|` 开头的连续行。
/// 返回：去掉 `| --- |` 分隔行后的单元格文字，`\|` 还原为 `|`，各行补齐到最大列数。
List<List<String>> _tableRows(List<String> lines) {
  final separator = RegExp(r'^:?-{3,}:?$');
  final rows = <List<String>>[];
  for (final line in lines) {
    final cells = _tableCells(line);
    if (cells.isNotEmpty && cells.every(separator.hasMatch)) continue;
    rows.add(cells);
  }
  final columns = rows.fold(
    0,
    (max, row) => row.length > max ? row.length : max,
  );
  return [
    for (final row in rows) [...row, ...List.filled(columns - row.length, '')],
  ];
}

/// 作用：按未转义的 `|` 切分一行表格。参数 line：表格行。返回：去掉首尾竖线后、两端空白已裁剪的单元格。
List<String> _tableCells(String line) {
  final cells = <String>[];
  final cell = StringBuffer();
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == r'\' && index + 1 < line.length && line[index + 1] == '|') {
      cell.write('|');
      index++;
    } else if (char == '|') {
      cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(char);
    }
  }
  cells.add(cell.toString().trim());
  // 行首与行尾的竖线各产生一个空单元格，去掉后才是实际列。
  if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
  if (cells.isNotEmpty &&
      cells.last.isEmpty &&
      line.trimRight().endsWith('|')) {
    cells.removeLast();
  }
  return cells;
}

/// 把识别结果 Markdown 渲染为标题、段落、列表与表格（#67「识别文字弹窗 Markdown 渲染（#96）」）。
/// 只负责展示；文字选中由外层 SelectionArea 提供，复制全部由调用方使用原文。
class MarkdownView extends StatelessWidget {
  /// source 为识别结果 Markdown 原文。
  const MarkdownView({super.key, required this.source});

  final String source;

  /// 作用：返回两个相邻块之间的间距。参数 previous、next：相邻块。
  /// 返回：标题之后 8、相邻段落之间 8、其他情况 12（#67 第 2、3、6 条）。
  static double gap(MarkdownBlock previous, MarkdownBlock next) {
    if (previous is MarkdownHeading) return 8;
    if (previous is MarkdownParagraph && next is MarkdownParagraph) return 8;
    return 12;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final body = TextStyle(
      fontSize: GlassMetrics.bodyFont,
      height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
      color: colors.onSurface,
    );
    final blocks = parseMarkdownBlocks(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, block) in blocks.indexed) ...[
          if (index > 0) SizedBox(height: gap(blocks[index - 1], block)),
          _block(block, body, colors),
        ],
      ],
    );
  }

  /// 作用：渲染一个块。参数 block：块；body：正文样式；colors：主题配色。返回：块控件。
  Widget _block(MarkdownBlock block, TextStyle body, ColorScheme colors) =>
      switch (block) {
        MarkdownHeading(:final text) => Text(
          text,
          style: body.copyWith(
            fontSize: 14,
            height: 20 / 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        MarkdownParagraph(:final text) => Text(text, style: body),
        MarkdownList(:final items) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, item) in items.indexed)
              Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•', style: body),
                    const SizedBox(width: 6),
                    Expanded(child: Text(item, style: body)),
                  ],
                ),
              ),
          ],
        ),
        MarkdownTable(:final rows) => SingleChildScrollView(
          // 表格宽于正文区时在表格内横向滚动，不截断文字。
          scrollDirection: Axis.horizontal,
          child: Table(
            border: TableBorder.all(color: colors.outlineVariant, width: 1),
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: [
              for (final (index, row) in rows.indexed)
                TableRow(
                  children: [
                    for (final cell in row)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          cell,
                          style: index == 0
                              ? body.copyWith(fontWeight: FontWeight.w600)
                              : body,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      };
}
