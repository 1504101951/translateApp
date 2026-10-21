import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';

/// color 为源像素颜色；返回大写的 `#RRGGBB`（#111）。
String colorHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// start/end 为截图像素坐标；返回「长度 px（Δx × Δy）」，长度保留 1 位小数，Δ 取绝对值并四舍五入（#111）。
String rulerLabel(Offset start, Offset end) {
  final delta = end - start;
  return '${delta.distance.toStringAsFixed(1)} px'
      '（${delta.dx.abs().round()} × ${delta.dy.abs().round()}）';
}

/// 取色悬停标签与标尺测量线的叠加层；只显示，不接收指针，不进入导出与撤销（#111）。
class MeasureLayer extends StatelessWidget {
  /// imageSize 为截图像素尺寸；ruler 为标尺两端（截图像素），picker 为取色悬停点（截图像素），
  /// pickerColor 为该点源像素颜色（尚未解码时为 null，不显示取色标签）。
  const MeasureLayer({
    super.key,
    required this.imageSize,
    required this.ruler,
    required this.picker,
    required this.pickerColor,
  });

  final Size imageSize;
  final ({Offset start, Offset end})? ruler;
  final Offset? picker;
  final Color? pickerColor;

  /// context 为画布上下文；返回铺满画布的测量线与标签。
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // 截图像素按画布与截图的比例映射到显示点。
        Offset toLocal(Offset point) => Offset(
          point.dx / imageSize.width * size.width,
          point.dy / imageSize.height * size.height,
        );
        final ruler = this.ruler;
        final picker = this.picker;
        final pickerColor = this.pickerColor;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (ruler != null) ...[
              CustomPaint(
                painter: _RulerPainter(
                  start: toLocal(ruler.start),
                  end: toLocal(ruler.end),
                ),
              ),
              _label(
                anchor: toLocal(ruler.end),
                canvas: size,
                key: const Key('ruler-label'),
                child: Text(rulerLabel(ruler.start, ruler.end), style: _style),
              ),
            ],
            if (picker != null && pickerColor != null)
              _label(
                anchor: toLocal(picker),
                canvas: size,
                key: const Key('eyedropper-label'),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: MeasureMetrics.swatchSize,
                      height: MeasureMetrics.swatchSize,
                      decoration: BoxDecoration(
                        color: pickerColor,
                        border: Border.all(
                          color: Colors.white,
                          width: MeasureMetrics.swatchBorder,
                        ),
                        borderRadius: BorderRadius.circular(
                          MeasureMetrics.swatchRadius,
                        ),
                      ),
                    ),
                    const SizedBox(width: MeasureMetrics.swatchGap),
                    Text(colorHex(pickerColor), style: _style),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );

  /// 标签文字：白色等宽数字，字号同选区尺寸标签。
  static const _style = TextStyle(
    color: Colors.white,
    fontSize: CropMetrics.labelFontSize,
    fontFeatures: [ui.FontFeature.tabularFigures()],
  );

  /// anchor 为指针或终点的画布坐标，canvas 为画布尺寸，key 为标签身份，child 为标签内容；
  /// 返回定位后的标签：默认在锚点右下各 12pt；锚点在画布右半时放到左侧，下方放不下 12pt 加标签高度时放到上方。
  static Widget _label({
    required Offset anchor,
    required Size canvas,
    required Key key,
    required Widget child,
  }) {
    const offset = MeasureMetrics.labelOffset;
    final left = anchor.dx <= canvas.width / 2;
    final below = anchor.dy + offset + CropMetrics.labelHeight <= canvas.height;
    return Positioned(
      left: left ? anchor.dx + offset : null,
      right: left ? null : canvas.width - anchor.dx + offset,
      top: below
          ? anchor.dy + offset
          : math.max(0, anchor.dy - offset - CropMetrics.labelHeight),
      child: Container(
        key: key,
        height: CropMetrics.labelHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: CropMetrics.labelPadding,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CropMetrics.labelBackground,
          borderRadius: BorderRadius.circular(CropMetrics.labelRadius),
        ),
        child: child,
      ),
    );
  }
}

/// 标尺测量线：先画黑色 60% 描边再画白线，两端各画垂直于线的端点线。
class _RulerPainter extends CustomPainter {
  /// start/end 为两端的画布坐标。
  const _RulerPainter({required this.start, required this.end});

  final Offset start;
  final Offset end;

  /// canvas 为画布；按描边、白线两遍绘制主线与端点线，无返回值。
  @override
  void paint(Canvas canvas, Size size) {
    final delta = end - start;
    // 起点与终点重合时没有方向，只画主线（一个点）不画端点线。
    final normal = delta.distance == 0
        ? Offset.zero
        : Offset(-delta.dy, delta.dx) /
              delta.distance *
              (MeasureMetrics.tickLength / 2);
    for (final (width, color) in [
      (MeasureMetrics.outlineWidth, CropMetrics.labelBackground),
      (MeasureMetrics.lineWidth, Colors.white),
    ]) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(start, end, paint);
      if (normal == Offset.zero) continue;
      for (final point in [start, end]) {
        canvas.drawLine(point - normal, point + normal, paint);
      }
    }
  }

  /// oldDelegate 为上一帧绘制器；端点变化时重绘。
  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) =>
      oldDelegate.start != start || oldDelegate.end != end;
}
