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

  /// viewport为窗口尺寸，image为源像素尺寸，crop为源图选区，rowCount为实际行数，available为显示器可用局部点坐标，imageRect为等比图片在视口中的矩形；
  /// 返回完整位于窗口内的工具栏；优先选区外侧，空间不足时贴选区内缘。
  factory ScreenshotEditorLayout.place({
    required Size viewport,
    required Size image,
    required Rect crop,
    double toolbarLength = 640,
    int rowCount = 1,
    Rect? available,
    Rect? imageRect,
  }) {
    const margin = 8.0;
    const gap = 8.0;
    // rowCount包含工具、属性、录制目标和应用行；每行32pt、间距4pt、两侧padding8pt。
    final thickness =
        GlassMetrics.toolbarPadding * 2 +
        rowCount * GlassMetrics.hitSize +
        (rowCount - 1) * 4;
    final viewportRect = Offset.zero & viewport;
    final canvas = imageRect ?? viewportRect;
    final safe = available?.intersect(viewportRect) ?? viewportRect;
    // 已提交选区决定布局，拖动预览不改变图片坐标系。
    final selection = mapRectToFitted(crop, image, canvas);
    final horizontalLength = math.min(
      toolbarLength.clamp(48.0, 640.0),
      safe.width - margin * 2,
    );
    final verticalLength = math.min(
      toolbarLength.clamp(48.0, 640.0),
      safe.height - margin * 2,
    );
    final left = selection.left.clamp(
      safe.left + margin,
      safe.right - margin - horizontalLength,
    );
    final top = selection.top.clamp(
      safe.top + margin,
      safe.bottom - margin - verticalLength,
    );

    // 先用下/上方的横栏；纵向没有足够空间时使用右/左侧竖栏。
    if (selection.bottom + gap + thickness <= safe.bottom - margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          left,
          (selection.bottom + gap).clamp(
            safe.top + margin,
            safe.bottom - margin - thickness,
          ),
          horizontalLength,
          thickness,
        ),
        axis: Axis.horizontal,
      );
    }
    if (selection.top - gap - thickness >= safe.top + margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          left,
          (selection.top - gap - thickness).clamp(
            safe.top + margin,
            safe.bottom - margin - thickness,
          ),
          horizontalLength,
          thickness,
        ),
        axis: Axis.horizontal,
      );
    }
    if (selection.right + gap + thickness <= safe.right - margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          (selection.right + gap).clamp(
            safe.left + margin,
            safe.right - margin - thickness,
          ),
          top,
          thickness,
          verticalLength,
        ),
        axis: Axis.vertical,
      );
    }
    if (selection.left - gap - thickness >= safe.left + margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          (selection.left - gap - thickness).clamp(
            safe.left + margin,
            safe.right - margin - thickness,
          ),
          top,
          thickness,
          verticalLength,
        ),
        axis: Axis.vertical,
      );
    }

    // 横向空间不足时使用屏幕内侧竖栏，仍保留每个按钮的命中尺寸。
    if (safe.height - margin * 2 < thickness) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        axis: Axis.vertical,
        toolbar: Rect.fromLTWH(
          safe.right - margin - thickness,
          top,
          thickness,
          verticalLength,
        ),
      );
    }
    // 没有外部空白时允许覆盖选区内缘；画布不为工具栏改变位置或显示比例。
    // 原生复制/保存只接收 EditDocument 导出，不会截入这层 UI。
    return ScreenshotEditorLayout(
      canvas: canvas,
      toolbar: Rect.fromLTWH(
        (selection.right - horizontalLength).clamp(
          safe.left + margin,
          safe.right - margin - horizontalLength,
        ),
        (selection.bottom - gap - thickness).clamp(
          safe.top + margin,
          safe.bottom - margin - thickness,
        ),
        horizontalLength,
        thickness,
      ),
      axis: Axis.horizontal,
    );
  }
}
