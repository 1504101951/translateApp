import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/capture_phase.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/utils/screenshot_filename.dart';
import '../common/widgets/native_glass.dart';
import '../common/widgets/toolbar_feedback.dart';

/// 采集工具的统一悬浮控制条、长图保留页及视频结果；选区准备由截图选择层负责。
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

/// 维护实际采集状态和一秒响应；GIF参数由已保存的截图设置决定。
class _CaptureAppState extends State<CaptureApp> {
  Map<String, dynamic> _state = {};
  bool _pending = false;
  String? _feedback;
  bool _feedbackIsError = false;
  Timer? _feedbackTimer;

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

  /// 无参数；解除平台订阅并取消本窗口反馈计时。
  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    _feedbackTimer?.cancel();
    super.dispose();
  }

  /// state为完整快照；仅新的保存结果或错误触发反馈，重复进度回包不延长文字寿命。
  void _apply(Map<String, dynamic> state) {
    if (!mounted) return;
    final previous = _state;
    setState(() => _state = state);
    if (state['id'] != previous['id']) {
      _feedbackTimer?.cancel();
      _feedback = null;
    }
    if (state['error'] != null && state['error'] != previous['error']) {
      _showFeedback(state['error'] as String, isError: true);
    } else if (state['gifPath'] != null &&
        state['gifPath'] != previous['gifPath']) {
      _showFeedback('已保存 GIF');
    } else if (state['savedPath'] != null &&
        state['savedPath'] != previous['savedPath']) {
      final path = state['savedPath'] as String;
      _showFeedback(path.toLowerCase().endsWith('.png') ? '已保存截图' : '已保存 MP4');
    } else if (state['warning'] != null &&
        state['warning'] != previous['warning']) {
      _showFeedback(state['warning'] as String, isError: true);
    }
  }

  /// message为操作结果；显示1000ms，isError只影响前景语义色，不改变媒体状态。
  void _showFeedback(String message, {bool isError = false}) {
    _feedbackTimer?.cancel();
    setState(() {
      _feedback = message;
      _feedbackIsError = isError;
    });
    _feedbackTimer = Timer(GlassMetrics.feedbackDuration, () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  /// method/arguments 为已知采集命令及参数；返回完整快照，错误只显示在当前窗口。
  Future<void> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (!mounted) return;
    setState(() {
      _pending = true;
      _feedbackTimer?.cancel();
      _feedback = null;
    });
    try {
      final value = await widget.channel.invokeMapMethod<String, dynamic>(
        method,
        {if (_state['id'] != null) 'id': _state['id'], ...arguments},
      );
      if (value != null) _apply(value);
    } on PlatformException catch (error) {
      if (mounted) _showFeedback(error.message ?? error.code, isError: true);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  /// 无参数；立即放弃当前会话，原生停止后台任务并保留已经保存的文件。
  Future<void> _discard() => _invoke(MethodNames.cancelCapture);

  /// 无参数；复制会话中的完整源像素PNG，成功后显示一秒，失败沿用命令错误。
  Future<void> _copyImage() async {
    await _invoke(MethodNames.copyScreenshot);
    if (!mounted || _feedback != null) return;
    _showFeedback('已复制');
  }

  /// 无参数；两种采集共用四个独立材料气泡，状态只读，三操作沿用真实阶段约束。
  Widget _active() {
    final paused = _phase == CapturePhase.paused;
    final scrolling = _state['kind'] == 'scrolling';
    final seconds = ((_state['elapsed'] as num?)?.toDouble() ?? 0).floor();
    final elapsed =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final progress = scrolling
        ? '长截图：${_state['height'] ?? 0} 像素'
        : '录制：$elapsed';
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
    final status = label;

    /// description为上方提示，child为状态或操作；返回不共享外壳的32pt玻璃气泡。
    Widget bubble(String description, Widget child) => Tooltip(
      message: description,
      preferBelow: false,
      verticalOffset: GlassMetrics.hitSize / 2 + GlassMetrics.toastGap,
      constraints: const BoxConstraints(minHeight: GlassMetrics.buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: NativeGlassSurface(
        material: true,
        radius: GlassMetrics.controlRadius,
        child: child,
      ),
    );

    /// description为提示与可访问名，icon为操作图标，action为空时禁用；返回明确命中尺寸的按钮。
    Widget action(String description, IconData icon, VoidCallback? action) =>
        SizedBox.square(
          dimension: GlassMetrics.hitSize,
          child: bubble(
            description,
            IconButton(
              onPressed: action,
              padding: EdgeInsets.zero,
              icon: Icon(
                icon,
                size: GlassMetrics.icon,
                semanticLabel: description,
              ),
            ),
          ),
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: bubble(
            status,
            ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: GlassMetrics.buttonMinWidth,
                maxWidth: 196,
                minHeight: GlassMetrics.hitSize,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        action(
          paused ? '开始' : '暂停',
          paused ? Icons.play_arrow : Icons.pause,
          editable
              ? () => _invoke(MethodNames.setCapturePaused, {'paused': !paused})
              : null,
        ),
        const SizedBox(width: 4),
        action(
          '结束',
          Icons.stop,
          editable ? () => _invoke(MethodNames.stopCapture) : null,
        ),
        const SizedBox(width: 4),
        action('放弃', Icons.close, _pending ? null : _discard),
      ],
    );
  }

  /// 无参数；返回等比视频与固定右侧纵向工具栏，系统标题栏由原生窗口承载。
  Widget _videoResult() {
    final pixels = Size(
      (_state['width'] as num).toDouble(),
      (_state['height'] as num).toDouble(),
    );
    final logical = pixels / (_state['previewScale'] as num).toDouble();
    final converting = _phase == CapturePhase.converting;
    final enabled = !_pending && !converting;
    // 四个操作保持固定位置；转换时GIF按钮直接提供取消，不展开参数表单。
    final actions = <(String, IconData, VoidCallback?)>[
      (
        '播放视频',
        Icons.play_arrow,
        enabled ? () => _invoke(MethodNames.previewRecording) : null,
      ),
      (
        '保存 MP4',
        Icons.save_outlined,
        enabled ? () => _invoke(MethodNames.saveRecording) : null,
      ),
      (
        converting ? '取消转换' : '导出 GIF',
        converting ? Icons.cancel_outlined : Icons.gif_box_outlined,
        _pending
            ? null
            : () => _invoke(
                converting
                    ? MethodNames.cancelGIFExport
                    : MethodNames.exportRecordingGIF,
              ),
      ),
      ('关闭当前采集', Icons.close, _pending ? null : _discard),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = GlassMetrics.toolbarPadding;
        const gap = GlassMetrics.toastGap;
        // 右侧预留48pt工具栏、8pt间隔和左右各8pt外边距；与原生内容尺寸一致。
        const reservedWidth = GlassMetrics.toolbarThickness + gap + margin * 2;
        final toolbarHeight =
            actions.length * GlassMetrics.hitSize +
            (actions.length - 1) * GlassMetrics.captureResultActionGap +
            margin * 2;
        final scale = math.min(
          1.0,
          math.min(
            (constraints.maxWidth - reservedWidth) / logical.width,
            (constraints.maxHeight - margin * 2) / logical.height,
          ),
        );
        final size = logical * scale;
        final media = Rect.fromLTWH(
          margin + (constraints.maxWidth - reservedWidth - size.width) / 2,
          (constraints.maxHeight - size.height) / 2,
          size.width,
          size.height,
        );
        // 工具栏拥有独立的右侧列，窗口缩小时仍完整容纳，不覆盖视频。
        final toolbar = Rect.fromLTWH(
          constraints.maxWidth - margin - GlassMetrics.toolbarThickness,
          (constraints.maxHeight - toolbarHeight) / 2,
          GlassMetrics.toolbarThickness,
          toolbarHeight,
        );
        return Stack(
          children: [
            Positioned.fromRect(
              rect: media,
              child: Semantics(
                label:
                    '录制结果，${_state['duration']}秒，${pixels.width.toInt()}×${pixels.height.toInt()}像素',
                child: AppKitView(
                  key: ValueKey(_state['id']),
                  viewType: ChannelNames.captureVideoPreview,
                  creationParams: {'id': _state['id']},
                  creationParamsCodec: const StandardMessageCodec(),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: toolbar,
              child: Padding(
                padding: const EdgeInsets.all(margin),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0)
                        SizedBox(height: GlassMetrics.captureResultActionGap),
                      SizedBox.square(
                        dimension: GlassMetrics.hitSize,
                        child: NativeGlassSurface(
                          material: true,
                          radius: GlassMetrics.controlRadius,
                          child: IconButton(
                            tooltip: actions[i].$1,
                            padding: EdgeInsets.zero,
                            onPressed: actions[i].$3,
                            icon: Icon(actions[i].$2, size: GlassMetrics.icon),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_feedback != null || converting)
              ToolbarFeedback(
                toolbar: toolbar,
                message:
                    _feedback ??
                    '正在转换 ${(((_state['progress'] as num?)?.toDouble() ?? 0) * 100).round()}%',
                isError: _feedback != null && _feedbackIsError,
              ),
          ],
        );
      },
    );
  }

  /// child为视频或长图结果；Escape与系统关闭一样立即放弃，已经保存的文件保留。
  Widget _resultPage(Widget child) => Material(
    type: MaterialType.transparency,
    child: Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        if (!_pending) unawaited(_discard());
        return KeyEventResult.handled;
      },
      child: child,
    ),
  );

  /// 无参数；按源逻辑尺寸滚动长图，右侧只有保存、复制、放弃。
  Widget _imageResult() {
    final pixels = Size(
      (_state['width'] as num).toDouble(),
      (_state['height'] as num).toDouble(),
    );
    final logical = pixels / (_state['previewScale'] as num).toDouble();
    final bytes = _state['imageBytes'] as Uint8List;
    final enabled = !_pending;
    // 三个操作固定在右侧，不提供裁剪、贴图或编辑工具。
    final actions = <(String, IconData, VoidCallback?)>[
      (
        '保存',
        Icons.save_outlined,
        enabled
            ? () => _invoke(MethodNames.saveScreenshot, {
                'name': screenshotFilename(DateTime.now()),
              })
            : null,
      ),
      ('复制', Icons.copy_outlined, enabled ? () => _copyImage() : null),
      ('放弃', Icons.close, _pending ? null : _discard),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = GlassMetrics.toolbarPadding;
        const gap = GlassMetrics.toastGap;
        const reservedWidth = GlassMetrics.toolbarThickness + gap + margin * 2;
        final toolbarHeight =
            actions.length * GlassMetrics.hitSize +
            (actions.length - 1) * GlassMetrics.captureResultActionGap +
            margin * 2;
        final viewport = Rect.fromLTWH(
          margin,
          margin,
          math.max(0, constraints.maxWidth - reservedWidth),
          math.max(0, constraints.maxHeight - margin * 2),
        );
        final toolbar = Rect.fromLTWH(
          constraints.maxWidth - margin - GlassMetrics.toolbarThickness,
          (constraints.maxHeight - toolbarHeight) / 2,
          GlassMetrics.toolbarThickness,
          toolbarHeight,
        );
        return Stack(
          children: [
            Positioned.fromRect(
              rect: viewport,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  key: const Key('long-image-scroll'),
                  scrollDirection: Axis.vertical,
                  child: SizedBox(
                    width: math.max(viewport.width, logical.width),
                    height: math.max(viewport.height, logical.height),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Semantics(
                        label:
                            '长截图结果，${pixels.width.toInt()}×${pixels.height.toInt()}像素',
                        child: SizedBox(
                          key: const Key('long-image-preview'),
                          width: logical.width,
                          height: logical.height,
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.none,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: toolbar,
              child: Padding(
                padding: const EdgeInsets.all(margin),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0)
                        SizedBox(height: GlassMetrics.captureResultActionGap),
                      SizedBox.square(
                        dimension: GlassMetrics.hitSize,
                        child: NativeGlassSurface(
                          material: true,
                          radius: GlassMetrics.controlRadius,
                          child: IconButton(
                            tooltip: actions[i].$1,
                            padding: EdgeInsets.zero,
                            onPressed: actions[i].$3,
                            icon: Icon(actions[i].$2, size: GlassMetrics.icon),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_feedback != null)
              ToolbarFeedback(
                toolbar: toolbar,
                message: _feedback!,
                isError: _feedbackIsError,
              ),
          ],
        );
      },
    );
  }

  /// context 为窗口上下文；使用项目统一原生玻璃主题与窗口背景。
  @override
  Widget build(BuildContext context) =>
      NativeGlassApp(home: Builder(builder: _buildPage));

  /// context为内部主题；录制与长截图共用状态条，完成后分别展示视频或长图结果。
  Widget _buildPage(BuildContext context) {
    if ([CapturePhase.idle, CapturePhase.failed].contains(_phase)) {
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
      // 面板上部保留提示空间；仅四个气泡绘制材料，外围不绘制背景或阴影。
      return Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(GlassMetrics.toolbarPadding),
                  child: SizedBox(
                    height: GlassMetrics.hitSize,
                    child: _active(),
                  ),
                ),
              ),
              if (_feedback != null)
                ToolbarFeedback(
                  toolbar: Rect.fromLTWH(
                    GlassMetrics.toolbarPadding,
                    constraints.maxHeight -
                        GlassMetrics.toolbarPadding -
                        GlassMetrics.hitSize,
                    constraints.maxWidth - GlassMetrics.toolbarPadding * 2,
                    GlassMetrics.hitSize,
                  ),
                  message: _feedback!,
                  isError: _feedbackIsError,
                ),
            ],
          ),
        ),
      );
    }
    if (_phase == CapturePhase.imageReady) return _resultPage(_imageResult());
    return _resultPage(_videoResult());
  }
}
