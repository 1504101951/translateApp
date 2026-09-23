import '../common/constants/glass_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../common/utils/geometry.dart';

/// 截图预览与工具栏的位置；仅改变屏幕布局，不改变源图或导出裁剪坐标。
class ScreenshotEditorLayout {
  /// canvas 为图片显示矩形，toolbar 为工具栏矩形，axis 为按钮滚动方向。
  const ScreenshotEditorLayout({
    required this.canvas,
    required this.toolbar,
    required this.axis,
  });

  final Rect canvas;
  final Rect toolbar;
  final Axis axis;

  /// viewport 为窗口尺寸，image 为源图像素尺寸，crop 为已提交的源图选区；
  /// 返回完整位于窗口内的工具栏；优先选区外侧，空间不足时贴选区内缘。
  factory ScreenshotEditorLayout.place({
    required Size viewport,
    required Size image,
    required Rect crop,
    double toolbarLength = 640,
    bool propertyRow = false,
  }) {
    const margin = 8.0;
    const gap = 8.0;
    final thickness = propertyRow ? 84.0 : GlassMetrics.toolbarThickness;
    final canvas = Offset.zero & viewport;
    // 已提交选区决定布局，拖动预览不改变图片坐标系。
    final selection = mapRectToFitted(crop, image, canvas);
    final horizontalLength = math.min(
      toolbarLength.clamp(48.0, 640.0),
      viewport.width - margin * 2,
    );
    final verticalLength = math.min(
      toolbarLength.clamp(48.0, 640.0),
      viewport.height - margin * 2,
    );
    final left = selection.left.clamp(
      margin,
      viewport.width - margin - horizontalLength,
    );
    final top = selection.top.clamp(
      margin,
      viewport.height - margin - verticalLength,
    );

    // 先用下/上方的横栏；纵向没有足够空间时使用右/左侧竖栏。
    if (selection.bottom + gap + thickness <= viewport.height - margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          left,
          selection.bottom + gap,
          horizontalLength,
          thickness,
        ),
        axis: Axis.horizontal,
      );
    }
    if (selection.top - gap - thickness >= margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          left,
          selection.top - gap - thickness,
          horizontalLength,
          thickness,
        ),
        axis: Axis.horizontal,
      );
    }
    if (!propertyRow &&
        selection.right + gap + thickness <= viewport.width - margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          selection.right + gap,
          top,
          thickness,
          verticalLength,
        ),
        axis: Axis.vertical,
      );
    }
    if (!propertyRow && selection.left - gap - thickness >= margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          selection.left - gap - thickness,
          top,
          thickness,
          verticalLength,
        ),
        axis: Axis.vertical,
      );
    }

    // 没有外部空白时允许覆盖选区内缘；画布不为工具栏改变位置或显示比例。
    // 原生复制/保存只接收 EditDocument 导出，不会截入这层 UI。
    return ScreenshotEditorLayout(
      canvas: canvas,
      toolbar: Rect.fromLTWH(
        (selection.right - horizontalLength).clamp(
          margin,
          viewport.width - margin - horizontalLength,
        ),
        (selection.bottom - gap - thickness).clamp(
          margin,
          viewport.height - margin - thickness,
        ),
        horizontalLength,
        thickness,
      ),
      axis: Axis.horizontal,
    );
  }
}
