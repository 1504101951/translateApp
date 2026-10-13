import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';

/// 实时翻译结果窗口。只渲染主引擎快照，不保存会话或发起翻译。
class LiveRegionApp extends StatefulWidget {
  /// channel 为结果快照通道，测试可注入。
  const LiveRegionApp({super.key, this.channel});

  final MethodChannel? channel;

  /// 无参数；返回只订阅快照的状态。
  @override
  State<LiveRegionApp> createState() => _LiveRegionAppState();
}

class _LiveRegionAppState extends State<LiveRegionApp> {
  Map<String, dynamic> _state = const {};

  /// 无参数；注册快照并读取当前结果，不创建翻译服务。
  @override
  void initState() {
    super.initState();
    final channel = widget.channel ?? const MethodChannel(ChannelNames.liveRegion);
    channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.liveRegionState && call.arguments is Map) {
        _show(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    unawaited(_load(channel));
  }

  /// channel 为结果通道。拉取已有快照，窗口尚未收到状态时保留准备说明。
  Future<void> _load(MethodChannel channel) async {
    try {
      final value = await channel.invokeMapMethod<String, dynamic>(
        MethodNames.getLiveRegionState,
      );
      if (value != null) _show(value);
    } on PlatformException {
      // 准备阶段还没有会话快照，保留窗口里的准备说明。
    }
  }

  /// state 为原文、译文和状态。连续更新只替换文字，不改变窗口几何。
  void _show(Map<String, dynamic> state) {
    if (!mounted) return;
    setState(() => _state = state);
  }

  /// 无参数；返回上下排列且各自滚动的原文和译文。
  @override
  Widget build(BuildContext context) {
    final source = _state['source'] as String? ?? '';
    final translation = _state['translation'] as String? ?? '';
    final status = _state['status'] as String? ?? '';
    final banner = _state['banner'] as String?;
    final preparing = _state.isEmpty;
    return NativeGlassApp(
      title: '实时翻译',
      home: Padding(
        padding: const EdgeInsets.all(GlassMetrics.panelPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (banner != null && banner.isNotEmpty)
              _status(banner, emphasize: true),
            if (status.isNotEmpty) _status(status, emphasize: false),
            if (preparing)
              Expanded(
                child: _status('拖动或缩放此窗口。选择目标后点击开始实时翻译。', emphasize: false),
              )
            else ...[
              Expanded(child: _pane('原文', source)),
              const SizedBox(height: 12),
              Expanded(child: _pane('译文', translation)),
            ],
          ],
        ),
      ),
    );
  }

  /// label 为区域名，text 为该区正文。返回独立滚动的阅读区，滚动不带动另一区。
  Widget _pane(String label, String text) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(GlassMetrics.toolbarPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: GlassMetrics.captionFont,
                height: GlassMetrics.captionLine / GlassMetrics.captionFont,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: GlassMetrics.labelGap),
            Expanded(
              child: SingleChildScrollView(
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
          ],
        ),
      ),
    );
  }

  /// text 为状态或准备说明，emphasize 为暂停快照和已结束。返回单行状态，不单独依赖颜色。
  Widget _status(String text, {required bool emphasize}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: GlassMetrics.toolbarPadding),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: GlassMetrics.captionFont,
          height: GlassMetrics.captionLine / GlassMetrics.captionFont,
          fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}
