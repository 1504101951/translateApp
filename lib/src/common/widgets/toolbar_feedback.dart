import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../constants/glass_metrics.dart';
import 'native_glass.dart';

/// 工具栏外侧的文字反馈；调用者管理一秒寿命，此组件仅限制位置和尺寸。
class ToolbarFeedback extends StatelessWidget {
  /// toolbar为窗口内工具栏矩形，message为完整响应，isError决定语义错误色。
  const ToolbarFeedback({
    super.key,
    required this.toolbar,
    required this.message,
    this.isError = false,
  });

  final Rect toolbar;
  final String message;
  final bool isError;

  /// context为窗口主题；返回占据父Stack的定位层，气泡绝不进入工具栏矩形。
  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: CustomSingleChildLayout(
      delegate: _FeedbackLayout(toolbar),
      child: Semantics(
        liveRegion: true,
        child: NativeGlassSurface(
          key: const Key('toolbar-feedback-bubble'),
          radius: GlassMetrics.controlRadius,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              message,
              style: TextStyle(
                color: isError ? Theme.of(context).colorScheme.error : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 选择工具栏外侧空闲矩形；尺寸受该区域约束，不用覆盖工具栏的兜底坐标。
class _FeedbackLayout extends SingleChildLayoutDelegate {
  /// toolbar为逻辑点矩形；反馈优先上、下，再选择侧边。
  const _FeedbackLayout(this.toolbar);
  final Rect toolbar;

  /// size为窗口尺寸；返回一个与工具栏隔8pt的空闲矩形。
  Rect _space(Size size) {
    const gap = GlassMetrics.toastGap;
    final safe = Rect.fromLTWH(
      gap,
      gap,
      math.max(0, size.width - gap * 2),
      math.max(0, size.height - gap * 2),
    );
    final spaces = [
      Rect.fromLTRB(
        safe.left,
        safe.top,
        safe.right,
        math.max(safe.top, toolbar.top - gap),
      ),
      Rect.fromLTRB(
        safe.left,
        math.min(safe.bottom, toolbar.bottom + gap),
        safe.right,
        safe.bottom,
      ),
      Rect.fromLTRB(
        math.min(safe.right, toolbar.right + gap),
        safe.top,
        safe.right,
        safe.bottom,
      ),
      Rect.fromLTRB(
        safe.left,
        safe.top,
        math.max(safe.left, toolbar.left - gap),
        safe.bottom,
      ),
    ];
    // 常规窗口优先完整容纳一行；极窄结果窗仍限制在剩余空间，保留全部按钮命中区。
    for (final space in spaces) {
      if (space.width >= GlassMetrics.hitSize &&
          space.height >= GlassMetrics.buttonHeight) {
        return space;
      }
    }
    return spaces.reduce(
      (a, b) => a.width * a.height >= b.width * b.height ? a : b,
    );
  }

  /// constraints为窗口约束；返回不超过空闲区和240pt宽度的文字约束。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // _space先确定不会遮挡工具栏的区域，再允许长文字在该区域内滚动。
    final space = _space(constraints.biggest);
    return BoxConstraints.loose(Size(math.min(240, space.width), space.height));
  }

  /// size/childSize为窗口和实际气泡尺寸；返回完全位于选定空闲区内的坐标。
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // _space与测量阶段使用相同区域，避免测量后重新夹紧而覆盖工具栏。
    final space = _space(size);
    return Offset(
      (toolbar.center.dx - childSize.width / 2).clamp(
        space.left,
        space.right - childSize.width,
      ),
      space.bottom <= toolbar.top
          ? space.bottom - childSize.height
          : toolbar.top.clamp(space.top, space.bottom - childSize.height),
    );
  }

  /// oldDelegate为先前布局；工具栏变化时重新选择空闲区域。
  @override
  bool shouldRelayout(_FeedbackLayout oldDelegate) =>
      toolbar != oldDelegate.toolbar;
}
