import 'package:flutter/painting.dart';

import '../common/constants/drawing_metrics.dart';

/// 一次截图的美化参数（#103）；background 为 BeautifyMetrics.backgrounds 的下标，长度单位为屏幕点。
class BeautifyStyle {
  /// 各字段含义见类说明；默认内边距 64pt、圆角 12pt、开启阴影。
  const BeautifyStyle({
    required this.background,
    this.padding = BeautifyMetrics.defaultPadding,
    this.cornerRadius = BeautifyMetrics.roundRadius,
    this.shadow = true,
  });
  final int background;
  final double padding;
  final double cornerRadius;
  final bool shadow;

  /// 参数为需替换的字段；返回新参数，未指定字段保留。
  BeautifyStyle copyWith({
    int? background,
    double? padding,
    double? cornerRadius,
    bool? shadow,
  }) => BeautifyStyle(
    background: background ?? this.background,
    padding: padding ?? this.padding,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    shadow: shadow ?? this.shadow,
  );
}

/// canvas 为目标画布，content 为截图内容区域，unit 为每个屏幕点对应的画布单位（预览为显示缩放，导出为像素倍率）。
/// 在内容外按内边距画渐变背景并在背景上画阴影；内容圆角之外的四角也由背景覆盖，内容本身不绘制。
/// 预览与导出共用此函数，保证两者一致；无返回值。
void paintBeautifyBackdrop(
  Canvas canvas,
  Rect content,
  BeautifyStyle style, {
  double unit = 1,
}) {
  final outer = content.inflate(style.padding * unit);
  final inner = RRect.fromRectAndRadius(
    content,
    Radius.circular(style.cornerRadius * unit),
  );
  // 背景是外框减去圆角内容区，圆角外的四个小角由背景色覆盖。
  final band = Path.combine(
    PathOperation.difference,
    Path()..addRect(outer),
    Path()..addRRect(inner),
  );
  final preset = BeautifyMetrics.backgrounds[style.background];
  canvas.drawPath(
    band,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [preset.from, preset.to],
      ).createShader(outer),
  );
  if (!style.shadow) return;
  // 阴影只画在背景上，不覆盖截图内容。
  canvas.save();
  canvas.clipPath(band);
  canvas.drawRRect(
    inner.shift(Offset(0, BeautifyMetrics.shadowOffset * unit)),
    Paint()
      ..color = BeautifyMetrics.shadowColor
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        // MaskFilter 的 sigma 约为模糊半径的一半。
        BeautifyMetrics.shadowBlur * unit / 2,
      ),
  );
  canvas.restore();
}
