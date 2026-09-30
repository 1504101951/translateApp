import 'drawing_preferences.dart';
import '../common/constants/preference_keys.dart';

import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/utils/geometry.dart';
import '../common/utils/screenshot_filename.dart';
import '../common/widgets/native_glass.dart';
import '../common/widgets/native_resize_cursor.dart';
import 'edit_document.dart';
import 'drawing_style.dart';
import 'drawing_controls.dart';
import 'screenshot_editor_layout.dart';
import '../settings/screenshot_toolbar_preferences.dart';
import '../common/constants/screenshot_actions.dart';

/// handle 为控制点方向，plusWhenIdle控制空白十字；channel为截图引擎，返回系统或原生对角光标。
MouseCursor cursorForEditHandle(
  String? handle, {
  required bool plusWhenIdle,
  required MethodChannel channel,
}) {
  switch (handle) {
    case 'n':
    case 's':
      return SystemMouseCursors.resizeUpDown;
    case 'e':
    case 'w':
      return SystemMouseCursors.resizeLeftRight;
    case 'nw':
    case 'se':
      return NativeResizeCursor(
        NativeResizeCursor.northWestSouthEast,
        channel: channel,
      );
    case 'ne':
    case 'sw':
      return NativeResizeCursor(
        NativeResizeCursor.northEastSouthWest,
        channel: channel,
      );
    case 'move':
      return SystemMouseCursors.grab;
    default:
      return plusWhenIdle
          ? SystemMouseCursors.precise
          : SystemMouseCursors.basic;
  }
}

/// 独立截图编辑入口；channel 连接原生内存截图、剪贴板、保存与贴图。
class ScreenshotApp extends StatefulWidget {
  const ScreenshotApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.screenshot),
  });

  final MethodChannel channel;

  /// 无参数；创建编辑窗口状态。
  @override
  State<ScreenshotApp> createState() => _ScreenshotAppState();
}

/// 管理当前捕获的编辑草稿与异步反馈，过期捕获不能影响新截图。
class _ScreenshotAppState extends State<ScreenshotApp> {
  final EditDocument _document = EditDocument();
  final FocusNode _focusNode = FocusNode();
  // 录制目标属于当前截图草稿；应用异步查询按截图身份和目标隔离。
  bool _recordingExpanded = false;
  CaptureTarget _recordingTarget = CaptureTarget.region;
  Map<Object?, Object?>? _recordingApplication;
  List<Map<Object?, Object?>> _recordingApplications = [];
  bool _loadingApplications = false;
  int _applicationRequest = 0;
  final FocusNode _textFocus = FocusNode();
  final TextEditingController _textController = TextEditingController();
  final List<Offset> _strokePoints = [];

  Map<Object?, Object?> _capture = {};
  final GlobalKey _editorKey = GlobalKey();
  DrawingPreferences _drawing = DrawingPreferences();
  Future<void> _drawingSave = Future.value();
  DrawingStyle get _nextStyle => _drawing.styleFor(_styleTool);
  set _nextStyle(DrawingStyle value) =>
      _drawing = _drawing.copyWith(tool: _styleTool, style: value);
  Color get _fillColor => _drawing.styleFor(ScreenshotTool.rect).color;
  set _fillColor(Color value) => _drawing = _drawing.copyWith(
    tool: ScreenshotTool.rect,
    style: _drawing.styleFor(ScreenshotTool.rect).copyWith(color: value),
  );
  ShapeMode get _shapeMode => _drawing.brushMode;
  ShapeVariant get _styleShape => _styleSelection?.shape ?? _drawing.shape;
  String? _selectedShapeId;
  bool _shapeSelecting = false;
  bool _styleDialogOpen = false;
  ui.Image? _sourceImage;

  ScreenshotTool _tool = ScreenshotTool.crop;
  bool _busy = false;
  bool _failed = false;
  bool _textInputOpen = false;
  String? _message;

  /// 复制成功是短暂反馈；与需要保留的错误、保存状态分开管理。
  String? _copyFeedback;

  /// 连续复制先取消旧计时，保证新反馈保留完整一秒。
  Timer? _copyFeedbackTimer;
  String? _savedPath;
  List<_OcrOverlay> _ocrOverlays = [];
  // 双击位置只用于松开确认后的编辑/复制，第二次按下不能提前导出。
  Offset? _doubleTapPoint;
  Offset? _dragStart;
  Offset? _dragCurrent;
  // 拖拽预览不进历史；松手后才 add/setCrop，保证一次手势一条撤销。
  EditAnnotation? _previewAnnotation;

  /// 文字工具当前颜色。
  // 输入草稿与已选文字不写入工具默认值；只有编辑新文字的属性才更新偏好。
  Color _textColor = ScreenshotDefaults.strokeColor;
  double _fontSize = ScreenshotDefaults.fontSize;

  /// 已提交且当前选中的文字标注 id。
  String? _selectedTextId;

  /// 正在改内容的文字标注 id；新建时为 null。
  String? _editingTextId;

  /// 文本框拉伸时命中的控制点；空表示在画新框。
  String? _resizeHandle;

  /// 当前窗口 DPR；工具栏字号是点，标注里存图像素。
  double _pixelRatio = 1;

  /// 裁剪控制点拖动时的预览框。
  Rect? _previewCrop;

  /// 单击选中裁剪框后才允许拖；未选中保持默认窗口裁剪。
  ScreenshotToolbarPreferences _toolbar = ScreenshotToolbarPreferences();
  static const _toolIds = {
    ScreenshotActions.cursor: ScreenshotTool.cursor,
    ScreenshotActions.crop: ScreenshotTool.crop,
    ScreenshotActions.rect: ScreenshotTool.rect,
    ScreenshotActions.arrow: ScreenshotTool.arrow,
    ScreenshotActions.text: ScreenshotTool.text,
    ScreenshotActions.brush: ScreenshotTool.brush,
  };
  bool _cropSelected = false;

