import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'edit_document.dart';

/// capturedAt 为本地截图时间；返回带毫秒时间的 PNG 名称，重名序号由原生文件写入负责。
String screenshotFilename(DateTime capturedAt) {
  String pad(int value, [int width = 2]) =>
      value.toString().padLeft(width, '0');
  return '截图_${capturedAt.year}-${pad(capturedAt.month)}-${pad(capturedAt.day)}_'
      '${pad(capturedAt.hour)}-${pad(capturedAt.minute)}-${pad(capturedAt.second)}-'
      '${pad(capturedAt.millisecond, 3)}.png';
}

/// 编辑工具；与工具栏一一对应，不含设置里的目录选择。
enum ScreenshotTool { crop, rect, arrow, text, mask, brush }

/// 独立截图编辑入口；channel 连接原生内存截图、剪贴板、保存与贴图。
class ScreenshotApp extends StatefulWidget {
  const ScreenshotApp({
    super.key,
    this.channel = const MethodChannel('translateapp/screenshot'),
  });

  final MethodChannel channel;

  /// 无参数；创建编辑窗口状态。
  @override
  State<ScreenshotApp> createState() => _ScreenshotAppState();
}

class _ScreenshotAppState extends State<ScreenshotApp> {
  final EditDocument _document = EditDocument();
  final FocusNode _focusNode = FocusNode();
  final FocusNode _textFocus = FocusNode();
  final TextEditingController _textController = TextEditingController();
  final List<Offset> _strokePoints = [];

  Map<Object?, Object?> _capture = {};
  ScreenshotTool _tool = ScreenshotTool.crop;
  bool _busy = false;
  bool _failed = false;
  bool _textInputOpen = false;
  String? _message;
  String? _savedPath;
  List<_OcrOverlay> _ocrOverlays = [];
  Offset? _dragStart;
  Offset? _dragCurrent;
  // 拖拽预览不进历史；松手后才 add/setCrop，保证一次手势一条撤销。
  EditAnnotation? _previewAnnotation;

