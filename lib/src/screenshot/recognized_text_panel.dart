import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';

/// 截图里“识别文字”结果的弹窗；外观与尺寸沿用翻译弹窗，只显示识别到的文字。
///
/// 打开弹窗不写剪贴板：用户可以选中部分文字自行复制，或点“复制全部”。弹窗不自动关闭。
class RecognizedTextPanel extends StatelessWidget {
  /// text 为识别到的全部文字；onCopyAll 复制全部文字；onClose 关闭弹窗；
  /// onDrag 接收标题区拖动的位移，由调用方移动弹窗。
  const RecognizedTextPanel({
    super.key,
    required this.text,
    required this.onCopyAll,
    required this.onClose,
    required this.onDrag,
  });

  /// 与翻译结果弹窗相同的尺寸。
  static const size = Size(720, 420);
  final String text;
  final VoidCallback onCopyAll;
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
                            '识别到的文字',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                    child: SelectableText(
                      text,
                      style: TextStyle(
                        fontSize: GlassMetrics.bodyFont,
                        height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
                        color: colors.onSurface,
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