  /// 无参数；先监听再拉取快照，首张截图无需等待引擎启动通知，无返回值。
  @override
  void initState() {
    super.initState();
    _document.addListener(_onDocumentChanged);
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.screenshotToolbarChanged) {
        // 当前单一截图引擎是绘图属性的唯一编辑入口；旧保存回声不能回滚较新的本地输入。
        // 新截图从完整快照恢复参数；若未来允许并行截图引擎，需改为按字段带版本合并。
        // 工具配置独立更新，不替换正在编辑的图片、裁剪和标注草稿。
        final next = ScreenshotToolbarPreferences.fromMap(
          Map<Object?, Object?>.from(call.arguments as Map),
        );
        if (mounted) setState(() => _toolbar = next);
      } else if (call.method == MethodNames.screenshotChanged) {
        _replace(Map<Object?, Object?>.from(call.arguments as Map));
      } else if (call.method == MethodNames.screenshotToolbarAction) {
        final args = call.arguments as Map;
        // 原生语义动作只操作当前捕获；排队中的旧动作不能切走文字输入。
        if (_capture['id'] == null ||
            _capture['id'] != args['id'] ||
            _textInputOpen) {
          return;
        }
        _toolbarActions()[args['action']]?.call();
      } else if (call.method == MethodNames.confirmScreenshot) {
        final id = (call.arguments as Map)['id'];
        if (_capture['id'] == null || _capture['id'] != id) return;
        // 原生键路由与 Flutter 键盘共用确认语义，过期捕获不能触发导出。
        await _confirmScreenshot();
      } else if (call.method == MethodNames.escapePressed) {
        if (_recordingExpanded) {
          setState(() {
            _recordingExpanded = false;
            unawaited(_syncRecordingPreview());
          });
          return;
        }
        if (_styleDialogOpen) {
          Navigator.of(_editorKey.currentContext!).pop();
          return;
        }
        if (_textInputOpen) {
          _cancelText();
        } else {
          await _close();
        }
      } else if (call.method == MethodNames.undoPressed) {
        if (!_textInputOpen && _document.canUndo) _document.undo();
      } else if (call.method == MethodNames.redoPressed) {
        if (!_textInputOpen && _document.canRedo) _document.redo();
      }
    });
    _load();
    // 多行文本框默认把回车当换行；这里拦住未按 Shift 的回车，当作确认。
    _textFocus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey != LogicalKeyboardKey.enter &&
          event.logicalKey != LogicalKeyboardKey.numpadEnter) {
        return KeyEventResult.ignored;
      }
      final shift =
          HardwareKeyboard.instance.logicalKeysPressed.contains(
            LogicalKeyboardKey.shiftLeft,
          ) ||
          HardwareKeyboard.instance.logicalKeysPressed.contains(
            LogicalKeyboardKey.shiftRight,
          );
      if (shift) return KeyEventResult.ignored;
      // 输入法尚在组词时，Return 必须交给输入法完成候选确认。
      if (!_textController.value.composing.isCollapsed &&
          _textController.value.composing.isValid) {
        return KeyEventResult.ignored;
      }
      _commitText();
      return KeyEventResult.handled;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// 无参数；文档变更时刷新叠加层，无返回值。
  void _onDocumentChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// value 为原生截图快照；替换图片并清空上一张草稿，无返回值。
  void _replace(Map<Object?, Object?> value) {
    if (!mounted) return;
    _recordingExpanded = false;
    _recordingTarget = CaptureTarget.region;
    _recordingApplication = null;
    _recordingApplications = [];
    _loadingApplications = false;
    _applicationRequest++;
    if (_styleDialogOpen) {
      Navigator.of(_editorKey.currentContext!).pop();
    }
    _copyFeedbackTimer?.cancel();
    final bytes = value['bytes'] as Uint8List?;
    final width = (value['width'] as num?)?.toInt() ?? 0;
    final height = (value['height'] as num?)?.toInt() ?? 0;
    setState(() {
      _sourceImage?.dispose();
      _sourceImage = null;
      _capture = value;
      _toolbar = ScreenshotToolbarPreferences.fromMap(value);
      _drawing = DrawingPreferences.fromMap(
        value[PreferenceKeys.screenshotDrawing] as Map?,
      );
      _textColor = _drawing.styles[ScreenshotTool.text]!.color;
      _fontSize = _drawing.fontSize;
      _message = value['error'] as String?;
      _failed = _message != null;
      _savedPath = null;
      _copyFeedback = null;
      _busy = false;
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _setTextInput(false);
      _textController.clear();
      _strokePoints.clear();
      _ocrOverlays = [];
      _tool = ScreenshotTool.crop;
      _selectedTextId = null;
      _selectedShapeId = null;
      _shapeSelecting = false;
      _editingTextId = null;
      _resizeHandle = null;
      _cropSelected = false;
      _previewCrop = null;
      if (bytes != null && width > 0 && height > 0) {
        _document.loadCapture(bytes, width, height);
        _loadSourceImage(bytes, value['id']);
        final cropW = (value['cropWidth'] as num?)?.toDouble();
        final cropH = (value['cropHeight'] as num?)?.toDouble();
        if (cropW != null && cropH != null && cropW >= 1 && cropH >= 1) {
          _document.setCrop(
            Rect.fromLTWH(
              (value['cropX'] as num?)?.toDouble() ?? 0,
              (value['cropY'] as num?)?.toDouble() ?? 0,
              cropW,
              cropH,
            ),
          );
          // 当前窗口只提供初始范围预览；首次拖动应能重新框选，不能锁成移动选区。
        }
      } else {
        _document.clear();
      }
    });
  }

  /// bytes为原图PNG、id为捕获身份；异步解码只更新同一会话的马赛克预览。
  Future<void> _loadSourceImage(Uint8List bytes, Object? id) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted || _capture['id'] != id) {
      frame.image.dispose();
      return;
    }
    setState(() {
      _sourceImage?.dispose();
      _sourceImage = frame.image;
    });
  }

  /// 返回当前被选中的标注；文字与非文字分别保留各自交互状态。
  EditAnnotation? get _styleSelection => _document.annotations
      .where((a) => a.id == (_selectedShapeId ?? _selectedTextId))
      .firstOrNull;

  /// 当前样式目标工具；选中标注优先于下一次绘制工具。
  ScreenshotTool get _styleTool {
    final selected = _styleSelection;
    if (selected == null) return _tool;
    return switch (selected.kind) {
      AnnotationKind.rectangle => ScreenshotTool.rect,
      AnnotationKind.arrow => ScreenshotTool.arrow,
      AnnotationKind.stroke => ScreenshotTool.brush,
      AnnotationKind.text => ScreenshotTool.text,
      AnnotationKind.mask => ScreenshotTool.rect,
    };
  }

  /// point为原图坐标；按绘制逆序命中形状，线条使用投影距离避免整块空白被选中。
  EditAnnotation? _hitShape(Offset point) {
    final tolerance = 6 * _pixelRatio;
    for (final a in _document.annotations.reversed) {
      if (a.kind == AnnotationKind.text) continue;
      if (!a.bounds.inflate(tolerance + a.strokeWidth / 2).contains(point)) {
        continue;
      }
      if (a.kind == AnnotationKind.mask) return a;
      if (a.kind == AnnotationKind.rectangle) {
        if (a.shape.circular) {
          final distance = (point - a.bounds.center).distance;
          final radius = a.bounds.width / 2;
          if (a.shape.filled
              ? distance <= radius
              : (distance - radius).abs() <= tolerance + a.strokeWidth / 2) {
            return a;
          }
        } else if (a.shape.filled ||
            !a.bounds.deflate(tolerance + a.strokeWidth / 2).contains(point)) {
          return a;
        }
        continue;
      }
      final points = a.kind == AnnotationKind.stroke
          ? a.points
          : [a.start!, a.end!];
      for (var i = 1; i < points.length; i++) {
        final delta = points[i] - points[i - 1];
        final rel = point - points[i - 1];
        final t = delta.distanceSquared == 0
            ? 0.0
            : ((rel.dx * delta.dx + rel.dy * delta.dy) / delta.distanceSquared)
                  .clamp(0.0, 1.0);
        if ((point - (points[i - 1] + delta * t)).distance <=
            tolerance + a.strokeWidth / 2) {
          return a;
        }
      }
    }
    return null;
  }

  /// 弹出独立控件；返回前保持原生按键处于文字输入作用域，避免HEX数字触发工具。
  Future<void> _editDrawingStyle({required bool color}) async {
    final editingText = _textInputOpen;
    final selected = editingText ? _previewAnnotation : _styleSelection;
    final captureId = _capture['id'];
    final tool = _styleTool;
    final initialColor =
        selected?.color ??
        (tool == ScreenshotTool.rect && _styleShape.filled
            ? _fillColor
            : tool == ScreenshotTool.text
            ? _textColor
            : _nextStyle.color);
    final initialWidth = selected == null
        ? _nextStyle.strokeWidth
        : selected.strokeWidth / _pixelRatio;
    _styleDialogOpen = true;
    _setTextInput(true);
    final result = await showDialog<Object>(
      context: _editorKey.currentContext!,
      builder: (dialogContext) => Dialog(
        child: color
            ? ColorPicker(
                initial: initialColor,
                onApply: (value) => Navigator.pop(dialogContext, value),
                onCancel: () => Navigator.pop(dialogContext),
              )
            : StrokeWidthPicker(
                initial: initialWidth,
                onApply: (value) => Navigator.pop(dialogContext, value),
                onCancel: () => Navigator.pop(dialogContext),
              ),
      ),
    );
    _styleDialogOpen = false;
    if (!mounted || captureId != _capture['id']) return;
    _setTextInput(editingText);
    if (editingText) {
      _textFocus.requestFocus();
    } else {
      _focusNode.requestFocus();
    }
    if (result == null) return;
    setState(() {
      if (editingText && result is Color) {
        _textColor = result;
        _previewAnnotation = _previewAnnotation?.copyWith(color: result);
        if (_editingTextId == null) {
          _drawing = _drawing.copyWith(
            tool: ScreenshotTool.text,
            style: _drawing.styles[ScreenshotTool.text]!.copyWith(
              color: result,
            ),
          );
        }
      } else if (selected != null) {
        final current = _document.annotations
            .where((a) => a.id == selected.id)
            .firstOrNull;
        if (current == null) return;
        final style = current.style.copyWith(
          color: result is Color ? result : null,
          strokeWidth: result is double ? result * _pixelRatio : null,
        );
        if (style.color != current.color ||
            style.strokeWidth != current.strokeWidth) {
          _document.updateAnnotation(current.copyWith(style: style));
        }
      } else if (result is Color) {
        if (tool == ScreenshotTool.rect && _styleShape.filled) {
          _fillColor = result;
        } else {
          _nextStyle = _nextStyle.copyWith(color: result);
          if (tool == ScreenshotTool.text) _textColor = result;
        }
      } else if (result is double) {
        _nextStyle = _nextStyle.copyWith(strokeWidth: result);
      }
    });
    if ((selected == null || editingText) && _editingTextId == null) {
      _persistDrawing();
    }
  }

  /// 显示图形模式选择；返回值在同一捕获内更新选中形状或后续绘制模式。
  void _chooseShape(ShapeVariant value) {
    final selected = _styleSelection;
    if (selected?.kind == AnnotationKind.rectangle) {
      final bounds = value.circular
          ? _circleBounds(selected!.bounds)
          : selected!.bounds;
      _document.updateAnnotation(
        selected.copyWith(shape: value, bounds: bounds),
      );
    } else {
      setState(() => _drawing = _drawing.copyWith(shape: value));
      _persistDrawing();
    }
  }

  /// 模式作用于当前画笔对象或后续轨迹；确认时只产生一次编辑历史。
  void _chooseBrush(ShapeMode value) {
    final selected = _styleSelection;
    if (selected?.kind == AnnotationKind.stroke) {
      _document.updateAnnotation(selected!.copyWith(shapeMode: value));
    } else {
      setState(() => _drawing = _drawing.copyWith(brushMode: value));
      _persistDrawing();
    }
  }

  /// 原图外接矩形取短边为直径，保证圆形而不是椭圆。
  Rect _circleBounds(Rect bounds) => Rect.fromLTWH(
    bounds.left,
    bounds.top,
    math.min(bounds.width, bounds.height),
    math.min(bounds.width, bounds.height),
  );

  /// 捕获独立快照串行保存到主设置引擎；失败可见，不静默丢弃偏好。
  void _persistDrawing() {
    final snapshot = _drawing.toMap();
    _drawingSave = _drawingSave.then((_) async {
      try {
        await widget.channel.invokeMethod(
          MethodNames.saveDrawingPreferences,
          snapshot,
        );
      } on PlatformException catch (error) {
        if (mounted) {
          setState(() {
            _message = error.message;
            _failed = true;
          });
        }
      }
    });
  }

  /// 无参数；拉取内存截图，失败保留可见错误，无返回值。
  Future<void> _load() async {
    try {
      final snapshot =
          await widget.channel.invokeMapMethod(MethodNames.getScreenshot) ?? {};
      if (_capture.isEmpty) _replace(snapshot);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  /// 无参数；同步当前录制预览身份，原生仅负责其他显示器的穿透遮罩。
  Future<void> _syncRecordingPreview() async {
    final id = _capture['id'];
    try {
      await widget.channel.invokeMethod<void>(
        MethodNames.previewCaptureTarget,
        {
          'id': id,
          'kind': (_recordingExpanded ? _recordingTarget : CaptureTarget.region)
              .name,
          'applicationID': _recordingApplication?['applicationID'],
        },
      );
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() => _message = error.message);
      }
    }
  }

  /// 无参数；返回所选应用在冻结显示器上的源像素窗口矩形，null表示尚未选择应用。
  List<Rect>? get _recordingWindows {
    if (!_recordingExpanded ||
        _recordingTarget != CaptureTarget.application ||
        _recordingApplication == null) {
      return null;
    }
    final scale =
        (_capture['width'] as num) /
        ((_capture['displayWidth'] as num?) ?? (_capture['width'] as num));
    return ((_recordingApplication!['windows'] as List?) ?? []).map((item) {
      final rect = item as Map;
      return Rect.fromLTWH(
        ((rect['x'] as num) - ((_capture['captureDisplayX'] as num?) ?? 0)) *
            scale,
        ((rect['y'] as num) - ((_capture['captureDisplayY'] as num?) ?? 0)) *
            scale,
        (rect['width'] as num) * scale,
        (rect['height'] as num) * scale,
      );
    }).toList();
  }

  /// target为录制目标身份；切换时清空应用选择，应用列表迟到后不影响其他目标，无返回值。
  Future<void> _selectRecordingTarget(CaptureTarget target) async {
    final id = _capture['id'];
    final request = ++_applicationRequest;
    setState(() {
      _recordingTarget = target;
      _recordingApplication = null;
      _recordingApplications = [];
      _loadingApplications = target == CaptureTarget.application;
      _message = null;
    });
    await _syncRecordingPreview();
    if (target != CaptureTarget.application) return;
    try {
      final sources = await widget.channel.invokeListMethod<Object?>(
        MethodNames.captureSources,
        {'id': id},
      );
      if (!mounted ||
          _capture['id'] != id ||
          _recordingTarget != target ||
          request != _applicationRequest) {
        return;
      }
      setState(() {
        _recordingApplications = sources!
            .cast<Map>()
            .map(Map<Object?, Object?>.from)
            .toList();
        if (_recordingApplications.isEmpty) _message = '没有可录制的应用。';
      });
    } on PlatformException catch (error) {
      if (mounted &&
          _capture['id'] == id &&
          _recordingTarget == target &&
          request == _applicationRequest) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } finally {
      if (mounted &&
          _capture['id'] == id &&
          _recordingTarget == target &&
          request == _applicationRequest) {
        setState(() => _loadingApplications = false);
      }
    }
  }

  /// kind为region/display/application，scrolling指定长截图；提交当前源像素选区或应用身份，失败保留文档。
  Future<void> _prepareCapture(
    CaptureTarget kind, {
    bool scrolling = false,
  }) async {
    if (_busy || _capture['canCaptureMedia'] != true) return;
    final id = _capture['id'];
    setState(() => _busy = true);
    try {
      await widget.channel.invokeMethod<void>(MethodNames.prepareCapture, {
        'id': id,
        'kind': kind.name,
        'scrolling': scrolling,
        if (kind == CaptureTarget.application)
          'applicationID': _recordingApplication!['applicationID'],
        if (kind == CaptureTarget.region) ...{
          'x': _document.cropRect.left.floorToDouble(),
          'y': _document.cropRect.top.floorToDouble(),
          'width': _document.cropRect.width.floorToDouble(),
          'height': _document.cropRect.height.floorToDouble(),
        },
      });
      if (!mounted || _capture['id'] != id) return;
      // 成功启动由原生关闭冻结画布；失败时保留当前裁剪和标注草稿。
      setState(() {
        _message = null;
        _failed = false;
      });
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  /// message 为复制成功文案；显示一秒浮层，返回 void；连续成功重新计时。
  void _showCopyFeedback(String message) {
    _copyFeedbackTimer?.cancel();
    setState(() {
      _copyFeedback = message;
      _message = null;
      _failed = false;
    });
    _copyFeedbackTimer = Timer(GlassMetrics.copyFeedbackDuration, () {
      if (mounted) setState(() => _copyFeedback = null);
    });
  }

  /// 无参数；确认当前文字、开始选区采集或复制截图，返回该操作结束的 Future。
  Future<void> _confirmScreenshot() async {
    if (_styleDialogOpen) return;
    if (_busy) return;
    if (_recordingExpanded) {
      if (_recordingTarget == CaptureTarget.application &&
          _recordingApplication == null) {
        return;
      }
      // 与开始按钮共用校验后的采集入口，回车不能误复制截图。
      await _prepareCapture(_recordingTarget);
      return;
    }
    if (_textInputOpen) {
      _commitText();
      return;
    }
    // 只有导出事务确认复制成功才结束截图；失败保留当前编辑状态。
    await _export('copy', closeAfterCopy: true);
  }

  /// action 为 copy/save/pin；先在 Dart 合成 PNG，再把 bytes 交给原生，无返回值。
  Future<void> _export(String action, {bool closeAfterCopy = false}) async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    String? saved;
    try {
      final bytes = await _document.renderPng();
      if (!mounted || _capture['id'] != id) return;
      if (action == 'save') {
        saved = await widget.channel.invokeMethod<String>(
          MethodNames.saveScreenshot,
          {
            'id': id,
            'bytes': bytes,
            'name': screenshotFilename(
              DateTime.fromMillisecondsSinceEpoch(
                _capture['capturedAt'] as int,
              ),
            ),
          },
        );
        if (saved == null) return;
        if (!mounted || _capture['id'] != id) return;
        setState(() {
          _savedPath = saved;
          _message = '已保存截图';
        });
        return;
      }
      if (action == 'pin') {
        final origin = pinOriginAppKit(
          crop: _document.cropRect,
          display: Rect.fromLTWH(
            (_capture['displayX'] as num).toDouble(),
            (_capture['displayY'] as num).toDouble(),
            (_capture['displayWidth'] as num).toDouble(),
            (_capture['displayHeight'] as num).toDouble(),
          ),
          image: _document.imageSize,
        );
        final pinId = await widget.channel.invokeMethod<String>(
          MethodNames.pinScreenshot,
          {'id': id, 'bytes': bytes, 'x': origin.dx, 'y': origin.dy},
        );
        if (!mounted || _capture['id'] != id) return;
        if (pinId == null) {
          setState(() {
            _message = '贴图失败';
            _failed = true;
          });
          return;
        }
        // 贴图成功即结束编辑层，只留下独立置顶图。
        await widget.channel.invokeMethod<void>(MethodNames.closeScreenshot);
        return;
      }
      await widget.channel.invokeMethod<void>(MethodNames.copyScreenshot, {
        'id': id,
        'bytes': bytes,
      });
      if (!mounted || _capture['id'] != id) return;
      // 只在系统剪贴板写入成功后展示反馈；新的成功操作重新计时。
      _showCopyFeedback('已复制图片');
      if (closeAfterCopy) {
        await widget.channel.invokeMethod<void>(MethodNames.closeScreenshot);
      }
    } on PlatformException catch (error) {
      if (!mounted || _capture['id'] != id) return;
      _copyFeedbackTimer?.cancel();
      setState(() {
        _copyFeedback = null;
        _savedPath = saved ?? _savedPath;
        _message = error.message;
        _failed = true;
      });
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  /// method 为非导出系统操作；关闭/重截/授权不改剪贴板，无返回值。
  Future<void> _command(String method) async {
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      final value = await widget.channel.invokeMethod<Object?>(method);
      if (!mounted) return;
      if (method == MethodNames.requestScreenAccess && value is Map) {
        setState(() => _capture['screenAccess'] = value['screenAccess']);
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 无参数；识别当前合成图文字并复制，无字不改剪贴板。
  Future<void> _copyOcrText() async {
    // 识别和剪贴板回复均可跨越换图；两次等待都必须保留同一捕获身份。
    final id = _capture['id'];
    final text = await _recognizeOcr();
    if (!mounted || _capture['id'] != id || text == null) return;
    if (text.trim().isEmpty) {
      setState(() {
        _message = '画面中没有可识别的文字';
        _failed = true;
      });
      return;
    }
    try {
      await widget.channel.invokeMethod<void>(MethodNames.copyText, {
        'text': text,
      });
      if (mounted && _capture['id'] == id) _showCopyFeedback('已复制文字');
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  /// 无参数；识别文字后把译文浮在原位置；由主引擎在完整成功时记录截图来源历史。
  Future<void> _translateOcr() async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      final bytes = await _document.renderPng();
      final raw = await widget.channel.invokeListMethod(
        MethodNames.recognizeBlocks,
        {'id': id, 'bytes': bytes},
      );
      final blocks = [
        for (final item in raw ?? const [])
          if (item is Map)
            _OcrOverlay(
              source: '${item['text'] ?? ''}',
              rect: Rect.fromLTWH(
                _document.cropRect.left +
                    ((item['x'] as num?)?.toDouble() ?? 0),
                _document.cropRect.top + ((item['y'] as num?)?.toDouble() ?? 0),
                (item['width'] as num?)?.toDouble() ?? 0,
                (item['height'] as num?)?.toDouble() ?? 0,
              ),
            ),
      ].where((item) => item.source.trim().isNotEmpty).toList();
      if (blocks.isEmpty) {
        if (mounted && _capture['id'] == id) {
          setState(() {
            _ocrOverlays = [];
            _message = '画面中没有可识别的文字';
            _failed = true;
          });
        }
        return;
      }
      // OCR 等待期间可能关闭或替换截图，旧结果不能开始翻译。
      if (!mounted || _capture['id'] != id) return;
      final joined = blocks.map((item) => item.source).join('\n');
      final translated = await widget.channel.invokeMethod<String>(
        MethodNames.translatePlainText,
        {'text': joined, 'id': id},
      );
      final lines = (translated ?? '').split('\n');
      final overlays = <_OcrOverlay>[
        for (var i = 0; i < blocks.length; i++)
          _OcrOverlay(
            source: blocks[i].source,
            translation: i < lines.length ? lines[i] : blocks[i].source,
            rect: blocks[i].rect,
          ),
      ];
      if (mounted && _capture['id'] == id) {
        setState(() {
          _ocrOverlays = overlays;
          _message = '已在图上显示译文';
        });
      }
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  /// 无参数；合成当前编辑图并请求设备 OCR，失败时返回 null。
  Future<String?> _recognizeOcr() async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return null;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      final bytes = await _document.renderPng();
      final text = await widget.channel.invokeMethod<String>(
        MethodNames.recognizeText,
        {'id': id, 'bytes': bytes},
      );
      return text ?? '';
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
      return null;
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  /// 无参数；Esc/关闭丢弃未导出草稿，不调用 copy，无返回值。
  Future<void> _close() => _command(MethodNames.closeScreenshot);

  /// imagePoint 为源图像素坐标；按当前工具开始拖拽或打开文本输入，无返回值。
  void _onDragStart(Offset imagePoint) {
    if (_tool == ScreenshotTool.cursor &&
        !_busy &&
        !_textInputOpen &&
        _hitText(imagePoint) == null) {
      final shape = _hitShape(imagePoint);
      if (shape != null) {
        setState(() {
          _selectedShapeId = shape.id;
          _selectedTextId = null;
          _cropSelected = false;
          _shapeSelecting = true;
        });
        return;
      }
    }
    _selectedShapeId = null;

    if (!_document.hasImage || _busy || _textInputOpen) return;
    if ((_tool == ScreenshotTool.text || _tool == ScreenshotTool.cursor) &&
        _startTextGesture(imagePoint)) {
      return;
    }
    if (_tool == ScreenshotTool.crop || _tool == ScreenshotTool.cursor) {
      // 光标先命中文字，再选择截图范围；裁剪工具未选中时仍可重新框选。
      if (_cropSelected || _tool == ScreenshotTool.cursor) {
        final handle = _handleAt(_document.cropRect, imagePoint);
        if (handle != null) {
          setState(() {
            _resizeHandle = handle;
            _dragStart = imagePoint;
            _dragCurrent = imagePoint;
            _previewCrop = _document.cropRect;
            _cropSelected = true;
            _selectedTextId = null;
          });
          return;
        }
      }
      if (_tool == ScreenshotTool.cursor) {
        setState(() => _cropSelected = false);
        return;
      }
      setState(() {
        _cropSelected = false;
        _resizeHandle = null;
        _dragStart = imagePoint;
        _dragCurrent = imagePoint;
        _previewCrop = Rect.fromPoints(imagePoint, imagePoint);
        _selectedTextId = null;
      });
      return;
    }
    setState(() {
      _selectedTextId = null;
      _previewCrop = null;
      _dragStart = imagePoint;
      _dragCurrent = imagePoint;
      _strokePoints
        ..clear()
        ..add(imagePoint);
      _previewAnnotation = _draftAnnotation(imagePoint, imagePoint);
    });
  }

  /// imagePoint 为拖拽中的源图像素坐标；只更新预览，不写历史，无返回值。
  void _onDragUpdate(Offset imagePoint) {
    if (_shapeSelecting) return;
    if (_dragStart == null || _textInputOpen) return;
    setState(() {
      _dragCurrent = imagePoint;
      if (_previewCrop != null) {
        if (_resizeHandle != null) {
          _previewCrop = _resizedRect(
            _document.cropRect,
            _resizeHandle!,
            imagePoint,
          );
        } else if (_dragStart != null) {
          _previewCrop = Rect.fromPoints(_dragStart!, imagePoint);
        }
        return;
      }
      if (_resizeHandle != null && _selectedTextId != null) {
        final current = _document.annotations
            .where((item) => item.id == _selectedTextId)
            .firstOrNull;
        if (current != null) {
          _previewAnnotation = current.copyWith(
            bounds: _resizedRect(current.bounds, _resizeHandle!, imagePoint),
          );
        }
        return;
      }
      if (_tool == ScreenshotTool.brush) {
        _strokePoints.add(imagePoint);
      }
      _previewAnnotation = _draftAnnotation(_dragStart!, imagePoint);
    });
  }

  /// 无参数；结束拖拽并提交裁剪/标注，无返回值。
  void _onDragEnd() {
    if (_shapeSelecting) {
      _shapeSelecting = false;
      return;
    }
    if (_dragStart == null) return;
    final start = _dragStart!;
    final end = _dragCurrent ?? start;
    final preview = _previewAnnotation;
    final handle = _resizeHandle;
    final selectedId = _selectedTextId;
    final cropPreview = _previewCrop;
    if (cropPreview != null) {
      Rect? next = handle != null ? cropPreview : null;
      if (next == null) {
        final rect = Rect.fromPoints(start, end);
        final minSide = 8 * _pixelRatio;
        if (rect.width >= minSide && rect.height >= minSide) {
          next = rect;
        }
      }
      setState(() {
        _dragStart = null;
        _dragCurrent = null;
        _previewAnnotation = null;
        _previewCrop = null;
        _resizeHandle = null;
        if (next != null) _cropSelected = true;
      });
      if (next != null) _document.setCrop(next);
      return;
    }
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _previewCrop = null;
      _resizeHandle = null;
    });
    if (handle != null && selectedId != null && preview != null) {
      final current = _document.annotations
          .where((item) => item.id == selectedId)
          .firstOrNull;
      if (current != null) {
        _document.updateAnnotation(current.copyWith(bounds: preview.bounds));
      }
      return;
    }
    if (_tool == ScreenshotTool.cursor) {
      return;
    }
    if (_tool == ScreenshotTool.text) {
      final rect = Rect.fromPoints(start, end);
      final box = (rect.width < 8 || rect.height < 8)
          ? Rect.fromLTWH(
              start.dx,
              start.dy,
              ScreenshotDefaults.textBox.width,
              ScreenshotDefaults.textBox.height,
            )
          : rect;
      _openTextInput(box.topLeft, bounds: box);
      return;
    }
    if (_tool == ScreenshotTool.brush) {
      if (_strokePoints.length >= 2) {
        _document.addAnnotation(
          EditAnnotation(
            id: '',
            kind: AnnotationKind.stroke,
            shapeMode: _shapeMode,
            style: _nextStyle.copyWith(
              strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
            ),
            bounds: boundsForPoints(_strokePoints),
            points: List<Offset>.from(_strokePoints),
          ),
        );
      }
      _strokePoints.clear();
      return;
    }
    if (preview == null) return;
    if (preview.kind != AnnotationKind.arrow &&
        (preview.bounds.width < 1 || preview.bounds.height < 1)) {
      return;
    }
    // 预览共用临时 id；提交时留空，由文档分配正式 id。
    _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: preview.kind,
        shapeMode: preview.shapeMode,
        shape: preview.shape,
        style: preview.style,
        bounds: preview.bounds,
        start: preview.start,
        end: preview.end,
        text: preview.text,
        color: preview.color,
        strokeWidth: preview.strokeWidth,
        fontSize: preview.fontSize,
      ),
    );
  }

  /// imagePoint 为按下位置；返回是否命中文字或开始新文字框，未命中光标操作交给截图区域。
  bool _startTextGesture(Offset imagePoint) {
    final selected = _document.annotations
        .where((item) => item.id == _selectedTextId)
        .firstOrNull;
    if (selected != null) {
      final handle = _handleAt(selected.bounds, imagePoint);
      if (handle != null && handle != 'move') {
        setState(() {
          _cropSelected = false;
          _resizeHandle = handle;
          _dragStart = imagePoint;
          _dragCurrent = imagePoint;
          _previewAnnotation = selected;
        });
        return true;
      }
    }
    final hit = _hitText(imagePoint);
    if (hit != null) {
      setState(() {
        _cropSelected = false;
        _selectedTextId = hit.id;
        _resizeHandle = _handleAt(hit.bounds, imagePoint) ?? 'move';
        _dragStart = imagePoint;
        _dragCurrent = imagePoint;
        _previewAnnotation = hit;
      });
      return true;
    }
    if (_tool == ScreenshotTool.cursor) {
      setState(() => _selectedTextId = null);
      return false;
    }
    setState(() {
      _selectedTextId = null;
      _cropSelected = false;
      _dragStart = imagePoint;
      _dragCurrent = imagePoint;
      _previewAnnotation = EditAnnotation(
        id: 'preview',
        kind: AnnotationKind.text,
        bounds: Rect.fromPoints(imagePoint, imagePoint),
        color: _textColor,
        fontSize: _toImageFont(_fontSize),
      );
    });
    return true;
  }

  /// annotation 为已提交文字；打开输入并选中该框。
  void _openExistingText(EditAnnotation annotation) {
    setState(() {
      _selectedTextId = annotation.id;
      _cropSelected = false;
      _editingTextId = annotation.id;
      _setTextInput(true);
      _textController.text = annotation.text;
      _textColor = annotation.color;
      _fontSize = _nearestVisualFont(_toVisualFont(annotation.fontSize));
      _dragStart = annotation.bounds.topLeft;
      _previewAnnotation = annotation;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  /// point 为源图像素；返回最上层命中的文字标注。
  EditAnnotation? _hitText(Offset point) {
    for (final annotation in _document.annotations.reversed) {
      if (annotation.kind == AnnotationKind.text &&
          annotation.bounds.inflate(4).contains(point)) {
        return annotation;
      }
    }
    return null;
  }

  /// bounds 为文本框或裁剪框，point 为源图像素；八角拉伸，框内移动。
  String? _handleAt(Rect bounds, Offset point) {
    return editHandleAt(
      bounds,
      point,
      GlassMetrics.cropHandleHitRadius * _pixelRatio,
      edgePad: GlassMetrics.cropEdgeHitRadius * _pixelRatio,
    );
  }

  /// bounds 为改前矩形，handle 为控制点，point 为当前指针；返回新矩形。
  Rect _resizedRect(Rect bounds, String handle, Offset point) {
    if (handle == 'move') {
      final next = bounds.shift(point - _dragStart!);
      final maxX = math.max(0, _document.width - next.width);
      final maxY = math.max(0, _document.height - next.height);
      return Rect.fromLTWH(
        next.left.clamp(0, maxX).toDouble(),
        next.top.clamp(0, maxY).toDouble(),
        next.width,
        next.height,
      );
    }
    var left = bounds.left;
    var top = bounds.top;
    var right = bounds.right;
    var bottom = bounds.bottom;
    switch (handle) {
      case 'n':
        top = point.dy;
      case 's':
        bottom = point.dy;
      case 'w':
        left = point.dx;
      case 'e':
        right = point.dx;
      case 'nw':
        left = point.dx;
        top = point.dy;
      case 'ne':
        right = point.dx;
        top = point.dy;
      case 'sw':
        left = point.dx;
        bottom = point.dy;
      case 'se':
        right = point.dx;
        bottom = point.dy;
    }
    return Rect.fromLTRB(
      left <= right - 8 ? left : right - 8,
      top <= bottom - 8 ? top : bottom - 8,
      right,
      bottom,
    );
  }

  /// start/end 为拖拽端点；返回对应工具的预览标注，裁剪/文字返回 null。
  EditAnnotation? _draftAnnotation(Offset start, Offset end) {
    final bounds = Rect.fromPoints(start, end);
    switch (_tool) {
      case ScreenshotTool.cursor:
      case ScreenshotTool.crop:
        return null;
      case ScreenshotTool.text:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.text,
          bounds: bounds,
          color: _textColor,
          fontSize: _toImageFont(_fontSize),
        );
      case ScreenshotTool.brush:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.stroke,
          shapeMode: _shapeMode,
          style: _nextStyle.copyWith(
            strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
          ),
          bounds: boundsForPoints(
            _strokePoints.isEmpty ? [start, end] : _strokePoints,
          ),
          points: List<Offset>.from(
            _strokePoints.isEmpty ? [start, end] : _strokePoints,
          ),
        );
      case ScreenshotTool.rect:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.rectangle,
          shape: _drawing.shape,
          style: _nextStyle.copyWith(
            color: _drawing.shape.filled ? _fillColor : _nextStyle.color,
            strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
          ),
          bounds: _drawing.shape.circular ? _circleBounds(bounds) : bounds,
        );
      case ScreenshotTool.arrow:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.arrow,
          style: _nextStyle.copyWith(
            strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
          ),
          bounds: bounds,
          start: start,
          end: end,
        );
    }
  }

  /// point 为点击位置；bounds 为文本框，缺省用默认尺寸。打开就地输入。
  void _openTextInput(Offset point, {Rect? bounds}) {
    _textColor = _drawing.styles[ScreenshotTool.text]!.color;
    _fontSize = _drawing.fontSize;
    final box = _clampedTextBox(point, bounds: bounds);
    setState(() {
      _setTextInput(true);
      _cropSelected = false;
      _selectedTextId = null;
      _selectedShapeId = null;
      _shapeSelecting = false;
      _editingTextId = null;
      _textController.text = '';
      _dragStart = box.topLeft;
      _previewAnnotation = EditAnnotation(
        id: 'preview',
        kind: AnnotationKind.text,
        bounds: box,
        color: _textColor,
        fontSize: _toImageFont(_fontSize),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  /// 无参数；提交文本标注并关闭输入框；再编辑时更新同一条。
  void _commitText() {
    if (!_textController.value.composing.isCollapsed &&
        _textController.value.composing.isValid) {
      return;
    }
    final preview = _previewAnnotation;
    final text = _textController.text.trim();
    final editingId = _editingTextId;
    setState(() {
      _setTextInput(false);
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _editingTextId = null;
    });
    if (text.isEmpty || preview == null) return;
    if (editingId != null) {
      final current = _document.annotations
          .where((item) => item.id == editingId)
          .firstOrNull;
      if (current == null) return;
      _document.updateAnnotation(
        current.copyWith(
          text: text,
          bounds: preview.bounds,
          color: _textColor,
          fontSize: _toImageFont(_fontSize),
        ),
      );
      setState(() => _selectedTextId = editingId);
      return;
    }
    final id = _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: preview.bounds,
        text: text,
        color: _textColor,
        fontSize: _toImageFont(_fontSize),
      ),
    );
    setState(() => _selectedTextId = id);
  }

  /// point 为落点，bounds 为拖出的框；裁到图内，避免测试小图上文本框跑出画布。
  Rect _clampedTextBox(Offset point, {Rect? bounds}) {
    final image = _document.imageSize;
    if (bounds != null) {
      final left = bounds.left.clamp(0, math.max(0, image.width - 8));
      final top = bounds.top.clamp(0, math.max(0, image.height - 8));
      final right = bounds.right.clamp(left + 8, image.width);
      final bottom = bounds.bottom.clamp(top + 8, image.height);
      return Rect.fromLTRB(
        left.toDouble(),
        top.toDouble(),
        right.toDouble(),
        bottom.toDouble(),
      );
    }
    final width = math.min(
      ScreenshotDefaults.textBox.width,
      math.max(24, image.width - point.dx),
    );
    final height = math.min(
      ScreenshotDefaults.textBox.height,
      math.max(20, image.height - point.dy),
    );
    return Rect.fromLTWH(
      point.dx.clamp(0, math.max(0, image.width - width)),
      point.dy.clamp(0, math.max(0, image.height - height)),
      width.toDouble(),
      height.toDouble(),
    );
  }

  /// imagePoint 为点击位置；点在裁剪框内选中，点外面取消选中。未选中时仍可拖出新框。
  void _onCropTap(Offset imagePoint) {
    final inside = _document.cropRect
        .inflate(4 * _pixelRatio)
        .contains(imagePoint);
    setState(() {
      _selectedTextId = null;
      _cropSelected = inside;
    });
  }

  /// imagePoint 为点击位置；点已有文字再编辑，点空白落默认文本框。
  void _onTextTap(Offset imagePoint) {
    if (!_document.hasImage || _busy || _textInputOpen) return;
    final hit = _hitText(imagePoint);
    if (_tool == ScreenshotTool.cursor && hit == null) {
      final shape = _hitShape(imagePoint);
      if (shape != null) {
        setState(() {
          _selectedShapeId = shape.id;
          _selectedTextId = null;
          _cropSelected = false;
        });
        return;
      }
    }
    _selectedShapeId = null;
    if (_tool == ScreenshotTool.cursor) {
      if (hit == null) {
        _onCropTap(imagePoint);
      } else {
        setState(() {
          _selectedTextId = hit.id;
          _cropSelected = false;
        });
      }
      return;
    }
    if (hit != null) {
      _openExistingText(hit);
      return;
    }
    _openTextInput(imagePoint);
  }

  /// active为文字编辑状态；原生按键路由必须让文本编辑/输入法优先处理组合键。
  void _setTextInput(bool active) {
    _textInputOpen = active;
    unawaited(
      widget.channel.invokeMethod<void>(MethodNames.screenshotTextInput, {
        'id': _capture['id'],
        'active': active,
      }),
    );
  }

  /// 无参数；取消文本输入，已提交的标注保持不变。
  void _cancelText() {
    setState(() {
      _setTextInput(false);
      _editingTextId = null;
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _textController.clear();
    });
  }

  /// 无参数；解除原生回调与文档监听，无返回值。
  @override
  void dispose() {
    _sourceImage?.dispose();
    _copyFeedbackTimer?.cancel();
    _document.removeListener(_onDocumentChanged);
    _document.dispose();
    _focusNode.dispose();
    _textFocus.dispose();
    _textController.dispose();
    widget.channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// context 为编辑窗口上下文；返回无边框暗色叠加编辑界面。
  @override
  Widget build(BuildContext context) {
    final renderedTool = _tool;
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final hasImage = _document.hasImage;
    return NativeGlassApp(
      home: Focus(
        key: _editorKey,
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_recordingExpanded) {
              setState(() {
                _recordingExpanded = false;
                unawaited(_syncRecordingPreview());
              });
              return KeyEventResult.handled;
            }
            if (_textInputOpen) {
              _cancelText();
            } else {
              _close();
            }
            return KeyEventResult.handled;
          }
          // 文字输入中把 ⌘Z 留给输入框；否则与工具栏共用标注历史。
          if (_textInputOpen) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            // 复用导出事务：复制成功才关闭，失败保留截图供重试。
            _confirmScreenshot();
            return KeyEventResult.handled;
          }
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          final meta =
              keys.contains(LogicalKeyboardKey.metaLeft) ||
              keys.contains(LogicalKeyboardKey.metaRight);
          if (meta && event.logicalKey == LogicalKeyboardKey.keyZ) {
            final shift =
                keys.contains(LogicalKeyboardKey.shiftLeft) ||
                keys.contains(LogicalKeyboardKey.shiftRight);
            if (shift) {
              if (_document.canRedo) _document.redo();
            } else {
              if (_document.canUndo) _document.undo();
            }
            return KeyEventResult.handled;
          }
          final chord = ToolbarShortcut.fromEvent(event);
          final action = _toolbar.shortcuts.entries
              .where((item) => item.value.matches(chord))
              .firstOrNull;
          if (action != null) {
            // 隐藏只影响按钮；动作自身仍检查忙碌、撤销历史等执行条件。
            _toolbarActions()[action.key]?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (hasImage)
                _EditorSurface(
                  key: ValueKey(_capture['id']),
                  imageScale: (_capture['imageScale'] as num?)?.toDouble(),
                  channel: widget.channel,
                  document: _document,
                  tool: _tool,
                  dragStart: _dragStart,
                  dragCurrent: _dragCurrent,
                  previewAnnotation: _previewAnnotation,
                  previewCrop:
                      _recordingExpanded &&
                          _recordingTarget != CaptureTarget.region
                      ? Offset.zero & _document.imageSize
                      : _previewCrop,
                  recordingWindows: _recordingWindows,
                  recordingPreview:
                      _recordingExpanded &&
                      _recordingTarget != CaptureTarget.region,
                  pixelRatio: _pixelRatio,
                  busy:
                      _busy ||
                      (_recordingExpanded &&
                          _recordingTarget != CaptureTarget.region),
                  textInputOpen: _textInputOpen && !_styleDialogOpen,
                  sourceImage: _sourceImage,
                  selectedShape: _selectedShapeId == null
                      ? null
                      : _styleSelection,
                  textController: _textController,
                  textFocus: _textFocus,
                  selectedText: _document.annotations
                      .where((item) => item.id == _selectedTextId)
                      .firstOrNull,
                  onDragStart: _onDragStart,
                  onDragUpdate: _onDragUpdate,
                  onDragEnd: _onDragEnd,
                  // 工具切换会释放旧手势的待处理单击；不得把它当成新工具的输入。
                  onTextTap: (point) {
                    if (_tool == renderedTool) _onTextTap(point);
                  },
                  onCropTap: _onCropTap,
                  cropSelected:
                      _cropSelected &&
                      !(_recordingExpanded &&
                          _recordingTarget != CaptureTarget.region),
                  activeHandle: _resizeHandle,
                  onDoubleTapDown: (point) => _doubleTapPoint = point,
                  onDoubleTap: () {
                    final point = _doubleTapPoint;
                    _doubleTapPoint = null;
                    if (point == null) return;
                    final hit = _tool == ScreenshotTool.cursor
                        ? _hitText(point)
                        : null;
                    if (hit != null) {
                      _openExistingText(hit);
                    } else {
                      _export('copy', closeAfterCopy: true);
                    }
                  },
                  onCommitText: _commitText,
                  toolbarBuilder: _buildToolbar,
                  toolbarSafeArea: _capture['toolbarSafeWidth'] == null
                      ? null
                      : Rect.fromLTWH(
                          (_capture['toolbarSafeX'] as num).toDouble(),
                          (_capture['toolbarSafeY'] as num).toDouble(),
                          (_capture['toolbarSafeWidth'] as num).toDouble(),
                          (_capture['toolbarSafeHeight'] as num).toDouble(),
                        ),
                  displaySize: _capture['displayWidth'] == null
                      ? null
                      : Size(
                          (_capture['displayWidth'] as num).toDouble(),
                          (_capture['displayHeight'] as num).toDouble(),
                        ),
                  secondaryItemCount: _toolbarActions().keys
                      .where(
                        (id) =>
                            id != ScreenshotActions.reveal &&
                            !ScreenshotActions.icons.containsKey(id),
                      )
                      .length,
                  toolbarItemCount:
                      _toolbarActions().keys
                          .where(
                            (id) =>
                                ScreenshotActions.icons.containsKey(id) &&
                                !_toolbar.hidden.contains(id),
                          )
                          .length +
                      (_busy ? 1 : 0),
                  recordingRows:
                      _recordingExpanded && _tool == ScreenshotTool.crop
                      ? (_recordingTarget == CaptureTarget.application ? 2 : 1)
                      : 0,
                  applicationCount: _recordingApplications.length,
                  toolbarHasMessage: _message != null,
                  copyFeedback: _copyFeedback,
                  ocrOverlays: _ocrOverlays,
                )
              else
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Material(
                      color: const Color(0xF0111111),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _message ??
                                  (_capture['screenAccess'] == false
                                      ? '截图需要屏幕录制权限'
                                      : '正在准备截图'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                            if (_capture['screenAccess'] == false) ...[
                              const SizedBox(height: 16),
                              NativeGlassSurface(
                                material: true,
                                child: FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _command(
                                          MethodNames.requestScreenAccess,
                                        ),
                                  child: const Text('申请屏幕录制权限'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!hasImage)
                Positioned(
                  right: 16,
                  top: 16,
                  child: NativeGlassSurface(
                    material: true,
                    child: IconButton(
                      key: const Key('screenshot-close'),
                      tooltip: '关闭',
                      onPressed: _busy ? null : _close,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// visual 为工具栏点大小；乘 DPR 得到源图像素字号。
  double _toImageFont(double visual) => visual * _pixelRatio;

  /// imageFont 为源图像素字号；除以 DPR 得到屏幕点大小。
  double _toVisualFont(double imageFont) => imageFont / _pixelRatio;

  /// visual 为换算后的点大小；落到最近的字号档。
  double _nearestVisualFont(double visual) {
    return ScreenshotDefaults.fontSizes.reduce(
      (a, b) => (a - visual).abs() < (b - visual).abs() ? a : b,
    );
  }

  /// 把当前颜色和字号写进选中或正在编辑的文本框。
  void _applyStyleToCurrent() {
    final imageFont = _toImageFont(_fontSize);
    if (_textInputOpen && _previewAnnotation != null) {
      _previewAnnotation = _previewAnnotation!.copyWith(
        color: _textColor,
        fontSize: imageFont,
      );
      return;
    }
    final id = _selectedTextId;
    if (id == null) return;
    final current = _document.annotations
        .where((item) => item.id == id)
        .firstOrNull;
    if (current == null || current.kind != AnnotationKind.text) return;
    _document.updateAnnotation(
      current.copyWith(color: _textColor, fontSize: imageFont),
    );
  }

  /// delta 为档位步进，-1 更小、+1 更大；字号只落在预设列表，并立刻作用到当前框。
  void _nudgeFontSize(int delta) {
    final selected = _textInputOpen ? _previewAnnotation : _styleSelection;
    if (selected?.kind == AnnotationKind.text) {
      _textColor = selected!.color;
      _fontSize = _nearestVisualFont(_toVisualFont(selected.fontSize));
    }
    final sizes = ScreenshotDefaults.fontSizes;
    final index = sizes.indexOf(_fontSize);
    final next = (index < 0 ? 1 : index) + delta;
    if (next < 0 || next >= sizes.length) return;
    setState(() {
      _fontSize = sizes[next];
      _applyStyleToCurrent();
    });
    if (_selectedTextId == null && _editingTextId == null) {
      _drawing = _drawing.copyWith(fontSize: _fontSize);
      _persistDrawing();
    }
  }

  /// 无参数；返回当前上下文可见动作及启用回调，鼠标与快捷键共用业务入口。
  Map<String, VoidCallback?> _toolbarActions() {
    final textControls =
        _tool == ScreenshotTool.text ||
        (_selectedTextId != null &&
            _document.annotations.any(
              (item) =>
                  item.id == _selectedTextId &&
                  item.kind == AnnotationKind.text,
            ));
    final styleTool = _styleTool;
    final brushMode = _styleSelection?.shapeMode ?? _shapeMode;
    final actions = <String, VoidCallback?>{
      if (_tool == ScreenshotTool.crop) ...{
        ScreenshotActions.record: _capture['canCaptureMedia'] == true
            ? () {
                setState(() => _recordingExpanded = !_recordingExpanded);
                unawaited(_syncRecordingPreview());
              }
            : null,
        ScreenshotActions.scrolling: _capture['canCaptureMedia'] == true
            ? () => _prepareCapture(CaptureTarget.region, scrolling: true)
            : null,
      },
      if (styleTool == ScreenshotTool.rect)
        for (final shape in ShapeVariant.values)
          '${ScreenshotActions.shapePrefix}${shape.name}': () =>
              _chooseShape(shape),
      if (styleTool == ScreenshotTool.brush)
        for (final mode in ShapeMode.values)
          '${ScreenshotActions.brushPrefix}${mode.name}': () =>
              _chooseBrush(mode),
      if (supportsDrawingColor(styleTool, brushMode))
        ScreenshotActions.palette: () => _editDrawingStyle(color: true),
      if (supportsStrokeWidth(styleTool) &&
          !(styleTool == ScreenshotTool.rect && _styleShape.filled))
        ScreenshotActions.width: () => _editDrawingStyle(color: false),
      for (final entry in _toolIds.entries)
        entry.key: () => setState(() {
          _tool = entry.value;
          _recordingExpanded = false;
          unawaited(_syncRecordingPreview());
          _recordingApplication = null;
          _selectedShapeId = null;
          _selectedTextId = null;
        }),
      ScreenshotActions.undo: _document.canUndo ? _document.undo : null,
      ScreenshotActions.redo: _document.canRedo ? _document.redo : null,
      ScreenshotActions.pin: _document.hasImage ? () => _export('pin') : null,
      ScreenshotActions.save: _document.hasImage ? () => _export('save') : null,
      ScreenshotActions.copy: _document.hasImage ? () => _export('copy') : null,
      ScreenshotActions.ocrCopy: _document.hasImage ? _copyOcrText : null,
      ScreenshotActions.ocrTranslate: _document.hasImage ? _translateOcr : null,
      ScreenshotActions.close: _close,
      if (textControls) ...{
        ScreenshotActions.sizeDown: () => _nudgeFontSize(-1),
        ScreenshotActions.sizeUp: () => _nudgeFontSize(1),
      },
      if (_savedPath != null)
        ScreenshotActions.reveal: () => widget.channel.invokeMethod<void>(
          MethodNames.revealFile,
          {'path': _savedPath},
        ),
    };
    return _busy ? actions.map((id, _) => MapEntry(id, null)) : actions;
  }

  /// axis为横/竖方向；按持久化顺序放置独立按钮，容器透明且可滚动。
  Widget _buildToolbar(BuildContext context, Axis axis) {
    final actions = _toolbarActions();
    final top = _toolbar.order
        .where((id) => !_toolbar.hidden.contains(id))
        .toList();
    final attributes = actions.keys
        .where(
          (id) =>
              id != ScreenshotActions.reveal &&
              !ScreenshotActions.icons.containsKey(id),
        )
        .toList();
    if (actions.containsKey(ScreenshotActions.reveal)) {
      top.add(ScreenshotActions.reveal);
    }
    final colors = Theme.of(context).colorScheme;
    final icons = <String, IconData>{
      ...ScreenshotActions.icons,
      ScreenshotActions.record: Icons.videocam_outlined,
      ScreenshotActions.scrolling: Icons.unfold_more,
      ScreenshotActions.palette: Icons.palette_outlined,
      ScreenshotActions.width: Icons.line_weight,
      ScreenshotActions.sizeDown: Icons.text_decrease,
      ScreenshotActions.sizeUp: Icons.text_increase,
      ScreenshotActions.reveal: Icons.folder_open,
      '${ScreenshotActions.shapePrefix}rectangle': Icons.crop_square,
      '${ScreenshotActions.shapePrefix}circle': Icons.circle_outlined,
      '${ScreenshotActions.shapePrefix}filledRectangle': Icons.square,
      '${ScreenshotActions.shapePrefix}filledCircle': Icons.circle,
      '${ScreenshotActions.brushPrefix}solid': Icons.brush,
      '${ScreenshotActions.brushPrefix}mosaic': Icons.grid_on,
    };
    // 模式按钮不产生hover层；普通操作保留主题反馈，属性不进入顶层排序。
    Widget button(String id) {
      final mode =
          id.startsWith(ScreenshotActions.shapePrefix) ||
          id.startsWith(ScreenshotActions.brushPrefix);
      final selected =
          _toolIds[id] == _tool ||
          id == '${ScreenshotActions.shapePrefix}${_styleShape.name}' ||
          id ==
              '${ScreenshotActions.brushPrefix}${(_styleSelection?.shapeMode ?? _shapeMode).name}';
      Widget child = SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          key: Key(id),
          tooltip:
              '${ScreenshotActions.labels[id]}${_toolbar.shortcuts[id] == null ? '' : ' ${_toolbar.shortcuts[id]!.label}'}',
          onPressed: actions[id],
          style: mode
              ? ButtonStyle(
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  backgroundColor: WidgetStatePropertyAll(
                    selected
                        ? NativeGlassTheme.selectionBlue
                        : Colors.transparent,
                  ),
                  foregroundColor: WidgetStatePropertyAll(
                    selected ? Colors.white : colors.onSurface,
                  ),
                  overlayColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.pressed)
                        ? (Theme.of(context).brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: .10)
                              : Colors.black.withValues(alpha: .08))
                        : Colors.transparent,
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                )
              : null,
          color: mode
              ? null
              : selected
              ? colors.primary
              : colors.onSurface,
          icon: Icon(icons[id] ?? Icons.circle, size: 16),
        ),
      );
      // 每个模式同样需要材料承载；外层工具栏保持透明。
      return NativeGlassSurface(material: true, child: child);
    }

    // 每组沿工具栏方向独立滚动；动态行数只改变工具栏占位，画布像素不参与布局。
    Widget row(List<String> ids, String key, {bool loading = false}) =>
        SingleChildScrollView(
          key: Key(key),
          scrollDirection: axis,
          child: Flex(
            direction: axis,
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              for (final id in ids) button(id),
              if (loading)
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: Icon(Icons.hourglass_top, size: 14),
                ),
            ],
          ),
        );

    /// label为提示与可访问名称，icon为图标，selected为选择状态；返回32pt独立材料按钮。
    Widget captureButton(
      String label,
      Widget icon,
      VoidCallback? action, {
      bool selected = false,
    }) => NativeGlassSurface(
      material: true,
      child: SizedBox(
        width: 32,
        height: 32,
        child: MergeSemantics(
          child: Semantics(
            label: label,
            selected: selected,
            child: IconButton(
              tooltip: label,
              onPressed: _busy ? null : action,
              icon: icon,
              style: IconButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: selected
                    ? NativeGlassTheme.selectionBlue
                    : Colors.transparent,
                foregroundColor: selected ? Colors.white : colors.onSurface,
              ),
            ),
          ),
        ),
      ),
    );

    /// key为行身份、children为按钮；返回沿当前工具栏方向可滚动的32pt操作行。
    Widget captureRow(String key, List<Widget> children) =>
        SingleChildScrollView(
          key: Key(key),
          scrollDirection: axis,
          child: Flex(
            direction: axis,
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: children,
          ),
        );
    final rows = <Widget>[
      row(top, 'screenshot-tools-row', loading: _busy),
      if (attributes.isNotEmpty) row(attributes, 'screenshot-attributes-row'),
      if (_recordingExpanded && _tool == ScreenshotTool.crop)
        captureRow('recording-targets-row', [
          for (final target in const {
            CaptureTarget.region: ('当前选区', Icons.crop),
            CaptureTarget.application: ('窗口', Icons.apps),
            CaptureTarget.display: ('全屏', Icons.desktop_mac),
          }.entries)
            captureButton(
              target.value.$1,
              Icon(target.value.$2, size: 16),
              () => _selectRecordingTarget(target.key),
              selected: _recordingTarget == target.key,
            ),
          captureButton(
            '开始录制',
            const Icon(Icons.fiber_manual_record, size: 16),
            _loadingApplications ||
                    (_recordingTarget == CaptureTarget.application &&
                        _recordingApplication == null)
                ? null
                : () => _prepareCapture(_recordingTarget),
          ),
          captureButton(
            '取消录制',
            const Icon(Icons.close, size: 16),
            () => setState(() {
              _recordingExpanded = false;
              unawaited(_syncRecordingPreview());
              _recordingApplication = null;
            }),
          ),
        ]),
      if (_recordingExpanded &&
          _tool == ScreenshotTool.crop &&
          _recordingTarget == CaptureTarget.application)
        captureRow('recording-applications-row', [
          if (_loadingApplications)
            const SizedBox(
              width: 32,
              height: 32,
              child: Icon(Icons.hourglass_top, size: 16),
            ),
          for (final app in _recordingApplications)
            captureButton(
              app['name'] as String,
              app['icon'] is Uint8List
                  ? Image.memory(
                      app['icon'] as Uint8List,
                      width: 16,
                      height: 16,
                    )
                  : const Icon(Icons.apps, semanticLabel: '应用图标不可用'),
              _loadingApplications
                  ? null
                  : () {
                      setState(() => _recordingApplication = app);
                      unawaited(_syncRecordingPreview());
                    },
              selected:
                  _recordingApplication?['applicationID'] ==
                  app['applicationID'],
            ),
        ]),
    ];
    final groups = Flex(
      direction: axis == Axis.horizontal ? Axis.vertical : Axis.horizontal,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        for (final row in rows)
          SizedBox(
            width: axis == Axis.vertical ? 32 : null,
            height: axis == Axis.horizontal ? 32 : null,
            child: row,
          ),
      ],
    );
    return SizedBox(
      key: const Key('screenshot-toolbar'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(
          builder: (context, constraints) => Flex(
            direction: axis,
            children: [
              Expanded(child: groups),
              if (_message != null)
                SizedBox(
                  width: axis == Axis.horizontal
                      ? constraints.maxWidth * .4
                      : null,
                  height: axis == Axis.vertical
                      ? constraints.maxHeight * .35
                      : null,
                  child: SingleChildScrollView(
                    child: Text(
                      _message!,
                      style: TextStyle(
                        color: _failed ? colors.error : colors.onSurface,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 源图、裁剪框、标注与工具栏的叠加绘制面。
class _EditorSurface extends StatefulWidget {
  const _EditorSurface({
    super.key,
    this.imageScale,
    required this.channel,
    required this.document,
    required this.tool,
    required this.dragStart,
    required this.dragCurrent,
    required this.previewAnnotation,
    this.previewCrop,
    this.recordingWindows,
    this.recordingPreview = false,
    required this.pixelRatio,
    required this.busy,
    required this.textInputOpen,
    required this.textController,
    required this.textFocus,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTextTap,
    required this.onCropTap,
    required this.cropSelected,
    required this.activeHandle,
    required this.onDoubleTap,
    required this.onDoubleTapDown,
    required this.onCommitText,
    required this.toolbarBuilder,
    this.toolbarSafeArea,
    this.displaySize,
    required this.toolbarItemCount,
    this.secondaryItemCount = 0,
    this.recordingRows = 0,
    this.applicationCount = 0,
    required this.toolbarHasMessage,
    required this.copyFeedback,
    required this.ocrOverlays,
    this.selectedText,
    this.sourceImage,
    this.selectedShape,
  });

  /// 长图来源像素倍率；为空表示整屏冻结画布，非空时保留选区逻辑宽度。
  final double? imageScale;
  final Rect? toolbarSafeArea;
  final Size? displaySize;
  final int toolbarItemCount;
  final int secondaryItemCount;
  final int recordingRows;
  final int applicationCount;
  final bool toolbarHasMessage;
  final MethodChannel channel;
  final EditDocument document;
  final ScreenshotTool tool;
  final Offset? dragStart;
  final Offset? dragCurrent;
  final EditAnnotation? previewAnnotation;
  final Rect? previewCrop;

  /// 应用预览窗口的源像素矩形；null表示使用普通区域遮罩。
  final List<Rect>? recordingWindows;
  final bool recordingPreview;
  final double pixelRatio;
  final bool busy;
  final bool textInputOpen;
  final TextEditingController textController;
  final FocusNode textFocus;
  final EditAnnotation? selectedText;
  final ui.Image? sourceImage;
  final EditAnnotation? selectedShape;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final ValueChanged<Offset> onTextTap;
  final ValueChanged<Offset> onCropTap;
  final bool cropSelected;
  final String? activeHandle;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onDoubleTapDown;
  final VoidCallback onCommitText;

  /// axis 由可用空白决定；返回具有相应滚动方向的工具栏。
  final Widget Function(BuildContext context, Axis axis) toolbarBuilder;
  final String? copyFeedback;
  final List<_OcrOverlay> ocrOverlays;

  /// 无参数；每张图片独立管理滚动位置，替换图片不会继承旧长图偏移。
  @override
  State<_EditorSurface> createState() => _EditorSurfaceState();
}

/// 长图滚动仅改变预览坐标，编辑与导出始终使用原图像素。
class _EditorSurfaceState extends State<_EditorSurface> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  /// 无参数；释放两轴预览滚动资源。
  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// context 为布局上下文；返回按图片像素映射手势的编辑画布。
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_vertical, _horizontal]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final imageSize = widget.document.imageSize;
          // 长图以采集倍率恢复原选区点宽；滚动只平移等比画布，不各自缩放横纵轴。
          final imageScale = widget.imageScale;
          final resultSize = imageScale == null ? null : imageSize / imageScale;
          final resultRect = resultSize == null
              ? null
              : Rect.fromLTWH(
                  math.max(0, (constraints.maxWidth - resultSize.width) / 2) -
                      (_horizontal.hasClients ? _horizontal.offset : 0),
                  -(_vertical.hasClients ? _vertical.offset : 0.0),
                  resultSize.width,
                  resultSize.height,
                );
          // 只按已提交选区定位；拖动过程中保持同一个图片坐标系。
          final maxItems = [
            widget.toolbarItemCount,
            widget.secondaryItemCount,
            if (widget.recordingRows > 0) 5,
            if (widget.recordingRows > 1) widget.applicationCount,
          ].reduce(math.max);
          final layout = ScreenshotEditorLayout.place(
            viewport: constraints.biggest,
            imageRect: resultRect,
            available:
                widget.toolbarSafeArea == null || widget.displaySize == null
                ? null
                : Rect.fromLTRB(
                    widget.toolbarSafeArea!.left *
                        constraints.maxWidth /
                        widget.displaySize!.width,
                    widget.toolbarSafeArea!.top *
                        constraints.maxHeight /
                        widget.displaySize!.height,
                    widget.toolbarSafeArea!.right *
                        constraints.maxWidth /
                        widget.displaySize!.width,
                    widget.toolbarSafeArea!.bottom *
                        constraints.maxHeight /
                        widget.displaySize!.height,
                  ),
            image: imageSize,
            crop: widget.document.cropRect,
            toolbarLength: 16 + maxItems * 32 + math.max(0, maxItems - 1) * 4,
            rowCount:
                1 +
                (widget.secondaryItemCount > 0 ? 1 : 0) +
                widget.recordingRows,
          );
          final fitted = layout.canvas;
          Rect cropDisplay = mapRectToFitted(
            widget.previewCrop ?? widget.document.cropRect,
            imageSize,
            fitted,
          );
          if (widget.previewCrop == null &&
              widget.tool == ScreenshotTool.crop &&
              widget.dragStart != null &&
              widget.dragCurrent != null) {
            cropDisplay = mapRectToFitted(
              Rect.fromPoints(widget.dragStart!, widget.dragCurrent!),
              imageSize,
              fitted,
            );
          }
          // local 相对已定位的图片子组件，不能再减 fitted 原点。
          Offset toImage(Offset local) {
            final x = (local.dx / fitted.width) * imageSize.width;
            final y = (local.dy / fitted.height) * imageSize.height;
            return Offset(
              x.clamp(0, imageSize.width),
              y.clamp(0, imageSize.height),
            );
          }

          final canvasContent = GestureDetector(
            key: const Key('screenshot-canvas'),
            // 裁剪起点就是按下点，不能被手势识别阈值移动。
            dragStartBehavior: DragStartBehavior.down,
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown:
                widget.textInputOpen ||
                    widget.busy ||
                    widget.tool == ScreenshotTool.text
                ? null
                : (details) =>
                      widget.onDoubleTapDown(toImage(details.localPosition)),
            onDoubleTap:
                widget.textInputOpen ||
                    widget.busy ||
                    widget.tool == ScreenshotTool.text
                ? null
                : widget.onDoubleTap,
            onPanStart: widget.busy || widget.textInputOpen
                ? null
                : (details) =>
                      widget.onDragStart(toImage(details.localPosition)),
            onPanUpdate: widget.busy || widget.textInputOpen
                ? null
                : (details) =>
                      widget.onDragUpdate(toImage(details.localPosition)),
            onPanEnd: widget.busy || widget.textInputOpen
                ? null
                : (_) => widget.onDragEnd(),
            onTapUp: !widget.textInputOpen && !widget.busy
                ? (details) {
                    final point = toImage(details.localPosition);
                    if (widget.tool == ScreenshotTool.crop) {
                      widget.onCropTap(point);
                    } else if (widget.tool == ScreenshotTool.text ||
                        widget.tool == ScreenshotTool.cursor) {
                      widget.onTextTap(point);
                    }
                  }
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  widget.document.sourcePng!,
                  fit: BoxFit.fill,
                  scale: MediaQuery.devicePixelRatioOf(context),
                  cacheWidth: widget.document.width,
                  cacheHeight: widget.document.height,
                  filterQuality: FilterQuality.none,
                  isAntiAlias: false,
                  gaplessPlayback: true,
                ),
                CustomPaint(
                  painter: _OverlayPainter(
                    sourceImage: widget.sourceImage,
                    selectedShape: widget.selectedShape,
                    annotations: widget.document.annotations,
                    previewAnnotation: widget.previewAnnotation,
                    imageSize: imageSize,
                  ),
                ),
                ...[
                  for (final overlay in widget.ocrOverlays)
                    Positioned.fromRect(
                      rect: mapRectToFitted(
                        overlay.rect,
                        imageSize,
                        Offset.zero & fitted.size,
                      ).intersect(Offset.zero & fitted.size),
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: const Color(0xCCFFFFFF),
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: Text(
                              overlay.translation.isEmpty
                                  ? overlay.source
                                  : overlay.translation,
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          );

          return _CornerCursor(
            cursorFor: (local) {
              if (widget.textInputOpen) return SystemMouseCursors.text;
              // 拖动过程中维持起始控制点方向，不因越过中线变成移动光标。
              if (widget.activeHandle != null) {
                return cursorForEditHandle(
                  widget.activeHandle,
                  plusWhenIdle: false,
                  channel: widget.channel,
                );
              }
              final point = toImage(local - fitted.topLeft);
              final pad = GlassMetrics.cropHandleHitRadius * widget.pixelRatio;
              // 光标与文字先检查选中文字的控制点，再检查最上层文字，避免穿透到截图。
              if (widget.tool == ScreenshotTool.cursor ||
                  widget.tool == ScreenshotTool.text) {
                final box =
                    (widget.previewAnnotation ?? widget.selectedText)?.bounds;
                final handle = box == null
                    ? null
                    : editHandleAt(
                        box,
                        point,
                        pad,
                        edgePad:
                            GlassMetrics.cropEdgeHitRadius * widget.pixelRatio,
                      );
                if (handle != null && handle != 'move') {
                  return cursorForEditHandle(
                    handle,
                    plusWhenIdle: false,
                    channel: widget.channel,
                  );
                }
                for (final annotation in widget.document.annotations.reversed) {
                  if (annotation.kind == AnnotationKind.text &&
                      annotation.bounds.inflate(4).contains(point)) {
                    return cursorForEditHandle(
                      editHandleAt(
                            annotation.bounds,
                            point,
                            pad,
                            edgePad:
                                GlassMetrics.cropEdgeHitRadius *
                                widget.pixelRatio,
                          ) ??
                          'move',
                      plusWhenIdle: false,
                      channel: widget.channel,
                    );
                  }
                }
                if (widget.tool == ScreenshotTool.text) {
                  return SystemMouseCursors.basic;
                }
              }
              if (widget.tool == ScreenshotTool.crop ||
                  widget.tool == ScreenshotTool.cursor) {
                if (widget.tool == ScreenshotTool.crop &&
                    !widget.cropSelected) {
                  return SystemMouseCursors.precise;
                }
                final handle = editHandleAt(
                  widget.previewCrop ?? widget.document.cropRect,
                  point,
                  pad,
                  edgePad: GlassMetrics.cropEdgeHitRadius * widget.pixelRatio,
                );
                if (handle != null) {
                  return cursorForEditHandle(
                    handle,
                    plusWhenIdle: false,
                    channel: widget.channel,
                  );
                }
                return widget.tool == ScreenshotTool.crop
                    ? SystemMouseCursors.precise
                    : SystemMouseCursors.basic;
              }
              return SystemMouseCursors.basic;
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (resultSize == null)
                  Positioned.fromRect(rect: fitted, child: canvasContent)
                else
                  Positioned.fill(
                    child: Scrollbar(
                      controller: _vertical,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _vertical,
                        child: SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: math.max(
                              constraints.maxWidth,
                              resultSize.width,
                            ),
                            height: math.max(
                              constraints.maxHeight,
                              resultSize.height,
                            ),
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: resultSize.width,
                                height: resultSize.height,
                                child: canvasContent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 选区外的暗角用独立层，避免吞掉画布手势。
                IgnorePointer(
                  child: CustomPaint(
                    size: constraints.biggest,
                    painter: _DimPainter(
                      recordingPreview: widget.recordingPreview,
                      cropDisplay: cropDisplay,
                      showHandles: widget.cropSelected,
                      windows: widget.recordingWindows
                          ?.map(
                            (rect) => mapRectToFitted(rect, imageSize, fitted),
                          )
                          .toList(),
                    ),
                  ),
                ),
                // 拖动时不让工具栏遮住正在变化的选区；松开后按新选区重新定位。
                if ((widget.dragStart == null || widget.textInputOpen) &&
                    (widget.toolbarItemCount > 0 ||
                        widget.secondaryItemCount > 0 ||
                        widget.toolbarHasMessage))
                  Positioned.fromRect(
                    rect: layout.toolbar,
                    child: widget.toolbarBuilder(context, layout.axis),
                  ),
                if (widget.copyFeedback != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomSingleChildLayout(
                        delegate: _CopyFeedbackLayout(layout.toolbar),
                        child: Semantics(
                          liveRegion: true,
                          child: NativeGlassSurface(
                            key: const Key('screenshot-copy-feedback'),
                            radius: GlassMetrics.controlRadius,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              // 成功状态由文字完整表达，短提示保持28pt轮廓，长提示自动换行。
                              child: Text(widget.copyFeedback!),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.textInputOpen)
                  Positioned.fromRect(
                    rect: mapRectToFitted(
                      (widget.previewAnnotation ?? widget.selectedText)
                              ?.bounds ??
                          Rect.fromLTWH(
                            widget.dragStart?.dx ?? 0,
                            widget.dragStart?.dy ?? 0,
                            ScreenshotDefaults.textBox.width,
                            ScreenshotDefaults.textBox.height,
                          ),
                      imageSize,
                      fitted,
                    ),
                    child: GestureDetector(
                      onDoubleTap: () {},
                      child: Material(
                        color: Colors.transparent,
                        child: NativeGlassSurface(
                          material: true,
                          child: TextField(
                            key: const Key('screenshot-text-field'),
                            controller: widget.textController,
                            focusNode: widget.textFocus,
                            autofocus: true,
                            maxLines: null,
                            textInputAction: TextInputAction.done,
                            style: TextStyle(
                              color:
                                  (widget.previewAnnotation ??
                                          widget.selectedText)
                                      ?.color ??
                                  ScreenshotDefaults.strokeColor,
                              fontSize:
                                  ((widget.previewAnnotation ??
                                              widget.selectedText)
                                          ?.fontSize ??
                                      ScreenshotDefaults.fontSize) *
                                  fitted.width /
                                  imageSize.width,
                            ),
                            cursorColor: ScreenshotDefaults.strokeColor,
                            decoration: const InputDecoration(
                              isDense: true,
                              filled: false,
                              hintText: '输入文字，回车确认',
                              hintStyle: TextStyle(color: Color(0x99FFFFFF)),
                              border: OutlineInputBorder(),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Color(0xFF5EEAD4),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Color(0xFF5EEAD4),
                                ),
                              ),
                            ),
                            onSubmitted: (_) => widget.onCommitText(),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.selectedText != null ||
                    (widget.previewAnnotation?.kind == AnnotationKind.text))
                  IgnorePointer(
                    child: CustomPaint(
                      size: constraints.biggest,
                      painter: _TextBoxPainter(
                        box: mapRectToFitted(
                          (widget.previewAnnotation ?? widget.selectedText)!
                              .bounds,
                          imageSize,
                          fitted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 复制提示的定位；优先工具栏上方，屏幕边缘不足时使用其他不遮工具栏的位置。
class _CopyFeedbackLayout extends SingleChildLayoutDelegate {
  /// toolbar 为当前工具栏的窗口坐标矩形。
  const _CopyFeedbackLayout(this.toolbar);
  final Rect toolbar;

  /// constraints 为窗口约束；返回提示最大尺寸，允许大字号文字换行。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.min(240, constraints.maxWidth - 16),
          constraints.maxHeight - 16,
        ),
      );

  /// size/childSize 为窗口与实际提示尺寸；返回始终留在窗口内的浮层坐标。
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 8.0;
    final x = (toolbar.center.dx - childSize.width / 2).clamp(
      gap,
      size.width - childSize.width - gap,
    );
    final above = toolbar.top - childSize.height - gap;
    if (above >= gap) return Offset(x, above);
    final below = toolbar.bottom + gap;
    if (below + childSize.height <= size.height - gap) return Offset(x, below);
    final right = toolbar.right + gap;
    final y = toolbar.top.clamp(gap, size.height - childSize.height - gap);
    if (right + childSize.width <= size.width - gap) return Offset(right, y);
    final left = toolbar.left - childSize.width - gap;
    if (left >= gap) return Offset(left, y);
    return Offset(x, above.clamp(gap, size.height - childSize.height - gap));
  }

  /// oldDelegate 为上一帧定位信息；工具栏移动时重新计算提示位置。
  @override
  bool shouldRelayout(_CopyFeedbackLayout oldDelegate) =>
      toolbar != oldDelegate.toolbar;
}

/// cursorFor 根据本地坐标返回四角拉伸光标；child 为画布手势层。
class _CornerCursor extends StatefulWidget {
  const _CornerCursor({required this.cursorFor, required this.child});

  final MouseCursor Function(Offset local) cursorFor;
  final Widget child;

  @override
  State<_CornerCursor> createState() => _CornerCursorState();
}

/// 维护当前鼠标光标；按子画布指针位置切换拉伸光标，离开时恢复默认。
class _CornerCursorState extends State<_CornerCursor> {
  MouseCursor _cursor = SystemMouseCursors.basic;
  Offset? _position;

  /// oldWidget 为先前画布状态；裁剪完成时鼠标可能静止，仍需刷新方向。
  @override
  void didUpdateWidget(covariant _CornerCursor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_position != null) _cursor = widget.cursorFor(_position!);
  }

  /// position 为画布局部位置；保存悬停位置并按当前裁剪状态更新系统光标。
  void _update(Offset position) {
    _position = position;
    final next = widget.cursorFor(position);
    if (next != _cursor) setState(() => _cursor = next);
  }

  /// context 为画布上下文；鼠标悬停与按住移动均使用同一命中规则。
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      cursor: _cursor,
      onEnter: (event) => _update(event.localPosition),
      onHover: (event) => _update(event.localPosition),
      onExit: (_) {
        _position = null;
        if (_cursor != SystemMouseCursors.basic) {
          setState(() => _cursor = SystemMouseCursors.basic);
        }
      },
      child: Listener(
        onPointerMove: (event) => _update(event.localPosition),
        child: widget.child,
      ),
    );
  }
}

/// box 为显示坐标下的文本框；画出可拉伸控制点。
class _TextBoxPainter extends CustomPainter {
  _TextBoxPainter({required this.box});

  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    _DimPainter(cropDisplay: box, showHandles: true).paintHandles(canvas);
  }

  @override
  bool shouldRepaint(covariant _TextBoxPainter oldDelegate) =>
      oldDelegate.box != box;
}

/// 选区外遮罩；只负责变暗，不参与命中。
class _DimPainter extends CustomPainter {
  _DimPainter({
    required this.cropDisplay,
    required this.showHandles,
    this.windows,
    this.recordingPreview = false,
  });

  final List<Rect>? windows;
  final bool recordingPreview;

  final Rect cropDisplay;
  final bool showHandles;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    var visible = Path()..addRect(cropDisplay);
    if (windows != null) {
      visible = Path();
      for (final rect in windows!) {
        visible = Path.combine(
          PathOperation.union,
          visible,
          Path()..addRect(rect),
        );
      }
    }
    final shade = Path.combine(PathOperation.difference, outer, visible);
    canvas.drawPath(shade, Paint()..color = const Color(0x99000000));
    if (windows != null) {
      final border = Paint()
        ..color = NativeGlassTheme.selectionBlue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (final rect in windows!) {
        canvas.drawRect(rect, border);
      }
    }
    paintHandles(canvas);
  }

  /// canvas为显示坐标画布；绘制边框及八个控制点，不绘制遮罩，文本框共用。
  void paintHandles(Canvas canvas) {
    final border = Paint()
      ..color = recordingPreview ? NativeGlassTheme.selectionBlue : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(cropDisplay, border);
    if (!showHandles) return;
    const handle = GlassMetrics.cropHandle;
    final fill = Paint()
      ..color = recordingPreview
          ? NativeGlassTheme.selectionBlue
          : Colors.white;
    for (final point in <Offset>[
      cropDisplay.topLeft,
      cropDisplay.topCenter,
      cropDisplay.topRight,
      cropDisplay.centerLeft,
      cropDisplay.centerRight,
      cropDisplay.bottomLeft,
      cropDisplay.bottomCenter,
      cropDisplay.bottomRight,
    ]) {
      canvas.drawCircle(point, handle / 2, fill);
      canvas.drawCircle(
        point,
        handle / 2,
        Paint()
          ..color = NativeGlassTheme.selectionBlue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DimPainter oldDelegate) =>
      oldDelegate.recordingPreview != recordingPreview ||
      oldDelegate.windows != windows ||
      oldDelegate.cropDisplay != cropDisplay ||
      oldDelegate.showHandles != showHandles;
}

/// 在源图坐标系绘制已提交标注与拖拽预览。
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.annotations,
    required this.previewAnnotation,
    required this.imageSize,
    this.sourceImage,
    this.selectedShape,
  });

  final List<EditAnnotation> annotations;
  final EditAnnotation? previewAnnotation;
  final Size imageSize;
  final ui.Image? sourceImage;
  final EditAnnotation? selectedShape;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;
    canvas.save();
    canvas.scale(scaleX, scaleY);
    final draggingId = previewAnnotation?.id;
    for (final annotation in annotations) {
      // 拖动中只画预览，避免文字留在原地、松手再瞬移。
      if (draggingId != null &&
          draggingId != 'preview' &&
          annotation.id == draggingId) {
        continue;
      }
      EditDocument.paintAnnotation(
        canvas,
        annotation,
        sourceImage: sourceImage,
      );
    }
    if (previewAnnotation != null) {
      EditDocument.paintAnnotation(
        canvas,
        previewAnnotation!,
        sourceImage: sourceImage,
      );
    }
    if (selectedShape != null) {
      canvas.drawRect(
        selectedShape!.bounds.inflate(2),
        Paint()
          ..color = const Color(0xFF007AFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / scaleX,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) {
    return oldDelegate.annotations != annotations ||
        oldDelegate.previewAnnotation != previewAnnotation ||
        oldDelegate.imageSize != imageSize;
  }
}

/// 一块 OCR 译文浮层；rect 为源图像素，translation 为空时显示原文。
class _OcrOverlay {
  const _OcrOverlay({
    required this.source,
    this.translation = '',
    required this.rect,
  });

  final String source;
  final String translation;
  final Rect rect;
}
