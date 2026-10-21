import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/widgets/native_glass.dart';
import 'markdown_view.dart';

/// 识别到的一个二维码或条码；symbology 为 Vision 类型名（如 qr、ean13），payload 为码的文字内容（#108）。
typedef RecognizedCode = ({String symbology, String payload});

/// payload 为码内容原文；返回它是否为可打开的 http/https 链接（需带主机名），规则与原生 openLink 校验一致。
bool isOpenableLink(String payload) {
  final uri = Uri.tryParse(payload);
  return uri != null &&
      ScreenshotDefaults.openableLinkSchemes.contains(
        uri.scheme.toLowerCase(),
      ) &&
      uri.host.isNotEmpty;
}

/// 截图里“识别文字”结果的弹窗；外观与尺寸沿用翻译弹窗，正文先列出二维码与条码，再渲染识别文字 Markdown。
///
/// 打开弹窗不写剪贴板：用户可以选中部分文字自行复制，或点“复制全部”复制 Markdown 原文。弹窗不自动关闭。
class RecognizedTextPanel extends StatelessWidget {
  /// text 为识别结果 Markdown 原文（可为空），codes 为按位置排序的码；onCopyAll 复制原文；
  /// onCopyCode 复制一个码的内容，onOpenLink 打开链接内容；onClose 关闭弹窗；
  /// onDrag 接收标题区拖动的位移，由调用方移动弹窗。
  const RecognizedTextPanel({
    super.key,
    required this.text,
    this.codes = const [],
    required this.onCopyAll,
    required this.onCopyCode,
    required this.onOpenLink,
    required this.onClose,
    required this.onDrag,
  });

  /// 与翻译结果弹窗相同的尺寸。
  static const size = Size(720, 420);
  final String text;
  final List<RecognizedCode> codes;
  final VoidCallback onCopyAll;
  final ValueChanged<String> onCopyCode;
  final ValueChanged<String> onOpenLink;
  final VoidCallback onClose;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return NativeGlassSurface(
      child: Padding(
        padding: const EdgeInsets.all(GlassMetrics.pagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 整块 56pt 标题区可拖动；两个按钮与正文保留各自的点击和选字手势。
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      key: const ValueKey('recognized-text-drag-area'),
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) => onDrag(details.delta),
                      child: Row(
                        children: [
                          Icon(
                            Icons.drag_indicator,
                            size: GlassMetrics.icon,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '识别结果',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 只有码没有文字时，码各自复制，不显示复制全部。
                  if (text.trim().isNotEmpty) ...[
                    NativeGlassSurface(
                      material: true,
                      child: IconButton(
                        onPressed: onCopyAll,
                        tooltip: '复制全部',
                        icon: const Icon(
                          Icons.copy_rounded,
                          size: GlassMetrics.icon,
                        ),
                        visualDensity: VisualDensity.standard,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  NativeGlassSurface(
                    material: true,
                    child: IconButton(
                      onPressed: onClose,
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, size: GlassMetrics.icon),
                      visualDensity: VisualDensity.standard,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SizedBox.expand(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(8),
                    // MarkdownView 只在显示时渲染识别结果；SelectionArea 让码内容、标题、段落、列表与表格内文字都可选中复制。
                    child: SelectionArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final code in codes)
                            _CodeRow(
                              code: code,
                              onCopy: () => onCopyCode(code.payload),
                              onOpen: isOpenableLink(code.payload)
                                  ? () => onOpenLink(code.payload)
                                  : null,
                            ),
                          if (text.trim().isNotEmpty)
                            MarkdownView(source: text),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 识别结果中的一条码：类型、完整内容与复制、打开链接操作（#108）。
class _CodeRow extends StatelessWidget {
  /// code 为码，onCopy 复制内容，onOpen 打开链接（内容不是可打开链接时为 null，不显示按钮）。
  const _CodeRow({required this.code, required this.onCopy, this.onOpen});

  final RecognizedCode code;
  final VoidCallback onCopy;
  final VoidCallback? onOpen;

  /// context 为构建上下文；返回类型标签、完整内容与操作按钮组成的一行。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // QR 码显示「二维码」，其余显示 Vision 类型名。
    final kind = code.symbology == 'qr'
        ? '二维码'
        : '条码 · ${code.symbology.toUpperCase()}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kind,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                // 链接完整显示，用户打开前能看到真实地址。
                Text(code.payload, style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          NativeGlassSurface(
            material: true,
            child: IconButton(
              onPressed: onCopy,
              tooltip: '复制内容',
              icon: const Icon(Icons.copy_rounded, size: GlassMetrics.icon),
              visualDensity: VisualDensity.standard,
            ),
          ),
          if (onOpen != null) ...[
            const SizedBox(width: 8),
            NativeGlassSurface(
              material: true,
              child: IconButton(
                onPressed: onOpen,
                tooltip: '打开链接',
                icon: const Icon(Icons.open_in_new, size: GlassMetrics.icon),
                visualDensity: VisualDensity.standard,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
