import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/native_glass.dart';
import 'screenshot_history.dart';

/// 拼接截图前选择方向的弹窗；确定返回 true（纵向）或 false（横向），取消返回 null（#109）。
class StitchDialog extends StatefulWidget {
  /// count 为参与拼接的截图张数，用于标题。
  const StitchDialog({super.key, required this.count});

  final int count;

  /// 无参数；返回持有方向选择的状态。
  @override
  State<StitchDialog> createState() => _StitchDialogState();
}

/// 持有当前选择的拼接方向，默认纵向。
class _StitchDialogState extends State<StitchDialog> {
  bool _vertical = true;

  /// context 为弹窗上下文；返回方向分段与取消/拼接操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: Text('拼接 ${widget.count} 张截图'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NativeGlassSegments<bool>(
          value: _vertical,
          options: const {true: '纵向', false: '横向'},
          onChanged: (value) => setState(() => _vertical = value),
        ),
        const SizedBox(height: 12),
        Text(
          '按截图时间先后排列，不缩放；尺寸不同时居中，空白处透明。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: () => Navigator.pop(context, _vertical),
          child: const Text('拼接'),
        ),
      ),
    ],
  );
}

/// 拆分截图前选择段数的弹窗；确定返回段数，取消返回 null（#109）。
class SplitDialog extends StatefulWidget {
  /// height 为图片像素高度；段数为 2–10 且不超过该高度。
  const SplitDialog({super.key, required this.height});

  final int height;

  /// 无参数；返回持有段数选择的状态。
  @override
  State<SplitDialog> createState() => _SplitDialogState();
}

/// 持有当前选择的段数，默认 2 段。
class _SplitDialogState extends State<SplitDialog> {
  int _parts = 2;

  /// context 为弹窗上下文；返回段数下拉与取消/拆分操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: const Text('拆分截图'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NativeGlassDropdown<int>(
          label: '段数',
          value: _parts,
          items: {
            for (var parts = 2; parts <= math.min(10, widget.height); parts++)
              parts: '$parts 段',
          },
          onChanged: (value) => setState(() => _parts = value),
        ),
        Text('按高度等分，余数并入最后一段。', style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: () => Navigator.pop(context, _parts),
          child: const Text('拆分'),
        ),
      ),
    ],
  );
}

/// 并排比较两张截图的弹窗；两图左上角对齐到同一画布，可开关差异高亮（#109）。
class ScreenshotCompareDialog extends StatefulWidget {
  /// first/second 为较早与较晚的截图，mask 为原生生成的画布大小差异蒙版 PNG，
  /// different/total 为不同像素数与画布总像素数。
  const ScreenshotCompareDialog({
    super.key,
    required this.first,
    required this.second,
    required this.mask,
    required this.different,
    required this.total,
  });

  final ScreenshotRecord first;
  final ScreenshotRecord second;
  final Uint8List mask;
  final int different;
  final int total;

  /// 弹窗最大宽度（点），受窗口宽度限制。
  static const maxWidth = 960.0;

  /// 两图之间的间距（点）。
  static const gap = 12.0;

  /// 无参数；返回持有高亮开关的状态。
  @override
  State<ScreenshotCompareDialog> createState() =>
      _ScreenshotCompareDialogState();
}

/// 持有「高亮差异」开关，默认开启。
class _ScreenshotCompareDialogState extends State<ScreenshotCompareDialog> {
  bool _highlight = true;

  /// record 为一侧截图；返回按比例缩放到可用区域、左上角对齐到比较画布并可叠加差异蒙版的图片。
  Widget _side(ScreenshotRecord record) {
    final width = math.max(widget.first.width, widget.second.width);
    final height = math.max(widget.first.height, widget.second.height);
    return FittedBox(
      child: SizedBox(
        width: width.toDouble(),
        height: height.toDouble(),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: record.width.toDouble(),
              height: record.height.toDouble(),
              child: Image.file(File(record.path), fit: BoxFit.fill),
            ),
            if (_highlight)
              Positioned.fill(
                child: Image.memory(
                  widget.mask,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.none,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// context 为弹窗上下文；返回并排的两图、高亮开关、差异摘要与完成操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    maxWidth: ScreenshotCompareDialog.maxWidth,
    title: const Text('比较截图'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _side(widget.first)),
              const SizedBox(width: ScreenshotCompareDialog.gap),
              Expanded(child: _side(widget.second)),
            ],
          ),
        ),
        NativeGlassSwitchTile(
          title: '高亮差异',
          value: _highlight,
          onChanged: (value) => setState(() => _highlight = value),
        ),
        Text(
          widget.different == 0
              ? '两张截图像素完全一致'
              : '差异像素 ${widget.different} / 总像素 ${widget.total}'
                    '（${(widget.different / widget.total * 100).toStringAsFixed(2)}%）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ),
    ],
  );
}