  /// 无参数；先监听再拉取快照，首张截图无需等待引擎启动通知，无返回值。
  @override
  void initState() {
    super.initState();
    _document.addListener(_onDocumentChanged);
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == 'screenshotChanged') {
        _replace(Map<Object?, Object?>.from(call.arguments as Map));
      } else if (call.method == 'escapePressed') {
        if (_textInputOpen) {
          _cancelText();
        } else {
          await _close();
        }
      } else if (call.method == 'undoPressed') {
        if (!_textInputOpen && _document.canUndo) _document.undo();
      } else if (call.method == 'redoPressed') {
        if (!_textInputOpen && _document.canRedo) _document.redo();
      }
    });
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// 无参数；文档变更时刷新叠加层，无返回值。
  void _onDocumentChanged() {
    if (mounted) setState(() {});
  }

  /// value 为原生截图快照；替换图片并清空上一张草稿，无返回值。
  void _replace(Map<Object?, Object?> value) {
    if (!mounted) return;
    final bytes = value['bytes'] as Uint8List?;
    final width = (value['width'] as num?)?.toInt() ?? 0;
    final height = (value['height'] as num?)?.toInt() ?? 0;
    setState(() {
      _capture = value;
      _message = value['error'] as String?;
      _failed = _message != null;
      _savedPath = null;
      _busy = false;
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _textInputOpen = false;
      _textController.clear();
      _strokePoints.clear();
      _ocrOverlays = [];
      _tool = ScreenshotTool.crop;
      if (bytes != null && width > 0 && height > 0) {
        _document.loadCapture(bytes, width, height);
      } else {
        _document.clear();
      }
    });
  }

  /// 无参数；拉取内存截图，失败保留可见错误，无返回值。
  Future<void> _load() async {
    try {
      final snapshot =
          await widget.channel.invokeMapMethod('getScreenshot') ?? {};
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
        saved = await widget.channel.invokeMethod<String>('saveScreenshot', {
          'id': id,
          'bytes': bytes,
          'name': screenshotFilename(
            DateTime.fromMillisecondsSinceEpoch(_capture['capturedAt'] as int),
          ),
        });
        if (saved == null) return;
        if (!mounted || _capture['id'] != id) return;
        setState(() {
          _savedPath = saved;
          _message = '已保存截图';
        });
        return;
      }
      if (action == 'pin') {
        final pinId = await widget.channel.invokeMethod<String>(
          'pinScreenshot',
          {'id': id, 'bytes': bytes},
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
        await widget.channel.invokeMethod<void>('closeScreenshot');
        return;
      }
      await widget.channel.invokeMethod<void>('copyScreenshot', {
        'id': id,
        'bytes': bytes,
      });
      if (!mounted || _capture['id'] != id) return;
      setState(() => _message = '已复制图片');
      if (closeAfterCopy) {
        await widget.channel.invokeMethod<void>('closeScreenshot');
      }
    } on PlatformException catch (error) {
      if (!mounted || _capture['id'] != id) return;
      setState(() {
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
      if (method == 'requestScreenAccess' && value is Map) {
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
    final text = await _recognizeOcr();
    if (text == null) return;
    if (text.trim().isEmpty) {
      setState(() {
        _message = '画面中没有可识别的文字';
        _failed = true;
      });
      return;
    }
    try {
      await widget.channel.invokeMethod<void>('copyText', {'text': text});
      if (mounted) setState(() => _message = '已复制文字');
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  /// 无参数；识别文字后把译文浮在原位置；走 translatePlainText，不开选区会话、不写历史。
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
      final raw = await widget.channel.invokeListMethod('recognizeBlocks', {
        'id': id,
        'bytes': bytes,
      });
      final blocks = [
        for (final item in raw ?? const [])
          if (item is Map)
            _OcrOverlay(
              source: '${item['text'] ?? ''}',
              rect: Rect.fromLTWH(
                _document.cropRect.left + ((item['x'] as num?)?.toDouble() ?? 0),
                _document.cropRect.top + ((item['y'] as num?)?.toDouble() ?? 0),
                (item['width'] as num?)?.toDouble() ?? 0,
                (item['height'] as num?)?.toDouble() ?? 0,
              ),
            ),
      ].where((item) => item.source.trim().isNotEmpty).toList();
      if (blocks.isEmpty) {
        if (mounted) {
          setState(() {
            _ocrOverlays = [];
            _message = '画面中没有可识别的文字';
            _failed = true;
          });
        }
        return;
      }
      final joined = blocks.map((item) => item.source).join('\n');
      final translated = await widget.channel.invokeMethod<String>(
        'translatePlainText',
        {'text': joined},
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
      if (mounted) {
        setState(() {
          _ocrOverlays = overlays;
          _message = '已在图上显示译文';
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
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
      final text = await widget.channel.invokeMethod<String>('recognizeText', {
        'id': id,
        'bytes': bytes,
      });
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
  Future<void> _close() => _command('closeScreenshot');

  /// imagePoint 为源图像素坐标；按当前工具开始拖拽或打开文本输入，无返回值。
  void _onDragStart(Offset imagePoint) {
    if (!_document.hasImage || _busy || _textInputOpen) return;
    if (_tool == ScreenshotTool.text) {
      _openTextInput(imagePoint);
      return;
    }
    setState(() {
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
    if (_dragStart == null || _textInputOpen) return;
    setState(() {
      _dragCurrent = imagePoint;
      if (_tool == ScreenshotTool.brush) {
        _strokePoints.add(imagePoint);
      }
      _previewAnnotation = _draftAnnotation(_dragStart!, imagePoint);
    });
  }

  /// 无参数；结束拖拽并提交裁剪/标注，无返回值。
  void _onDragEnd() {
    if (_dragStart == null) return;
    final start = _dragStart!;
    final end = _dragCurrent ?? start;
    final preview = _previewAnnotation;
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
    });
    if (_tool == ScreenshotTool.crop) {
      final rect = Rect.fromPoints(start, end);
      if (rect.width >= 1 && rect.height >= 1) {
        _document.setCrop(rect);
      }
      return;
    }
    if (_tool == ScreenshotTool.brush) {
      if (_strokePoints.length >= 2) {
        _document.addAnnotation(
          EditAnnotation(
            id: '',
            kind: AnnotationKind.stroke,
            bounds: _boundsFor(_strokePoints),
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

  /// start/end 为拖拽端点；返回对应工具的预览标注，裁剪/文字返回 null。
  EditAnnotation? _draftAnnotation(Offset start, Offset end) {
    final bounds = Rect.fromPoints(start, end);
    switch (_tool) {
      case ScreenshotTool.crop:
      case ScreenshotTool.text:
        return null;
      case ScreenshotTool.brush:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.stroke,
          bounds: _boundsFor(_strokePoints.isEmpty ? [start, end] : _strokePoints),
          points: List<Offset>.from(
            _strokePoints.isEmpty ? [start, end] : _strokePoints,
          ),
        );
      case ScreenshotTool.rect:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.rectangle,
          bounds: bounds,
        );
      case ScreenshotTool.arrow:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.arrow,
          bounds: bounds,
          start: start,
          end: end,
        );
      case ScreenshotTool.mask:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.mask,
          bounds: bounds,
          color: const Color(0xFF000000),
        );
    }
  }

  /// points 为笔划点列；返回包围盒，单点时给 1px 以免空矩形。
  Rect _boundsFor(List<Offset> points) {
    var minX = points.first.dx;
    var minY = points.first.dy;
    var maxX = minX;
    var maxY = minY;
    for (final point in points) {
      minX = minX < point.dx ? minX : point.dx;
      minY = minY < point.dy ? minY : point.dy;
      maxX = maxX > point.dx ? maxX : point.dx;
      maxY = maxY > point.dy ? maxY : point.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX == minX ? minX + 1 : maxX, maxY == minY ? minY + 1 : maxY);
  }

  /// point 为点击位置；打开就地文本输入，确认后写入标注，无返回值。
  void _openTextInput(Offset point) {
    setState(() {
      _textInputOpen = true;
      _textController.text = '';
      _dragStart = point;
    });
    // 父级 Focus 会抢走按键；输入时把焦点交给文本框。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  /// 无参数；提交文本标注并关闭输入框，无返回值。
  void _commitText() {
    final point = _dragStart;
    final text = _textController.text.trim();
    setState(() {
      _textInputOpen = false;
      _dragStart = null;
      _dragCurrent = null;
    });
    if (point == null || text.isEmpty) return;
    _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: Rect.fromLTWH(point.dx, point.dy, 240, 36),
        text: text,
      ),
    );
  }

  /// 无参数；取消文本输入，不写入标注，无返回值。
  void _cancelText() {
    setState(() {
      _textInputOpen = false;
      _dragStart = null;
      _dragCurrent = null;
      _textController.clear();
    });
  }

  /// 无参数；解除原生回调与文档监听，无返回值。
  @override
  void dispose() {
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
    final hasImage = _document.hasImage;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF286A65),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_textInputOpen) {
              _cancelText();
            } else {
              _close();
            }
            return KeyEventResult.handled;
          }
          // 文字输入中把 ⌘Z 留给输入框；否则与工具栏共用标注历史。
          if (_textInputOpen) return KeyEventResult.ignored;
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          final meta = keys.contains(LogicalKeyboardKey.metaLeft) ||
              keys.contains(LogicalKeyboardKey.metaRight);
          if (meta && event.logicalKey == LogicalKeyboardKey.keyZ) {
            final shift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
                keys.contains(LogicalKeyboardKey.shiftRight);
            if (shift) {
              if (_document.canRedo) _document.redo();
            } else {
              if (_document.canUndo) _document.undo();
            }
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
                  document: _document,
                  tool: _tool,
                  dragStart: _dragStart,
                  dragCurrent: _dragCurrent,
                  previewAnnotation: _previewAnnotation,
                  busy: _busy,
                  textInputOpen: _textInputOpen,
                  textController: _textController,
                  textFocus: _textFocus,
                  onDragStart: _onDragStart,
                  onDragUpdate: _onDragUpdate,
                  onDragEnd: _onDragEnd,
                  onDoubleTap: () =>
                      _export('copy', closeAfterCopy: true),
                  onCommitText: _commitText,
                  toolbar: _buildToolbar(),
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
                              style: const TextStyle(color: Colors.white, fontSize: 15),
                            ),
                            if (_capture['screenAccess'] == false) ...[
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _command('requestScreenAccess'),
                                child: const Text('申请屏幕录制权限'),
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
                  child: IconButton(
                    key: const Key('screenshot-close'),
                    tooltip: '关闭',
                    onPressed: _busy ? null : _close,
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 无参数；返回贴近选区的工具栏，含反馈文案。
  Widget _buildToolbar() {
    Widget toolButton({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback? onPressed,
      bool selected = false,
    }) {
      return IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        color: selected ? const Color(0xFF5EEAD4) : Colors.white,
        icon: Icon(icon, size: 20),
      );
    }

    return Material(
      color: const Color(0xEE1F2933),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
              children: [
                toolButton(
                  key: const Key('screenshot-tool-crop'),
                  tooltip: '裁剪',
                  icon: Icons.crop,
                  selected: _tool == ScreenshotTool.crop,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _tool = ScreenshotTool.crop),
                ),
                toolButton(
                  key: const Key('screenshot-tool-rect'),
                  tooltip: '矩形',
                  icon: Icons.crop_square,
                  selected: _tool == ScreenshotTool.rect,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _tool = ScreenshotTool.rect),
                ),
                toolButton(
                  key: const Key('screenshot-tool-arrow'),
                  tooltip: '箭头',
                  icon: Icons.north_east,
                  selected: _tool == ScreenshotTool.arrow,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _tool = ScreenshotTool.arrow),
                ),
                toolButton(
                  key: const Key('screenshot-tool-text'),
                  tooltip: '文字',
                  icon: Icons.text_fields,
                  selected: _tool == ScreenshotTool.text,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _tool = ScreenshotTool.text),
                ),
                toolButton(
                  key: const Key('screenshot-tool-mask'),
                  tooltip: '遮挡',
                  icon: Icons.hide_source,
                  selected: _tool == ScreenshotTool.mask,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _tool = ScreenshotTool.mask),
                ),
                toolButton(
                  key: const Key('screenshot-tool-brush'),
                  tooltip: '画笔',
                  icon: Icons.brush,
                  selected: _tool == ScreenshotTool.brush,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _tool = ScreenshotTool.brush),
                ),
                toolButton(
                  key: const Key('screenshot-undo'),
                  tooltip: '撤销',
                  icon: Icons.undo,
                  onPressed: !_busy && _document.canUndo
                      ? _document.undo
                      : null,
                ),
                toolButton(
                  key: const Key('screenshot-redo'),
                  tooltip: '重做',
                  icon: Icons.redo,
                  onPressed: !_busy && _document.canRedo
                      ? _document.redo
                      : null,
                ),
                toolButton(
                  key: const Key('screenshot-pin'),
                  tooltip: '贴图',
                  icon: Icons.push_pin_outlined,
                  onPressed: !_busy && _document.hasImage
                      ? () => _export('pin')
                      : null,
                ),
                toolButton(
                  key: const Key('screenshot-save'),
                  tooltip: '保存',
                  icon: Icons.save_outlined,
                  onPressed: !_busy && _document.hasImage
                      ? () => _export('save')
                      : null,
                ),
                toolButton(
                  key: const Key('screenshot-copy'),
                  tooltip: '复制图片',
                  icon: Icons.copy_outlined,
                  onPressed: !_busy && _document.hasImage
                      ? () => _export('copy')
                      : null,
                ),
                toolButton(
                  key: const Key('screenshot-ocr-copy'),
                  tooltip: '复制文字',
                  icon: Icons.text_snippet_outlined,
                  onPressed: !_busy && _document.hasImage ? _copyOcrText : null,
                ),
                toolButton(
                  key: const Key('screenshot-ocr-translate'),
                  tooltip: '翻译文字',
                  icon: Icons.translate,
                  onPressed: !_busy && _document.hasImage ? _translateOcr : null,
                ),
                toolButton(
                  key: const Key('screenshot-close'),
                  tooltip: '关闭',
                  icon: Icons.close,
                  onPressed: _busy ? null : _close,
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    // 静态图标避免无限转动动画拖住 pumpAndSettle。
                    child: Icon(Icons.hourglass_top, size: 14),
                  ),
              ],
            ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: SelectableText(
                  _message!,
                  style: TextStyle(
                    color: _failed
                        ? Colors.redAccent.shade100
                        : const Color(0xFF5EEAD4),
                    fontSize: 12,
                  ),
                ),
              ),
            if (_savedPath != null)
              TextButton(
                onPressed: () => widget.channel.invokeMethod<void>(
                  'revealFile',
                  {'path': _savedPath},
                ),
                child: const Text('在 Finder 中显示'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 源图、裁剪框、标注与工具栏的叠加绘制面。
class _EditorSurface extends StatelessWidget {
  const _EditorSurface({
    required this.document,
    required this.tool,
    required this.dragStart,
    required this.dragCurrent,
    required this.previewAnnotation,
    required this.busy,
    required this.textInputOpen,
    required this.textController,
    required this.textFocus,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDoubleTap,
    required this.onCommitText,
    required this.toolbar,
    required this.ocrOverlays,
  });

  final EditDocument document;
  final ScreenshotTool tool;
  final Offset? dragStart;
  final Offset? dragCurrent;
  final EditAnnotation? previewAnnotation;
  final bool busy;
  final bool textInputOpen;
  final TextEditingController textController;
  final FocusNode textFocus;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDoubleTap;
  final VoidCallback onCommitText;
  final Widget toolbar;
  final List<_OcrOverlay> ocrOverlays;

  /// context 为布局上下文；返回按图片像素映射手势的编辑画布。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final imageSize = document.imageSize;
        final fitted = _fitRect(imageSize, constraints.biggest);
        Rect cropDisplay = _mapRect(document.cropRect, imageSize, fitted);
        if (tool == ScreenshotTool.crop &&
            dragStart != null &&
            dragCurrent != null) {
          cropDisplay = _mapRect(
            Rect.fromPoints(dragStart!, dragCurrent!),
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

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: fitted,
              child: GestureDetector(
                key: const Key('screenshot-canvas'),
                behavior: HitTestBehavior.opaque,
                onDoubleTap: textInputOpen ||
                        busy ||
                        tool == ScreenshotTool.text
                    ? null
                    : onDoubleTap,
                onPanStart: busy || textInputOpen
                    ? null
                    : (details) => onDragStart(toImage(details.localPosition)),
                onPanUpdate: busy || textInputOpen
                    ? null
                    : (details) =>
                        onDragUpdate(toImage(details.localPosition)),
                onPanEnd: busy || textInputOpen ? null : (_) => onDragEnd(),
                onTapDown: !textInputOpen &&
                        !busy &&
                        tool == ScreenshotTool.text
                    ? (details) => onDragStart(toImage(details.localPosition))
                    : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      document.sourcePng!,
                      fit: BoxFit.fill,
                      // 物理像素图按窗口 DPR 显示，避免 2x PNG 被缩到逻辑点再放大。
                      scale: MediaQuery.devicePixelRatioOf(context),
                      cacheWidth: document.width,
                      cacheHeight: document.height,
                      filterQuality: FilterQuality.none,
                      isAntiAlias: false,
                      gaplessPlayback: true,
                    ),
                    CustomPaint(
                      painter: _OverlayPainter(
                        annotations: document.annotations,
                        previewAnnotation: previewAnnotation,
                        imageSize: imageSize,
                      ),
                    ),
                    ...[
                      for (final overlay in ocrOverlays)
                        Positioned.fromRect(
                          rect: _mapRect(
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
            ),
            // 选区外的暗角用独立层，避免吞掉画布手势。
            IgnorePointer(
              child: CustomPaint(
                size: constraints.biggest,
                painter: _DimPainter(cropDisplay: cropDisplay),
              ),
            ),
            Positioned(
              left: cropDisplay.left.clamp(8, constraints.maxWidth - 8),
              top: (cropDisplay.bottom + 8)
                  .clamp(8, constraints.maxHeight - 72),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (constraints.maxWidth - 16).clamp(200, 640),
                ),
                child: toolbar,
              ),
            ),
            if (textInputOpen && dragStart != null)
              Positioned(
                left: _mapPoint(dragStart!, imageSize, fitted).dx,
                top: _mapPoint(dragStart!, imageSize, fitted).dy,
                width: 220,
                child: GestureDetector(
                  onDoubleTap: () {},
                  child: Material(
                    color: const Color(0xF0111111),
                    child: TextField(
                      key: const Key('screenshot-text-field'),
                      controller: textController,
                      focusNode: textFocus,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '输入文字，回车确认',
                        hintStyle: TextStyle(color: Colors.white54),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => onCommitText(),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 冻结帧窗口已与显示器对齐；铺满视口，避免 letterbox 黑边。
  static Rect _fitRect(Size image, Size viewport) => Offset.zero & viewport;

  static Rect _mapRect(Rect src, Size image, Rect fitted) {
    return Rect.fromLTRB(
      fitted.left + src.left / image.width * fitted.width,
      fitted.top + src.top / image.height * fitted.height,
      fitted.left + src.right / image.width * fitted.width,
      fitted.top + src.bottom / image.height * fitted.height,
    );
  }

  static Offset _mapPoint(Offset src, Size image, Rect fitted) {
    return Offset(
      fitted.left + src.dx / image.width * fitted.width,
      fitted.top + src.dy / image.height * fitted.height,
    );
  }
}

/// 选区外遮罩；只负责变暗，不参与命中。
class _DimPainter extends CustomPainter {
  _DimPainter({required this.cropDisplay});

  final Rect cropDisplay;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRect(cropDisplay)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = const Color(0x99000000));
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(cropDisplay, border);
    const handle = 6.0;
    final fill = Paint()..color = Colors.white;
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
      canvas.drawRect(
        Rect.fromCenter(center: point, width: handle, height: handle),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DimPainter oldDelegate) =>
      oldDelegate.cropDisplay != cropDisplay;
}

/// 在源图坐标系绘制已提交标注与拖拽预览。
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.annotations,
    required this.previewAnnotation,
    required this.imageSize,
  });

  final List<EditAnnotation> annotations;
  final EditAnnotation? previewAnnotation;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;
    canvas.save();
    canvas.scale(scaleX, scaleY);
    for (final annotation in annotations) {
      EditDocument.paintAnnotation(canvas, annotation);
    }
    if (previewAnnotation != null) {
      EditDocument.paintAnnotation(canvas, previewAnnotation!);
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
