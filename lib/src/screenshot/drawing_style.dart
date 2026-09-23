import 'dart:ui';

import '../common/constants/screenshot_enums.dart';

/// 各标注组合使用的不可变样式；颜色为不透明sRGB，线宽为图像坐标单位。
class DrawingStyle {
  const DrawingStyle({
    this.color = ScreenshotDefaults.strokeColor,
    this.strokeWidth = 3,
  });

  final Color color;
  final double strokeWidth;

  /// 传入需替换的颜色/线宽，返回独立快照，不改变已绘制对象。
  DrawingStyle copyWith({Color? color, double? strokeWidth}) => DrawingStyle(
    color: color ?? this.color,
    strokeWidth: strokeWidth ?? this.strokeWidth,
  );
}

/// tool为当前工具；返回是否支持线宽，避免控件与绘制器分别推断能力。
bool supportsStrokeWidth(ScreenshotTool tool) => const {
  ScreenshotTool.rect,
  ScreenshotTool.arrow,
  ScreenshotTool.brush,
}.contains(tool);

/// tool为工具、mode为图形模式；返回是否支持颜色，马赛克不消耗颜色。
bool supportsDrawingColor(ScreenshotTool tool, ShapeMode mode) =>
    (tool == ScreenshotTool.brush && mode != ShapeMode.mosaic) ||
    tool == ScreenshotTool.rect ||
    tool == ScreenshotTool.arrow ||
    tool == ScreenshotTool.text;
