import 'drawing_preferences.dart';
import '../common/constants/preference_keys.dart';

import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../common/constants/channel_names.dart';
import '../common/constants/drawing_metrics.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/utils/geometry.dart';
import '../common/utils/screenshot_filename.dart';
import '../common/widgets/native_glass.dart';
import '../common/widgets/toolbar_feedback.dart';
import '../common/widgets/native_brush_cursor.dart';
import '../common/widgets/native_resize_cursor.dart';
import 'beautify.dart';
import 'edit_document.dart';
import 'drawing_style.dart';
import 'drawing_controls.dart';
import 'measure_layer.dart';
import 'recognized_text_panel.dart';
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

/// 工具栏下方可展开的设置行；录制与实时翻译为目标选择行，美化与比例为设置行（#103、#106）。
enum _ExpandedRow { recording, live, beautify, ratio }

/// 方向键对应的单位移动方向（#106）；LogicalKeyboardKey 重写了相等判断，不能作为常量映射的键。
final _arrowDirections = <LogicalKeyboardKey, Offset>{
  LogicalKeyboardKey.arrowLeft: Offset(-1, 0),
  LogicalKeyboardKey.arrowRight: Offset(1, 0),
  LogicalKeyboardKey.arrowUp: Offset(0, -1),
  LogicalKeyboardKey.arrowDown: Offset(0, 1),
};

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
  /// 工具栏下方展开的设置行，同一时刻最多一行；收起美化或比例行后已选值仍生效（#103、#106）。
  _ExpandedRow? _expandedRow;
  bool get _recordingExpanded => _expandedRow == _ExpandedRow.recording;
  bool get _liveExpanded => _expandedRow == _ExpandedRow.live;
  bool get _beautifyExpanded => _expandedRow == _ExpandedRow.beautify;

  /// 本次截图锁定的选区宽高比；null 为自由，新截图重置（#106）。
  double? _cropRatio;

  /// 本次截图的美化参数；null 表示不美化，新截图重置。
  BeautifyStyle? _beautify;
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
  /// 样式或上传确认弹窗打开中：Esc 关闭弹窗、回车不导出、新截图先关闭弹窗。
  bool _dialogOpen = false;
  ui.Image? _sourceImage;

  /// 标尺两端（截图像素）；不进入标注与撤销，切换工具或新截图后清除（#111）。
  ({Offset start, Offset end})? _ruler;

  /// 取色悬停点（截图像素），指针离开画布时为 null（#111）。
  Offset? _picker;

  /// 当前截图的非预乘 RGBA 源像素及其解码任务；每张截图首次取色时解码一次（#111）。
  ByteData? _sourcePixels;
  Future<void>? _pixelLoad;

  /// 确认截图（回车或双击）时的动作，来自截图快照与工具栏变更通知（#111）。
  ScreenshotConfirmAction _confirmAction = ScreenshotConfirmAction.copy;

  ScreenshotTool _tool = ScreenshotTool.crop;
  bool _busy = false;
  bool _failed = false;
  bool _textInputOpen = false;
  String? _feedbackMessage;
  Timer? _feedbackTimer;

  /// 无参数；返回当前一秒文字反馈，成功和失败共用同一状态。
  String? get _message => _feedbackMessage;

  /// value为响应文案；赋值方负责当前重建，计时结束仅移除文字，不修改保存路径或编辑状态。
  set _message(String? value) {
    _feedbackTimer?.cancel();
    _feedbackMessage = value;
    if (value == null) return;
    _feedbackTimer = Timer(GlassMetrics.feedbackDuration, () {
      if (mounted) setState(() => _feedbackMessage = null);
    });
  }

  String? _savedPath;
  List<_OcrOverlay> _ocrOverlays = [];

  /// “识别文字”得到的文字 Markdown 与二维码/条码；非空时显示结果弹窗（#108）。
  ({String text, List<RecognizedCode> codes})? _recognition;

  /// 结果弹窗相对窗口中心的拖动位移。
  Offset _recognizedOffset = Offset.zero;
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

  /// 文字工具下最近一次点中的文字框及时刻，用于识别双击进入编辑。
  String? _lastTextTapId;
  DateTime _lastTextTapAt = DateTime.fromMillisecondsSinceEpoch(0);

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
    ScreenshotActions.step: ScreenshotTool.step,
    ScreenshotActions.text: ScreenshotTool.text,
    ScreenshotActions.brush: ScreenshotTool.brush,
    ScreenshotActions.eyedropper: ScreenshotTool.eyedropper,
    ScreenshotActions.ruler: ScreenshotTool.ruler,
  };
  bool _cropSelected = false;

  /// 无参数；返回当前正在使用的可拼接功能：展开中的实时翻译或录制，否则是当前工具。
  String get _activeId => _liveExpanded
      ? ScreenshotActions.live
      : _recordingExpanded
      ? ScreenshotActions.record
      : _beautifyExpanded
      ? ScreenshotActions.beautify
      : _expandedRow == _ExpandedRow.ratio
      ? ScreenshotActions.ratio
      : _toolIds.entries.firstWhere((entry) => entry.value == _tool).key;

  /// 无参数；返回第二行应展示其子级的一级工具。
  /// 当前功能是子级时为它的父级；是一级工具时为它自己；是一级动作时没有子级可展示。
  String? get _group {
    final id = _activeId;
    return _toolbar.parentOf(id) ??
        (ScreenshotActions.composable[id]!.hostsChildren ? id : null);
  }

  /// 无参数；返回第二行里按配置顺序排列、未隐藏的子级功能。
  List<String> get _visibleChildren => [
    for (final id in _toolbar.children[_group] ?? const <String>[])
      if (!_toolbar.hidden.contains(id)) id,
  ];

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
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        final next = ScreenshotToolbarPreferences.fromMap(map);
        if (mounted) {
          setState(() {
            _toolbar = next;
            _confirmAction = ScreenshotConfirmAction.parse(
              map[PreferenceKeys.screenshotConfirmAction] as String?,
            );
          });
        }
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
        if (_expandedRow != null) {
          setState(() {
            _expandedRow = null;
            unawaited(_syncRecordingPreview());
            unawaited(_syncLivePreview());
          });
          return;
        }
        if (_dialogOpen) {
          Navigator.of(_editorKey.currentContext!).pop();
          return;
        }
        // 识别结果弹窗打开时，Esc 先关闭弹窗，不关闭截图。
        if (_recognition != null) {
          setState(() => _recognition = null);
          return;
        }
        if (_textInputOpen) {
          // Esc 结束输入并保留文字。
          _commitText();
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
    // 文字内容变化时让文字框高度跟随内容。
    _textController.addListener(_fitEditingText);
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
    _expandedRow = null;
    // 每次截图默认不美化、比例自由。
    _beautify = null;
    _cropRatio = null;
    unawaited(_syncLivePreview());
    _recordingTarget = CaptureTarget.region;
    _recordingApplication = null;
    _recordingApplications = [];
    _loadingApplications = false;
    _applicationRequest++;
    if (_dialogOpen) {
      Navigator.of(_editorKey.currentContext!).pop();
    }
    _feedbackTimer?.cancel();
    final bytes = value['bytes'] as Uint8List?;
    final width = (value['width'] as num?)?.toInt() ?? 0;
    final height = (value['height'] as num?)?.toInt() ?? 0;
    setState(() {
      _sourceImage?.dispose();
      _sourceImage = null;
      _sourcePixels = null;
      _pixelLoad = null;
      _ruler = null;
      _picker = null;
      _capture = value;
      _toolbar = ScreenshotToolbarPreferences.fromMap(value);
      _confirmAction = ScreenshotConfirmAction.parse(
        value[PreferenceKeys.screenshotConfirmAction] as String?,
      );
      _drawing = DrawingPreferences.fromMap(
        value[PreferenceKeys.screenshotDrawing] as Map?,
      );
      _textColor = _drawing.styles[ScreenshotTool.text]!.color;
      _fontSize = _drawing.fontSize;
      _message = value['error'] as String?;
      _failed = _message != null;
      _savedPath = null;
      _busy = false;
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _setTextInput(false);
      _textController.clear();
      _strokePoints.clear();
      _ocrOverlays = [];
      _recognition = null;
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
          // 前台窗口只提供初始范围预览，首次拖动重新框选；整屏与上次区域直接选中，可拖控制点调整（#105）。
          _cropSelected = value['cropSelected'] == true;
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
      AnnotationKind.step => ScreenshotTool.step,
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
      // 编号标记按圆形命中（#107）。
      if (a.kind == AnnotationKind.step) {
        if ((point - a.bounds.center).distance <=
            a.bounds.width / 2 + tolerance) {
          return a;
        }
        continue;
      }
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
    _dialogOpen = true;
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
    _dialogOpen = false;
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

  /// 无参数；展开时显示可调整的空结果窗，收起时关闭尚未开始的预览。
  Future<void> _syncLivePreview() async {
    final id = _capture['id'];
    try {
      await widget.channel.invokeMethod<void>(
        _liveExpanded
            ? MethodNames.previewLiveRegion
            : MethodNames.cancelLivePreview,
        {'id': id},
      );
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id && _liveExpanded) {
        setState(() => _message = error.message);
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
          'kind':
              (_recordingExpanded || _liveExpanded
                      ? _recordingTarget
                      : CaptureTarget.region)
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
    if ((!_recordingExpanded && !_liveExpanded) ||
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
    bool live = false,
  }) async {
    if (_busy || _capture['canCaptureMedia'] != true) return;
    final id = _capture['id'];
    setState(() => _busy = true);
    try {
      await widget.channel.invokeMethod<void>(MethodNames.prepareCapture, {
        'id': id,
        'kind': kind.name,
        'scrolling': scrolling,
        'live': live,
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

  /// message为复制成功文案；经统一反馈入口显示一秒，不改变编辑和保存状态。
  void _showCopyFeedback(String message) {
    setState(() {
      _message = message;
      _failed = false;
    });
  }

  /// 无参数；确认当前文字、开始选区采集或复制截图，返回该操作结束的 Future。
  Future<void> _confirmScreenshot() async {
    if (_dialogOpen) return;
    if (_busy) return;
    if (_recordingExpanded || _liveExpanded) {
      if (_recordingTarget == CaptureTarget.application &&
          _recordingApplication == null) {
        return;
      }
      // 与开始按钮共用校验后的采集入口，回车不能误复制截图。
      await _prepareCapture(_recordingTarget, live: _liveExpanded);
      return;
    }
    if (_textInputOpen) {
      _commitText();
      return;
    }
    // 确认动作由设置「回车或双击确认时」决定；只有导出事务成功才结束截图，失败保留当前编辑状态（#111）。
    switch (_confirmAction) {
      case ScreenshotConfirmAction.copy:
        await _export('copy', closeAfterCopy: true);
      case ScreenshotConfirmAction.copyAndSave:
        await _export('copySave', closeAfterCopy: true);
      case ScreenshotConfirmAction.upload:
        await _upload(closeAfter: true);
    }
  }

  /// action 为 copy/save/pin/copySave（先保存再复制）；先在 Dart 合成 PNG，再把 bytes 交给原生，无返回值。
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
      // 复制与保存输出美化图；贴图沿用原图，不在屏幕上钉出背景。
      final bytes = await _document.renderPng(
        beautify: action == 'pin' ? null : _beautify,
        unit: _pixelRatio,
      );
      if (!mounted || _capture['id'] != id) return;
      if (action == 'save' || action == 'copySave') {
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
        // 复制并保存在保存成功后继续走复制与关闭（#111）。
        if (action == 'save') {
          _afterExport(id, bytes);
          return;
        }
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
        // 先发出导出后的记录再结束编辑层；原生按到达顺序先核对截图身份，关闭后身份失效。
        _afterExport(id, bytes);
        // 贴图成功即结束编辑层，只留下独立置顶图。
        await widget.channel.invokeMethod<void>(MethodNames.closeScreenshot);
        return;
      }
      await widget.channel.invokeMethod<void>(MethodNames.copyScreenshot, {
        'id': id,
        'bytes': bytes,
      });
      if (!mounted || _capture['id'] != id) return;
      _afterExport(id, bytes);
      // 只在系统剪贴板写入成功后展示反馈；新的成功操作重新计时。
      _showCopyFeedback('已复制图片');
      if (closeAfterCopy) {
        await widget.channel.invokeMethod<void>(MethodNames.closeScreenshot);
      }
    } on PlatformException catch (error) {
      if (!mounted || _capture['id'] != id) return;
      _feedbackTimer?.cancel();
      setState(() {
        _savedPath = saved ?? _savedPath;
        _message = error.message;
        _failed = true;
      });
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  /// closeAfter 为成功后是否关闭截图（确认截图动作）；向主引擎查询上传目标，用户确认后上传导出图并复制分享链接，无返回值（#111）。
  /// 未配置目标时只提示去设置、不发送图像；取消确认或上传失败保留编辑。
  Future<void> _upload({bool closeAfter = false}) async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      // 主引擎按已提交设置返回「主机/存储桶」，未配置为 null。
      final target = await widget.channel.invokeMethod<String>(
        MethodNames.uploadTarget,
        {'id': id},
      );
      if (!mounted || _capture['id'] != id) return;
      if (target == null) {
        setState(() {
          _message = '未配置上传目标，请在「设置 → 截图 → 上传分享」中填写。';
          _failed = true;
        });
        return;
      }
      _dialogOpen = true;
      final confirmed = await showDialog<bool>(
        context: _editorKey.currentContext!,
        builder: (dialogContext) => NativeGlassDialog(
          title: const Text('上传截图'),
          content: Text('将上传到 $target，并复制分享链接。'),
          actions: [
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('上传'),
              ),
            ),
          ],
        ),
      );
      _dialogOpen = false;
      if (confirmed != true || !mounted || _capture['id'] != id) return;
      // 上传与复制使用同一张导出图（含美化）。
      final bytes = await _document.renderPng(
        beautify: _beautify,
        unit: _pixelRatio,
      );
      if (!mounted || _capture['id'] != id) return;
      final link = await widget.channel.invokeMethod<String>(
        MethodNames.uploadScreenshot,
        {'id': id, 'bytes': bytes},
      );
      if (!mounted || _capture['id'] != id) return;
      await widget.channel.invokeMethod<void>(MethodNames.copyText, {
        'text': link,
      });
      if (!mounted || _capture['id'] != id) return;
      _afterExport(id, bytes);
      _showCopyFeedback('已上传，链接已复制');
      if (closeAfter) {
        await widget.channel.invokeMethod<void>(MethodNames.closeScreenshot);
      }
    } on PlatformException catch (error) {
      if (!mounted || _capture['id'] != id) return;
      setState(() {
        _message = error.message;
        _failed = true;
      });
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  /// 无参数；返回解码当前源图非预乘 RGBA 的任务，同一张截图只解码一次；源图尚未解码完成时不缓存，下次取色重试（#111）。
  Future<void> _sourcePixelsReady() {
    final image = _sourceImage;
    if (image == null) return Future.value();
    return _pixelLoad ??= image
        .toByteData(format: ui.ImageByteFormat.rawStraightRgba)
        .then((data) {
          if (mounted && image == _sourceImage) {
            setState(() => _sourcePixels = data);
          }
        });
  }

  /// 无参数；返回取色悬停点的源像素颜色，像素尚未解码或指针不在画布上时返回 null（#111）。
  Color? get _pickedColor {
    final point = _picker;
    final pixels = _sourcePixels;
    if (point == null || pixels == null) return null;
    final x = point.dx.floor().clamp(0, _document.width - 1);
    final y = point.dy.floor().clamp(0, _document.height - 1);
    final offset = (y * _document.width + x) * 4;
    return Color.fromARGB(
      255,
      pixels.getUint8(offset),
      pixels.getUint8(offset + 1),
      pixels.getUint8(offset + 2),
    );
  }

  /// point 为悬停处的截图像素坐标，null 表示指针离开画布；更新取色悬停点并按需解码源像素，无返回值（#111）。
  void _hoverPicker(Offset? point) {
    if (point == _picker) return;
    setState(() => _picker = point);
    if (point != null) unawaited(_sourcePixelsReady());
  }

  /// point 为单击处的截图像素坐标；等待源像素就绪后复制该点的 `#RRGGBB` 并提示，无返回值（#111）。
  Future<void> _pickColor(Offset point) async {
    setState(() => _picker = point);
    await _sourcePixelsReady();
    final color = _pickedColor;
    if (!mounted || color == null) return;
    // colorHex 把源像素格式化为大写 #RRGGBB。
    final hex = colorHex(color);
    await widget.channel.invokeMethod<void>(MethodNames.copyText, {
      'text': hex,
    });
    if (mounted) _showCopyFeedback('已复制 $hex');
  }

  /// id 为本次截图身份，bytes 为刚导出成功的图片；记住本次选区（#105）并请求主引擎按「记录截图历史」开关写入（#29），无返回值。
  /// 两者都是导出成功后的附带记录：不等待回复，复制、保存、贴图的反馈与关闭不受其影响。
  void _afterExport(Object id, Uint8List bytes) {
    final crop = _document.cropRect;
    unawaited(
      widget.channel.invokeMethod<void>(MethodNames.rememberScreenshotRegion, {
        'id': id,
        'x': crop.left,
        'y': crop.top,
        'width': crop.width,
        'height': crop.height,
      }),
    );
    unawaited(
      widget.channel.invokeMethod<void>(MethodNames.recordScreenshotHistory, {
        'id': id,
        'bytes': bytes,
        'capturedAt': _capture['capturedAt'],
      }),
    );
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

  /// 无参数；识别截图中的文字与二维码/条码并打开结果弹窗，不写剪贴板；两者都没有时只提示（#108）。
  Future<void> _showRecognizedText() async {
    // 识别可跨越换图；等待结束后必须仍是同一捕获身份。
    final id = _capture['id'];
    // _recognizeOcr 返回识别文字与码，失败时为 null 并已显示错误。
    final recognition = await _recognizeOcr();
    if (!mounted || _capture['id'] != id || recognition == null) return;
    if (recognition.text.trim().isEmpty && recognition.codes.isEmpty) {
      setState(() {
        _message = '画面中没有可识别的文字、二维码或条码';
        _failed = true;
      });
      return;
    }
    setState(() {
      _recognition = recognition;
      _recognizedOffset = Offset.zero;
    });
  }

  /// text 为待复制内容，feedback 为成功提示；写入剪贴板后显示一秒提示，弹窗保持打开，无返回值。
  Future<void> _copyRecognized(String text, String feedback) async {
    final id = _capture['id'];
    try {
      await widget.channel.invokeMethod<void>(MethodNames.copyText, {
        'text': text,
      });
      if (mounted && _capture['id'] == id) _showCopyFeedback(feedback);
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  /// url 为码中的 http/https 链接；交给默认浏览器打开，成功后关闭截图编辑，失败时保留截图并提示，无返回值（#108）。
  Future<void> _openLink(String url) async {
    final id = _capture['id'];
    try {
      final opened = await widget.channel.invokeMethod<bool>(
        MethodNames.openLink,
        {'id': id, 'url': url},
      );
      if (!mounted || _capture['id'] != id) return;
      // 冻结画面会遮住浏览器，打开后结束截图编辑。
      if (opened == true) {
        await _close();
        return;
      }
      setState(() {
        _message = '无法打开链接';
        _failed = true;
      });
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
      // OCR 等待期间可能关闭或替换截图，迟到的识别结果不生成覆盖层、不开始翻译（#115）。
      if (!mounted || _capture['id'] != id) return;
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
        setState(() {
          _ocrOverlays = [];
          _message = '画面中没有可识别的文字';
          _failed = true;
        });
        return;
      }
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

  /// 无参数；合成当前编辑图并请求设备识别文字与二维码/条码。
  /// 返回 text 为 OCR Markdown（可为空），codes 为按位置排序的码；失败时显示错误并返回 null。
  Future<({String text, List<RecognizedCode> codes})?> _recognizeOcr() async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return null;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      final bytes = await _document.renderPng();
      final result = (await widget.channel.invokeMapMethod<String, Object?>(
        MethodNames.recognizeText,
        {'id': id, 'bytes': bytes},
      ))!;
      return (
        text: result['text'] as String,
        codes: [
          for (final code in result['codes'] as List)
            (
              symbology: (code as Map)['symbology'] as String,
              payload: code['payload'] as String,
            ),
        ],
      );
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
    // 输入中在文字框外按下：结束输入并保留文字，这次按下不再创建新内容。
    if (_textInputOpen) {
      _commitText();
      return;
    }
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
    // 标尺只记录两点，新拖动替换上一条；取色只响应单击。二者都不产生标注（#111）。
    if (_tool == ScreenshotTool.ruler) {
      setState(() => _ruler = (start: imagePoint, end: imagePoint));
      return;
    }
    if (_tool == ScreenshotTool.eyedropper) return;
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
    if (_tool == ScreenshotTool.ruler && _ruler != null) {
      setState(() => _ruler = (start: _ruler!.start, end: imagePoint));
      return;
    }
    if (_shapeSelecting) return;
    if (_dragStart == null || _textInputOpen) return;
    setState(() {
      _dragCurrent = imagePoint;
      if (_previewCrop != null) {
        if (_resizeHandle != null) {
          // 锁定比例时控制点按比例调整，移动选区不受比例影响（#106）。
          _previewCrop = _cropRatio == null || _resizeHandle == 'move'
              ? _resizedRect(_document.cropRect, _resizeHandle!, imagePoint)
              : _ratioResized(_document.cropRect, _resizeHandle!, imagePoint);
        } else if (_dragStart != null) {
          _previewCrop = _newSelection(_dragStart!, imagePoint);
        }
        return;
      }
      if (_resizeHandle != null && _selectedTextId != null) {
        final current = _document.annotations
            .where((item) => item.id == _selectedTextId)
            .firstOrNull;
        if (current != null) {
          // _fittedTextBounds 只采纳宽度变化，高度按文字内容重新计算。
          _previewAnnotation = current.copyWith(
            bounds: _fittedTextBounds(
              current,
              _resizedRect(current.bounds, _resizeHandle!, imagePoint),
              moved: _resizeHandle == 'move',
            ),
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
        final rect = _newSelection(start, end);
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
      // 拖出的宽度够大时按该宽度创建，否则按点击创建默认宽度的文字框。
      if (rect.width < ScreenshotDefaults.textBoxMinWidth * _pixelRatio) {
        _openTextInput(start);
      } else {
        _openTextInput(rect.topLeft, width: rect.width);
      }
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
      final handle = textBoxHandle(_handleAt(selected.bounds, imagePoint));
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
        _resizeHandle =
            textBoxHandle(_handleAt(hit.bounds, imagePoint)) ?? 'move';
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
      left <= right - CropMetrics.minSide ? left : right - CropMetrics.minSide,
      top <= bottom - CropMetrics.minSide ? top : bottom - CropMetrics.minSide,
      right,
      bottom,
    );
  }

  /// start/end 为拖出新选区的起止像素点；返回自由或锁定比例的新选区，比例下不强制最小边长（由松手时判断）。
  Rect _newSelection(Offset start, Offset end) => _cropRatio == null
      ? Rect.fromPoints(start, end)
      : ratioRect(
          anchor: start,
          toward: end,
          ratio: _cropRatio!,
          byHeight: false,
          bounds: Size(_document.width.toDouble(), _document.height.toDouble()),
          minSide: 0,
        );

  /// bounds 为当前选区，handle 为控制点，point 为指针像素位置；返回按锁定比例、以对角或对边为锚点调整后的选区（#106）。
  Rect _ratioResized(Rect bounds, String handle, Offset point) {
    // 角点由指针决定宽度；左右边只改宽度、上下边只改高度，另一边按比例推算。
    final (anchor, toward, byHeight) = switch (handle) {
      'nw' => (bounds.bottomRight, point, false),
      'ne' => (bounds.bottomLeft, point, false),
      'sw' => (bounds.topRight, point, false),
      'e' => (bounds.topLeft, Offset(point.dx, bounds.bottom), false),
      'w' => (bounds.topRight, Offset(point.dx, bounds.bottom), false),
      's' => (bounds.topLeft, Offset(bounds.right, point.dy), true),
      'n' => (bounds.bottomLeft, Offset(bounds.right, point.dy), true),
      _ => (bounds.topLeft, point, false),
    };
    return ratioRect(
      anchor: anchor,
      toward: toward,
      ratio: _cropRatio!,
      byHeight: byHeight,
      bounds: Size(_document.width.toDouble(), _document.height.toDouble()),
      minSide: CropMetrics.minSide,
    );
  }

  /// ratio 为选择的宽高比，null 为自由；锁定时以选区左上角为锚点保持宽度调整高度，超出截图则整体缩小，无返回值（#106）。
  void _chooseRatio(double? ratio) {
    setState(() {
      _cropRatio = ratio;
      if (ratio != null) _cropSelected = true;
    });
    if (ratio == null) return;
    final crop = _document.cropRect;
    _document.setCrop(
      ratioRect(
        anchor: crop.topLeft,
        toward: crop.bottomRight,
        ratio: ratio,
        byHeight: false,
        bounds: Size(_document.width.toDouble(), _document.height.toDouble()),
        minSide: CropMetrics.minSide,
      ),
    );
  }

  /// direction 为方向键的单位方向；在截图或光标工具、未选中标注时移动或调整选区。
  /// ⇧ 使用大步长，⌥ 以左上角为锚点调整宽高（锁定比例时另一边按比例推算）；返回是否已处理该按键（#106）。
  bool _nudgeCrop(Offset direction) {
    final keyboard = HardwareKeyboard.instance;
    if (!_document.hasImage ||
        _busy ||
        (_tool != ScreenshotTool.crop && _tool != ScreenshotTool.cursor) ||
        _selectedShapeId != null ||
        _selectedTextId != null ||
        keyboard.isMetaPressed ||
        keyboard.isControlPressed) {
      return false;
    }
    final step = direction *
        (keyboard.isShiftPressed
            ? CropMetrics.nudgeLargeStep
            : CropMetrics.nudgeStep);
    final crop = _document.cropRect;
    final bounds = Size(_document.width.toDouble(), _document.height.toDouble());
    final Rect next;
    if (!keyboard.isAltPressed) {
      // 移动保持尺寸，停在截图边缘。
      next = Rect.fromLTWH(
        (crop.left + step.dx).clamp(0, bounds.width - crop.width).toDouble(),
        (crop.top + step.dy).clamp(0, bounds.height - crop.height).toDouble(),
        crop.width,
        crop.height,
      );
    } else if (_cropRatio == null) {
      next = Rect.fromLTRB(
        crop.left,
        crop.top,
        (crop.right + step.dx)
            .clamp(crop.left + CropMetrics.minSide, bounds.width)
            .toDouble(),
        (crop.bottom + step.dy)
            .clamp(crop.top + CropMetrics.minSide, bounds.height)
            .toDouble(),
      );
    } else {
      next = ratioRect(
        anchor: crop.topLeft,
        toward: crop.bottomRight + step,
        ratio: _cropRatio!,
        byHeight: step.dy != 0,
        bounds: bounds,
        minSide: CropMetrics.minSide,
      );
    }
    setState(() => _cropSelected = true);
    _document.setCrop(next);
    return true;
  }

  /// start/end 为拖拽端点；返回对应工具的预览标注，裁剪/文字返回 null。
  EditAnnotation? _draftAnnotation(Offset start, Offset end) {
    final bounds = Rect.fromPoints(start, end);
    switch (_tool) {
      case ScreenshotTool.cursor:
      case ScreenshotTool.crop:
      case ScreenshotTool.eyedropper:
      case ScreenshotTool.ruler:
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
      // 编号标记以指针所在处为圆心，拖动时跟随指针（#107）。
      case ScreenshotTool.step:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.step,
          style: _nextStyle,
          bounds: Rect.fromCircle(
            center: end,
            radius: DrawingMetrics.stepDiameter * _pixelRatio / 2,
          ),
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

  /// point 为文字框左上角；width 为拖出的宽度，缺省用默认宽度。打开就地输入。
  void _openTextInput(Offset point, {double? width}) {
    _textColor = _drawing.styles[ScreenshotTool.text]!.color;
    _fontSize = _drawing.fontSize;
    final box = _newTextBox(point, width: width);
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
    if (preview == null) return;
    if (text.isEmpty) {
      // 空的文字框不保留；正在编辑的已有文字框一并删除。
      if (editingId != null) _document.removeAnnotation(editingId);
      setState(() => _selectedTextId = null);
      return;
    }
    final fontSize = _toImageFont(_fontSize);
    // 提交时高度按最终文字计算，导出与编辑时的换行一致。
    final bounds = Rect.fromLTWH(
      preview.bounds.left,
      preview.bounds.top,
      preview.bounds.width,
      textBoxHeight(text: text, fontSize: fontSize, width: preview.bounds.width),
    );
    if (editingId != null) {
      final current = _document.annotations
          .where((item) => item.id == editingId)
          .firstOrNull;
      if (current == null) return;
      _document.updateAnnotation(
        current.copyWith(
          text: text,
          bounds: bounds,
          color: _textColor,
          fontSize: fontSize,
        ),
      );
      setState(() => _selectedTextId = editingId);
      return;
    }
    final id = _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: bounds,
        text: text,
        color: _textColor,
        fontSize: fontSize,
      ),
    );
    setState(() => _selectedTextId = id);
  }

  /// point 为文字框左上角，width 为拖出的宽度（源图像素），缺省用默认宽度。
  /// 返回留在图内的一行高文字框；高度之后随文字内容增长。
  Rect _newTextBox(Offset point, {double? width}) {
    final image = _document.imageSize;
    final minWidth = ScreenshotDefaults.textBoxMinWidth * _pixelRatio;
    final wanted = width ?? ScreenshotDefaults.textBoxWidth * _pixelRatio;
    final left = point.dx
        .clamp(0, math.max(0, image.width - minWidth))
        .toDouble();
    final boxWidth = wanted
        .clamp(minWidth, math.max(minWidth, image.width - left))
        .toDouble();
    final fontSize = _toImageFont(_fontSize);
    final height = textBoxHeight(text: '', fontSize: fontSize, width: boxWidth);
    final top = point.dy
        .clamp(0, math.max(0, image.height - height))
        .toDouble();
    return Rect.fromLTWH(left, top, boxWidth, height);
  }

  /// annotation 为文字标注，raw 为拖动得到的矩形，moved 表示整体移动。
  /// 移动时原样返回；拖手柄时只采纳左右边界，宽度不小于最小宽度，高度按文字内容计算。
  Rect _fittedTextBounds(
    EditAnnotation annotation,
    Rect raw, {
    required bool moved,
  }) {
    if (moved) return raw;
    final minWidth = ScreenshotDefaults.textBoxMinWidth * _pixelRatio;
    final width = math.max(minWidth, raw.width);
    // 拖左侧手柄时右边界不动；宽度被最小值限制时左边界跟着收住。
    final left = raw.left == annotation.bounds.left
        ? raw.left
        : annotation.bounds.right - width;
    return Rect.fromLTWH(
      left,
      annotation.bounds.top,
      width,
      textBoxHeight(
        text: annotation.text,
        fontSize: annotation.fontSize,
        width: width,
      ),
    );
  }

  /// 无参数；输入中文字或字号变化后，让文字框高度等于当前内容所需高度。
  void _fitEditingText() {
    final preview = _previewAnnotation;
    if (!_textInputOpen || preview == null) return;
    final height = textBoxHeight(
      text: _textController.text,
      fontSize: preview.fontSize,
      width: preview.bounds.width,
    );
    if (height == preview.bounds.height) return;
    setState(() {
      _previewAnnotation = preview.copyWith(
        bounds: Rect.fromLTWH(
          preview.bounds.left,
          preview.bounds.top,
          preview.bounds.width,
          height,
        ),
      );
    });
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

  /// imagePoint 为点击位置；在该处放置下一个编号标记并记入撤销历史，无返回值（#107）。
  void _placeStep(Offset imagePoint) {
    if (!_document.hasImage || _busy) return;
    // _draftAnnotation 生成以点击处为圆心的编号标记，文档分配正式 id。
    final draft = _draftAnnotation(imagePoint, imagePoint)!;
    _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: draft.kind,
        style: draft.style,
        bounds: draft.bounds,
      ),
    );
  }

  /// imagePoint 为点击位置；点已有文字再编辑，点空白落默认文本框。
  void _onTextTap(Offset imagePoint) {
    // 输入中点击文字框外：结束输入并保留文字。
    if (_textInputOpen) {
      _commitText();
      return;
    }
    if (!_document.hasImage || _busy) return;
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
      // 单击选中；在双击间隔内再次点击同一文字框才进入编辑。
      final now = DateTime.now();
      final again =
          _lastTextTapId == hit.id &&
          now.difference(_lastTextTapAt) <= kDoubleTapTimeout;
      _lastTextTapId = hit.id;
      _lastTextTapAt = now;
      if (again) {
        _openExistingText(hit);
        return;
      }
      setState(() {
        _selectedTextId = hit.id;
        _cropSelected = false;
      });
      return;
    }
    _lastTextTapId = null;
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

  /// 无参数；解除原生回调与文档监听，无返回值。
  @override
  void dispose() {
    _sourceImage?.dispose();
    _feedbackTimer?.cancel();
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
            if (_expandedRow != null) {
              setState(() {
                _expandedRow = null;
                unawaited(_syncRecordingPreview());
                unawaited(_syncLivePreview());
              });
              return KeyEventResult.handled;
            }
            if (_textInputOpen) {
              // Esc 结束输入并保留文字。
              _commitText();
            } else {
              _close();
            }
            return KeyEventResult.handled;
          }
          // 文字输入中把 ⌘Z 与方向键留给输入框；否则与工具栏共用标注历史。
          if (_textInputOpen) return KeyEventResult.ignored;
          // _nudgeCrop 按方向键微调选区；不满足条件时交给后续处理（#106）。
          final direction = _arrowDirections[event.logicalKey];
          if (direction != null && _nudgeCrop(direction)) {
            return KeyEventResult.handled;
          }
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
                      (_recordingExpanded || _liveExpanded) &&
                          _recordingTarget != CaptureTarget.region
                      ? Offset.zero & _document.imageSize
                      : _previewCrop,
                  recordingWindows: _recordingWindows,
                  recordingPreview:
                      (_recordingExpanded || _liveExpanded) &&
                      _recordingTarget != CaptureTarget.region,
                  pixelRatio: _pixelRatio,
                  // 画笔光标与当前粗细、颜色一致；马赛克画笔没有颜色，显示空心圆。
                  brushCursor: NativeBrushCursor(
                    diameter: math.max(
                      NativeBrushCursor.minimumDiameter,
                      _drawing.styleFor(ScreenshotTool.brush).strokeWidth,
                    ),
                    color: _shapeMode == ShapeMode.mosaic
                        ? null
                        : _drawing
                              .styleFor(ScreenshotTool.brush)
                              .color
                              .toARGB32(),
                    channel: widget.channel,
                  ),
                  busy:
                      _busy ||
                      ((_recordingExpanded || _liveExpanded) &&
                          _recordingTarget != CaptureTarget.region),
                  textInputOpen: _textInputOpen && !_dialogOpen,
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
                  onStepTap: (point) {
                    if (_tool == renderedTool) _placeStep(point);
                  },
                  ruler: _ruler,
                  picker: _picker,
                  pickerColor: _pickedColor,
                  onPickerHover: _hoverPicker,
                  onPickerTap: (point) {
                    if (_tool == renderedTool) unawaited(_pickColor(point));
                  },
                  cropSelected:
                      _cropSelected &&
                      !((_recordingExpanded || _liveExpanded) &&
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
                  // 第二行是当前父级的子级加上当前工具的属性。
                  secondaryItemCount:
                      _visibleChildren.length +
                      _toolbarActions().keys
                          .where(
                            (id) =>
                                id != ScreenshotActions.reveal &&
                                !ScreenshotActions.icons.containsKey(id),
                          )
                          .length,
                  toolbarItemCount:
                      _toolbar.order
                          .where((id) => !_toolbar.hidden.contains(id))
                          .length +
                      (_busy ? 1 : 0),
                  // 两种准备共用行数。工具栏厚度和按钮行宽都靠它留在屏幕安全区内。
                  recordingRows:
                      (_recordingExpanded || _liveExpanded) &&
                          _tool == ScreenshotTool.crop
                      ? (_recordingTarget == CaptureTarget.application ? 2 : 1)
                      : 0,
                  applicationCount: _recordingApplications.length,
                  beautify: _beautify,
                  // 美化行：无背景 + 渐变 + 内边距 + 两种圆角 + 阴影；比例行：全部比例预设。
                  settingsRowItems: switch (_expandedRow) {
                    _ExpandedRow.beautify =>
                      1 +
                          BeautifyMetrics.backgrounds.length +
                          BeautifyMetrics.paddings.length +
                          3,
                    _ExpandedRow.ratio => CropMetrics.ratios.length,
                    _ => 0,
                  },
                  feedbackIsError: _failed,
                  feedback: _message,
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
              // 识别结果弹窗浮在截图之上，初始居中，可拖动标题区移动。
              if (_recognition != null)
                Center(
                  child: Transform.translate(
                    offset: _recognizedOffset,
                    child: SizedBox.fromSize(
                      size: RecognizedTextPanel.size,
                      child: RecognizedTextPanel(
                        text: _recognition!.text,
                        codes: _recognition!.codes,
                        onCopyAll: () =>
                            _copyRecognized(_recognition!.text, '已复制文字'),
                        onCopyCode: (payload) =>
                            _copyRecognized(payload, '已复制内容'),
                        onOpenLink: _openLink,
                        onClose: () => setState(() => _recognition = null),
                        onDrag: (delta) =>
                            setState(() => _recognizedOffset += delta),
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
      final preview = _previewAnnotation!;
      _previewAnnotation = preview.copyWith(
        color: _textColor,
        fontSize: imageFont,
        bounds: Rect.fromLTWH(
          preview.bounds.left,
          preview.bounds.top,
          preview.bounds.width,
          textBoxHeight(
            text: _textController.text,
            fontSize: imageFont,
            width: preview.bounds.width,
          ),
        ),
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
      current.copyWith(
        color: _textColor,
        fontSize: imageFont,
        // 字号变化后高度按内容重新计算，宽度不变。
        bounds: Rect.fromLTWH(
          current.bounds.left,
          current.bounds.top,
          current.bounds.width,
          textBoxHeight(
            text: current.text,
            fontSize: imageFont,
            width: current.bounds.width,
          ),
        ),
      ),
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
      // 录制用截图选区作为目标：无论它被拼在哪里，点击都切到截图工具并展开或收起目标选择行。
      ScreenshotActions.record: _capture['canCaptureMedia'] == true
          ? () {
              setState(() {
                _tool = ScreenshotTool.crop;
                _expandedRow = _recordingExpanded
                    ? null
                    : _ExpandedRow.recording;
                _selectedShapeId = null;
                _selectedTextId = null;
              });
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
            }
          : null,
      ScreenshotActions.scrolling: _capture['canCaptureMedia'] == true
          ? () => _prepareCapture(CaptureTarget.region, scrolling: true)
          : null,
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
          // 切换工具前结束输入并保留文字。
          if (_textInputOpen) _commitText();
          _tool = entry.value;
          _expandedRow = null;
          // 测量结果只属于当前工具，切换后清除（#111）。
          _ruler = null;
          _picker = null;
          unawaited(_syncRecordingPreview());
          unawaited(_syncLivePreview());
          _recordingApplication = null;
          _selectedShapeId = null;
          _selectedTextId = null;
        }),
      // 实时翻译同样使用截图选区：切到截图工具并展开或收起目标选择行。
      ScreenshotActions.live: _capture['canCaptureMedia'] == true
          ? () {
              setState(() {
                _tool = ScreenshotTool.crop;
                _expandedRow = _liveExpanded ? null : _ExpandedRow.live;
                _selectedShapeId = null;
                _selectedTextId = null;
              });
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
            }
          : null,
      // 美化只改变导出外观：展开或收起设置行，与录制、实时翻译目标行互斥。
      ScreenshotActions.beautify: _document.hasImage
          ? () {
              setState(() {
                _expandedRow = _beautifyExpanded
                    ? null
                    : _ExpandedRow.beautify;
              });
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
            }
          : null,
      // 比例作用于截图选区：切到截图工具并展开或收起比例行，与其他设置行互斥（#106）。
      ScreenshotActions.ratio: _document.hasImage
          ? () {
              setState(() {
                _tool = ScreenshotTool.crop;
                _expandedRow = _expandedRow == _ExpandedRow.ratio
                    ? null
                    : _ExpandedRow.ratio;
                _selectedShapeId = null;
                _selectedTextId = null;
              });
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
            }
          : null,
      ScreenshotActions.pin: _document.hasImage ? () => _export('pin') : null,
      ScreenshotActions.save: _document.hasImage ? () => _export('save') : null,
      ScreenshotActions.copy: _document.hasImage ? () => _export('copy') : null,
      ScreenshotActions.upload: _document.hasImage ? _upload : null,
      ScreenshotActions.ocrCopy: _document.hasImage ? _showRecognizedText : null,
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
    // 第二行先放当前父级的子级，再放当前工具的属性。
    final attributes = [
      ..._visibleChildren,
      ...actions.keys.where(
        (id) =>
            id != ScreenshotActions.reveal &&
            !ScreenshotActions.icons.containsKey(id),
      ),
    ];
    if (actions.containsKey(ScreenshotActions.reveal)) {
      top.add(ScreenshotActions.reveal);
    }
    final colors = Theme.of(context).colorScheme;
    final icons = <String, IconData>{
      ...ScreenshotActions.icons,
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
      '${ScreenshotActions.brushPrefix}highlighter': Icons.border_color,
    };
    // 模式按钮不产生hover层；普通操作保留主题反馈，属性不进入顶层排序。
    Widget button(String id) {
      final mode =
          id.startsWith(ScreenshotActions.shapePrefix) ||
          id.startsWith(ScreenshotActions.brushPrefix);
      // 高亮正在使用的功能，以及第二行所属的父级。
      final selected =
          id == _activeId ||
          id == _group ||
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
    final beautify = _beautify;
    final rows = <Widget>[
      row(top, 'screenshot-tools-row', loading: _busy),
      if (attributes.isNotEmpty) row(attributes, 'screenshot-attributes-row'),
      // 美化行：背景、内边距、圆角与阴影；未选背景时其余选项不可用（#103）。
      if (_beautifyExpanded)
        captureRow('beautify-row', [
          captureButton(
            '无背景',
            const Icon(Icons.block, size: 16),
            () => setState(() => _beautify = null),
            selected: beautify == null,
          ),
          for (final (index, preset) in BeautifyMetrics.backgrounds.indexed)
            captureButton(
              preset.name,
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [preset.from, preset.to],
                  ),
                ),
              ),
              () => setState(
                () => _beautify =
                    beautify?.copyWith(background: index) ??
                    BeautifyStyle(background: index),
              ),
              selected: beautify?.background == index,
            ),
          for (final option in BeautifyMetrics.paddings)
            captureButton(
              '内边距${option.label}',
              Text(option.label),
              beautify == null
                  ? null
                  : () => setState(
                      () =>
                          _beautify = beautify.copyWith(padding: option.value),
                    ),
              selected: beautify?.padding == option.value,
            ),
          for (final (label, icon, radius) in const [
            ('直角', Icons.crop_square, BeautifyMetrics.squareRadius),
            ('圆角', Icons.rounded_corner, BeautifyMetrics.roundRadius),
          ])
            captureButton(
              label,
              Icon(icon, size: 16),
              beautify == null
                  ? null
                  : () => setState(
                      () => _beautify = beautify.copyWith(cornerRadius: radius),
                    ),
              selected: beautify?.cornerRadius == radius,
            ),
          captureButton(
            '阴影',
            const Icon(Icons.layers, size: 16),
            beautify == null
                ? null
                : () => setState(
                    () =>
                        _beautify = beautify.copyWith(shadow: !beautify.shadow),
                  ),
            selected: beautify?.shadow == true,
          ),
        ]),
      // 比例行：自由与固定宽高比，锁定后框选与调整保持比例（#106）。
      if (_expandedRow == _ExpandedRow.ratio)
        captureRow('ratio-row', [
          for (final preset in CropMetrics.ratios)
            captureButton(
              preset.label == '自由' ? '自由比例' : '比例 ${preset.label}',
              Text(
                preset.label,
                style: const TextStyle(fontSize: CropMetrics.ratioFontSize),
              ),
              () => _chooseRatio(preset.ratio),
              selected: _cropRatio == preset.ratio,
            ),
        ]),
      if ((_recordingExpanded || _liveExpanded) &&
          _tool == ScreenshotTool.crop)
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
            _liveExpanded ? '开始实时翻译' : '开始录制',
            const Icon(Icons.fiber_manual_record, size: 16),
            _loadingApplications ||
                    (_recordingTarget == CaptureTarget.application &&
                        _recordingApplication == null)
                ? null
                : () => _prepareCapture(
                    _recordingTarget,
                    live: _liveExpanded,
                  ),
          ),
          captureButton(
            _liveExpanded ? '取消实时翻译' : '取消录制',
            const Icon(Icons.close, size: 16),
            () => setState(() {
              _expandedRow = null;
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
              _recordingApplication = null;
            }),
          ),
        ]),
      if ((_recordingExpanded || _liveExpanded) &&
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
    // 响应文字由画布外层独立定位，工具组始终使用完整工具栏空间。
    return SizedBox(
      key: const Key('screenshot-toolbar'),
      child: Padding(padding: const EdgeInsets.all(8), child: groups),
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
    required this.brushCursor,
    required this.busy,
    required this.textInputOpen,
    required this.textController,
    required this.textFocus,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTextTap,
    required this.onCropTap,
    required this.onStepTap,
    required this.ruler,
    required this.picker,
    required this.pickerColor,
    required this.onPickerHover,
    required this.onPickerTap,
    required this.cropSelected,
    required this.activeHandle,
    required this.onDoubleTap,
    required this.onDoubleTapDown,
    required this.toolbarBuilder,
    this.toolbarSafeArea,
    this.displaySize,
    required this.toolbarItemCount,
    this.secondaryItemCount = 0,
    this.recordingRows = 0,
    this.beautify,
    this.settingsRowItems = 0,
    this.applicationCount = 0,
    required this.feedbackIsError,
    required this.feedback,
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

  /// 本次截图的美化参数；非 null 时在选区外预览背景与阴影。
  final BeautifyStyle? beautify;

  /// 展开中的美化行或比例行的按钮数；0 表示均收起，参与工具栏尺寸计算。
  final int settingsRowItems;
  final int applicationCount;
  final bool feedbackIsError;
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

  /// 画笔工具在画布上使用的光标。
  final MouseCursor brushCursor;
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

  /// 编号工具下的单击位置（源图像素）；放置编号标记（#107）。
  final ValueChanged<Offset> onStepTap;

  /// 标尺两端、取色悬停点（截图像素）与该点源像素颜色；由 MeasureLayer 显示（#111）。
  final ({Offset start, Offset end})? ruler;
  final Offset? picker;
  final Color? pickerColor;

  /// 取色工具下的悬停位置（截图像素，离开画布为 null）与单击位置（#111）。
  final ValueChanged<Offset?> onPickerHover;
  final ValueChanged<Offset> onPickerTap;
  final bool cropSelected;
  final String? activeHandle;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onDoubleTapDown;

  /// axis 由可用空白决定；返回具有相应滚动方向的工具栏。
  final Widget Function(BuildContext context, Axis axis) toolbarBuilder;
  final String? feedback;
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
            if (widget.settingsRowItems > 0) widget.settingsRowItems,
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
                widget.recordingRows +
                (widget.settingsRowItems > 0 ? 1 : 0),
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

          // 文字、编号、取色与标尺的连续单击不能被识别为双击复制，也不等待双击超时。
          final singleTapTool = const {
            ScreenshotTool.text,
            ScreenshotTool.step,
            ScreenshotTool.eyedropper,
            ScreenshotTool.ruler,
          }.contains(widget.tool);
          final canvasContent = MouseRegion(
            opaque: false,
            // 取色工具悬停时报告指针处的截图像素（#111）。
            onHover: widget.tool == ScreenshotTool.eyedropper
                ? (event) => widget.onPickerHover(toImage(event.localPosition))
                : null,
            onExit: (_) => widget.onPickerHover(null),
            child: GestureDetector(
              key: const Key('screenshot-canvas'),
              // 裁剪起点就是按下点，不能被手势识别阈值移动。
              dragStartBehavior: DragStartBehavior.down,
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: widget.textInputOpen || widget.busy || singleTapTool
                  ? null
                  : (details) =>
                        widget.onDoubleTapDown(toImage(details.localPosition)),
              onDoubleTap: widget.textInputOpen || widget.busy || singleTapTool
                  ? null
                  : widget.onDoubleTap,
              onPanStart: widget.busy
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
              onTapUp: !widget.busy
                  ? (details) {
                      final point = toImage(details.localPosition);
                      // 输入中的点击只用于结束输入，由文字入口统一处理。
                      if (widget.textInputOpen) {
                        widget.onTextTap(point);
                      } else if (widget.tool == ScreenshotTool.crop) {
                        widget.onCropTap(point);
                      } else if (widget.tool == ScreenshotTool.text ||
                          widget.tool == ScreenshotTool.cursor) {
                        widget.onTextTap(point);
                      } else if (widget.tool == ScreenshotTool.step) {
                        widget.onStepTap(point);
                      } else if (widget.tool == ScreenshotTool.eyedropper) {
                        widget.onPickerTap(point);
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
                  // 测量线与取色标签在标注之上，不进入导出（#111）。
                  if (widget.ruler != null || widget.picker != null)
                    MeasureLayer(
                      imageSize: imageSize,
                      ruler: widget.ruler,
                      picker: widget.picker,
                      pickerColor: widget.pickerColor,
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
                    : textBoxHandle(
                        editHandleAt(
                          box,
                          point,
                          pad,
                          edgePad:
                              GlassMetrics.cropEdgeHitRadius *
                              widget.pixelRatio,
                        ),
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
                      textBoxHandle(
                            editHandleAt(
                              annotation.bounds,
                              point,
                              pad,
                              edgePad:
                                  GlassMetrics.cropEdgeHitRadius *
                                  widget.pixelRatio,
                            ),
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
              if (widget.tool == ScreenshotTool.brush) return widget.brushCursor;
              // 取色与标尺需要对准像素（#111）。
              if (widget.tool == ScreenshotTool.eyedropper ||
                  widget.tool == ScreenshotTool.ruler) {
                return SystemMouseCursors.precise;
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
                      beautify: widget.beautify,
                      // 显示坐标中每个屏幕点的长度，使预览内边距与导出一致。
                      beautifyUnit:
                          fitted.width / (imageSize.width / widget.pixelRatio),
                      showHandles: widget.cropSelected,
                      windows: widget.recordingWindows
                          ?.map(
                            (rect) => mapRectToFitted(rect, imageSize, fitted),
                          )
                          .toList(),
                    ),
                  ),
                ),
                // 选区像素尺寸标签：优先在左上角外侧上方，空间不足时放进选区内（#106）。
                if ((widget.tool == ScreenshotTool.crop ||
                        widget.tool == ScreenshotTool.cursor) &&
                    widget.recordingWindows == null &&
                    !widget.textInputOpen)
                  Positioned(
                    left: cropDisplay.left +
                        (cropDisplay.top -
                                    CropMetrics.labelGap -
                                    CropMetrics.labelHeight <
                                fitted.top
                            ? CropMetrics.labelGap
                            : 0),
                    top: cropDisplay.top -
                                CropMetrics.labelGap -
                                CropMetrics.labelHeight <
                            fitted.top
                        ? cropDisplay.top + CropMetrics.labelGap
                        : cropDisplay.top -
                              CropMetrics.labelGap -
                              CropMetrics.labelHeight,
                    child: IgnorePointer(
                      child: Container(
                        key: const Key('crop-size-label'),
                        height: CropMetrics.labelHeight,
                        padding: const EdgeInsets.symmetric(
                          horizontal: CropMetrics.labelPadding,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: CropMetrics.labelBackground,
                          borderRadius: BorderRadius.circular(
                            CropMetrics.labelRadius,
                          ),
                        ),
                        child: Text(
                          '${(widget.previewCrop ?? widget.document.cropRect).width.round()} × '
                          '${(widget.previewCrop ?? widget.document.cropRect).height.round()}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: CropMetrics.labelFontSize,
                            fontFeatures: [ui.FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                // 拖动时不让工具栏遮住正在变化的选区；松开后按新选区重新定位。
                if ((widget.dragStart == null || widget.textInputOpen) &&
                    (widget.toolbarItemCount > 0 ||
                        widget.secondaryItemCount > 0))
                  Positioned.fromRect(
                    rect: layout.toolbar,
                    child: widget.toolbarBuilder(context, layout.axis),
                  ),
                if (widget.feedback != null)
                  ToolbarFeedback(
                    toolbar: layout.toolbar,
                    message: widget.feedback!,
                    isError: widget.feedbackIsError,
                  ),
                if (widget.textInputOpen)
                  Positioned.fromRect(
                    rect: mapRectToFitted(
                      (widget.previewAnnotation ?? widget.selectedText)
                              ?.bounds ??
                          Rect.fromLTWH(
                            widget.dragStart?.dx ?? 0,
                            widget.dragStart?.dy ?? 0,
                            ScreenshotDefaults.textBoxWidth * widget.pixelRatio,
                            0,
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
                            // 回车是换行；结束输入靠点击框外、Esc 或切换工具。
                            textInputAction: TextInputAction.newline,
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
                            // 无边框无内边距：输入时的文字位置与提交后一致，边框由文字框描边绘制。
                            decoration: const InputDecoration.collapsed(
                              hintText: '输入文字',
                              hintStyle: TextStyle(color: Color(0x99FFFFFF)),
                            ),
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

/// handle 为文字框上命中的控制点。文字框高度随内容决定，上下边不能拉伸，按移动处理；
/// 其余控制点原样返回。
String? textBoxHandle(String? handle) =>
    handle == 'n' || handle == 's' ? 'move' : handle;

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
    this.beautify,
    this.beautifyUnit = 1,
  });

  /// 美化参数与显示坐标中每屏幕点的长度；非 null 时在选区外画出背景与阴影预览。
  final BeautifyStyle? beautify;
  final double beautifyUnit;

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
    // paintBeautifyBackdrop 与导出共用，预览即导出外观；窗口录制预览不显示美化。
    if (beautify != null && windows == null) {
      paintBeautifyBackdrop(canvas, cropDisplay, beautify!, unit: beautifyUnit);
    }
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
      oldDelegate.beautify != beautify ||
      oldDelegate.beautifyUnit != beautifyUnit ||
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
    // stepNumbers 按标注顺序编号，与导出一致；拖动中的新标记排在最后（#107）。
    final numbers = stepNumbers(annotations);
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
        stepNumber: numbers[annotation.id],
      );
    }
    if (previewAnnotation != null) {
      EditDocument.paintAnnotation(
        canvas,
        previewAnnotation!,
        sourceImage: sourceImage,
        stepNumber: numbers.length + 1,
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
