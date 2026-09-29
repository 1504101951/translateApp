import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/capture_phase.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import 'gif_options.dart';

/// 采集工具的统一悬浮控制条及视频结果；选区准备由截图选择层负责。
class CaptureApp extends StatefulWidget {
  /// channel 为会话状态及显式采集命令通道；可注入以验证界面状态。
  const CaptureApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.capture),
  });

  final MethodChannel channel;

  /// 无参数；返回采集控制状态，不创建翻译监听或数据库。
  @override
  State<CaptureApp> createState() => _CaptureAppState();
}

/// 维护实际采集状态与按需展开的GIF草稿；会话ID隔离迟到回调。
class _CaptureAppState extends State<CaptureApp> {
  Map<String, dynamic> _state = {};
  bool _pending = false;
  bool _gifExpanded = false;
  String? _error;
  String? _videoDraftId;
  final _start = TextEditingController(text: '0');
  final _end = TextEditingController();
  int _fps = 10;
  final _width = TextEditingController();

  CapturePhase get _phase =>
      CapturePhase.parse(_state['phase'] as String? ?? 'idle');

  /// 无参数；订阅原生状态并请求当前会话，不枚举来源或打开准备页面。
  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.captureStateChanged &&
          call.arguments is Map) {
        _apply(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    unawaited(_initialize());
  }

  /// 无参数；加载当前资源快照，真实错误由当前界面呈现。
  Future<void> _initialize() async {
    await _invoke(MethodNames.getCaptureState);
  }

  /// 无参数；解除平台订阅并释放所有本窗口表单资源。
  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    for (final controller in [_start, _end, _width]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// state 为完整平台快照；同一录制的进度回调不得覆盖用户编辑中的 GIF 参数。
  void _apply(Map<String, dynamic> state) {
    if (!mounted) return;
    if (state['duration'] is num && state['id'] != _videoDraftId) {
      _videoDraftId = state['id'] as String;
      _start.text = '0';
      _gifExpanded = false;
      // 保留实际时长精度，避免四舍五入后的结束时间超过源视频。
      _end.text = (state['duration'] as num).toDouble().toString();
      _fps = 10;
      _width.text = state['width'].toString();
    }
    setState(() => _state = state);
  }

  /// method/arguments 为已知采集命令及参数；返回完整快照，错误只显示在当前窗口。
  Future<void> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (!mounted) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      final value = await widget.channel.invokeMapMethod<String, dynamic>(
        method,
        {if (_state['id'] != null) 'id': _state['id'], ...arguments},
      );
      if (value != null) _apply(value);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  /// 无参数；解析 GIF 草稿；非法文本用 NaN/0 交给统一业务校验。
  GifOptions get _gif => GifOptions(
    start: double.tryParse(_start.text) ?? double.nan,
    end: double.tryParse(_end.text) ?? double.nan,
    fps: _fps,
    width: int.tryParse(_width.text) ?? 0,
  );

  /// 无参数；提交明确丢弃，所有活动与结果状态均由原生二级弹窗确认。
  Future<void> _discard() => _invoke(MethodNames.cancelCapture);

  /// label 为按钮文本；action 为空时禁用，primary 表示主要动作。
  Widget _button(String label, VoidCallback? action, {bool primary = false}) =>
      NativeGlassSurface(
        material: true,
        child: primary
            ? FilledButton(onPressed: action, child: Text(label))
            : TextButton(onPressed: action, child: Text(label)),
      );

  /// label/controller 为数值字段；enabled控制鼠标和键盘编辑，输入后重算验证结果。
  Widget _field(
    String label,
    TextEditingController controller, {
    bool enabled = true,
  }) => NativeGlassField(
    label: label,
    child: TextField(
      enabled: enabled && !_pending,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}),
    ),
  );

  /// 无参数；两种采集共用三操作，暂停保留时长和进度，过渡阶段禁用重复命令。
  Widget _active() {
    final paused = _phase == CapturePhase.paused;
    final scrolling =
        _state['kind'] == 'scrolling' || _phase == CapturePhase.scrolling;
    final seconds = ((_state['elapsed'] as num?)?.toDouble() ?? 0).floor();
    final elapsed =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final progress = scrolling
        ? '长截图 ${_state['height'] ?? 0} 像素'
        : '录制 $elapsed';
    final label = switch (_phase) {
      CapturePhase.preparing => '正在准备采集…',
      CapturePhase.pausing => '正在暂停…',
      CapturePhase.finalizing => '正在完成采集…',
      _ => paused ? '已暂停 · $progress' : progress,
    };
    final editable =
        !_pending &&
        [
          CapturePhase.recording,
          CapturePhase.scrolling,
          CapturePhase.paused,
        ].contains(_phase);
    return Row(
      children: [
        Expanded(
          child: Text(
            _error ?? label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: paused ? '开始' : '暂停',
          onPressed: editable
              ? () => _invoke(MethodNames.setCapturePaused, {'paused': !paused})
              : null,
          icon: Icon(paused ? Icons.play_arrow : Icons.pause),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '结束',
          onPressed: editable ? () => _invoke(MethodNames.stopCapture) : null,
          icon: const Icon(Icons.stop),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '放弃',
          onPressed: _pending ? null : _discard,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }

  /// 无参数；展示已可解码的视频和 GIF 参数，编码进度不会修改源视频。
  Widget _videoResult() {
    final duration = (_state['duration'] as num).toDouble();
    final sourceWidth = (_state['width'] as num).toInt();
    final sourceHeight = (_state['height'] as num).toInt();
    final options = _gif;
    final error = options.validate(
      duration: duration,
      sourceWidth: sourceWidth,
    );
    final converting = _phase == CapturePhase.converting;
    final enabled = !_pending && !converting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: GlassMetrics.videoPreviewHeight,
          child: AppKitView(
            key: ValueKey(_state['id']),
            viewType: ChannelNames.captureVideoPreview,
            creationParams: {'id': _state['id']},
            creationParamsCodec: const StandardMessageCodec(),
          ),
        ),
        const SizedBox(height: GlassMetrics.actionGap),
        Text(
          '录制完成 · ${duration.toStringAsFixed(2)} 秒 · $sourceWidth × $sourceHeight',
        ),
        const SizedBox(height: GlassMetrics.actionGap),
        Wrap(
          spacing: GlassMetrics.actionGap,
          runSpacing: GlassMetrics.actionGap,
          children: [
            _button(
              '播放视频',
              enabled ? () => _invoke(MethodNames.previewRecording) : null,
            ),
            _button(
              '保存 MP4',
              enabled ? () => _invoke(MethodNames.saveRecording) : null,
              primary: true,
            ),
          ],
        ),
        const SizedBox(height: GlassMetrics.groupGap),
        _button(
          _gifExpanded ? '收起 GIF 选项' : '导出 GIF…',
          enabled ? () => setState(() => _gifExpanded = !_gifExpanded) : null,
        ),
        if (_gifExpanded || converting) ...[
          const SizedBox(height: GlassMetrics.actionGap),
          IgnorePointer(
            ignoring: !enabled,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _field('开始（秒）', _start, enabled: enabled)),
                    const SizedBox(width: GlassMetrics.actionGap),
                    Expanded(child: _field('结束（秒）', _end, enabled: enabled)),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: NativeGlassField(
                        label: '帧率（1–30）',
                        child: NativeGlassDropdown<int>(
                          label: 'GIF帧率',
                          value: _fps,
                          items: {
                            for (var fps = 1; fps <= 30; fps++) fps: '$fps fps',
                          },
                          onChanged: enabled
                              ? (value) => setState(() => _fps = value)
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: GlassMetrics.actionGap),
                    Expanded(child: _field('宽度（像素）', _width, enabled: enabled)),
                  ],
                ),
              ],
            ),
          ),
          if (error != null)
            Text(error)
          else
            Text(
              '${(options.end - options.start).toStringAsFixed(2)} 秒 · ${options.frameCount} 帧 · ${options.width} × ${(sourceHeight * options.width / sourceWidth).round()} 像素',
            ),
          const SizedBox(height: GlassMetrics.actionGap),
          Wrap(
            spacing: GlassMetrics.actionGap,
            runSpacing: GlassMetrics.actionGap,
            children: [
              _button(
                '预览片段',
                enabled && error == null
                    ? () =>
                          _invoke(MethodNames.previewRecording, options.toMap())
                    : null,
              ),
              _button(
                '导出 GIF',
                enabled && error == null
                    ? () => _invoke(
                        MethodNames.exportRecordingGIF,
                        options.toMap(),
                      )
                    : null,
                primary: true,
              ),
            ],
          ),
          if (converting) ...[
            const SizedBox(height: GlassMetrics.groupGap),
            LinearProgressIndicator(
              value: (_state['progress'] as num?)?.toDouble(),
            ),
            Text(
              '正在转换 ${(((_state['progress'] as num?)?.toDouble() ?? 0) * 100).round()}%',
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: _button(
                '取消转换',
                () => _invoke(MethodNames.cancelGIFExport),
              ),
            ),
          ],
        ],
        for (final key in ['savedPath', 'gifPath'])
          if (_state[key] != null)
            Padding(
              padding: const EdgeInsets.only(top: GlassMetrics.actionGap),
              child: SelectableText('已保存：${_state[key]}'),
            ),
        const SizedBox(height: GlassMetrics.groupGap),
        Align(
          alignment: Alignment.centerLeft,
          child: _button('放弃当前录制', enabled ? _discard : null),
        ),
      ],
    );
  }

  /// context 为窗口上下文；使用项目统一原生玻璃主题与窗口背景。
  @override
  Widget build(BuildContext context) =>
      NativeGlassApp(home: Builder(builder: _buildPage));

  /// context为内部主题；录制与长截图共用状态条，已完成视频展示结果窗口。
  Widget _buildPage(BuildContext context) {
    if ([
      CapturePhase.idle,
      CapturePhase.failed,
      CapturePhase.imageReady,
    ].contains(_phase)) {
      return const SizedBox.shrink();
    }
    if ([
      CapturePhase.preparing,
      CapturePhase.recording,
      CapturePhase.pausing,
      CapturePhase.paused,
      CapturePhase.scrolling,
      CapturePhase.finalizing,
    ].contains(_phase)) {
      return NativeGlassSurface(
        material: true,
        radius: GlassMetrics.menuRadius,
        child: Padding(
          padding: const EdgeInsets.all(GlassMetrics.toolbarPadding),
          child: _active(),
        ),
      );
    }
    return NativeGlassWindowPage(
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(GlassMetrics.pagePadding),
          child: ListView(
            children: [
              if (_error ?? _state['error'] case final String message)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: GlassMetrics.actionGap,
                  ),
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              _videoResult(),
            ],
          ),
        ),
      ),
    );
  }
}
