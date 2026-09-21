import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../common/constants/screenshot_enums.dart';

/// 单条标注；坐标一律为源图像素，缩放只影响显示变换。
class EditAnnotation {
  const EditAnnotation({
    required this.id,
    required this.kind,
    required this.bounds,
    this.start,
    this.end,
    this.points = const [],
    this.text = '',
    this.color = ScreenshotDefaults.strokeColor,
    this.strokeWidth = 3,
    this.fontSize = ScreenshotDefaults.fontSize,
  });

  /// 文档内唯一 id；预览用临时值，提交后由文档分配。
  final String id;

  /// 绘制与手势策略按 kind 分支。
  final AnnotationKind kind;
  // rect/mask/text 用 bounds；arrow 用 start/end；stroke 用 points。
  /// 源图像素包围盒；文字框可拉伸后写回这里。
  final Rect bounds;
  final Offset? start;
  final Offset? end;
  final List<Offset> points;
  final String text;
  final Color color;
  final double strokeWidth;
  final double fontSize;

  /// 返回替换字段后的新标注；历史只存不可变对象，避免共享可变引用。
  EditAnnotation copyWith({
    Rect? bounds,
    Offset? start,
    Offset? end,
    List<Offset>? points,
    String? text,
    Color? color,
    double? strokeWidth,
    double? fontSize,
  }) {
    return EditAnnotation(
      id: id,
      kind: kind,
      bounds: bounds ?? this.bounds,
      start: start ?? this.start,
      end: end ?? this.end,
      points: points ?? this.points,
      text: text ?? this.text,
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

/// 撤销/重做命令；只记录标注与裁剪差异，不克隆位图。
abstract class _EditCommand {
  /// document为目标文档；执行标注状态变更，无返回值。
  void apply(EditDocument document);
  /// document为目标文档；恢复命令执行前标注状态，无返回值。
  void revert(EditDocument document);
}

/// 新增标注命令；执行添加同一标注，撤销按稳定标识删除。
class _AddAnnotationCommand extends _EditCommand {
  /// annotation为不可变标注；构造命令不立即修改文档。
  _AddAnnotationCommand(this.annotation);

  final EditAnnotation annotation;

  @override
  void apply(EditDocument document) => document._annotations.add(annotation);

  @override
  void revert(EditDocument document) =>
      document._annotations.removeWhere((item) => item.id == annotation.id);
}

/// 修改标注命令；执行写入after，撤销恢复before。
class _UpdateAnnotationCommand extends _EditCommand {
  /// before/after为同id标注的前后状态；构造不立即修改文档。
  _UpdateAnnotationCommand(this.before, this.after);

  final EditAnnotation before;
  final EditAnnotation after;

  @override
  void apply(EditDocument document) => document._replaceAnnotation(after);

  @override
  void revert(EditDocument document) => document._replaceAnnotation(before);
}

/// 截图编辑文档：持有源 PNG、裁剪框与平铺标注，并合成导出位图。
class EditDocument extends ChangeNotifier {
  Uint8List? _sourcePng;
  int _width = 0;
  int _height = 0;
  Rect _crop = Rect.zero;
  final List<EditAnnotation> _annotations = <EditAnnotation>[];
  final List<_EditCommand> _undo = <_EditCommand>[];
  final List<_EditCommand> _redo = <_EditCommand>[];
  int _nextId = 0;

  /// 无参数；返回当前源 PNG，未加载时为 null。
  Uint8List? get sourcePng => _sourcePng;

  /// 无参数；返回源图像素宽。
  int get width => _width;

  /// 无参数；返回源图像素高。
  int get height => _height;

  /// 无参数；返回源图像素尺寸。
  Size get imageSize => Size(_width.toDouble(), _height.toDouble());

  /// 无参数；返回裁剪框（源图像素坐标）。
  Rect get cropRect => _crop;

  /// 无参数；返回当前标注只读视图。
  List<EditAnnotation> get annotations => List.unmodifiable(_annotations);

  /// 无参数；是否还能撤销。
  bool get canUndo => _undo.isNotEmpty;

  /// 无参数；是否还能重做。
  bool get canRedo => _redo.isNotEmpty;

  /// 无参数；是否已加载可编辑源图。
  bool get hasImage => _sourcePng != null && _width > 0 && _height > 0;

  /// bytes 为捕获 PNG，width/height 为真实像素；新捕获清空草稿与历史，无返回值。
  void loadCapture(Uint8List bytes, int width, int height) {
    _sourcePng = bytes;
    _width = width;
    _height = height;
    _crop = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    _annotations.clear();
    _undo.clear();
    _redo.clear();
    _nextId = 0;
    notifyListeners();
  }

  /// 无参数；清空源图与编辑状态，用于原生关闭会话，无返回值。
  void clear() {
    _sourcePng = null;
    _width = 0;
    _height = 0;
    _crop = Rect.zero;
    _annotations.clear();
    _undo.clear();
    _redo.clear();
    _nextId = 0;
    notifyListeners();
  }

  /// crop 为源图像素裁剪框；越界夹紧到图片内，不进入撤销栈。
  void setCrop(Rect crop) {
    if (!hasImage) return;
    final next = _clampCrop(crop);
    if (_nearlySameRect(next, _crop)) return;
    _crop = next;
    notifyListeners();
  }

  /// annotation 为新标注；空 id 时分配，加入列表并记入撤销栈，返回其 id。
  String addAnnotation(EditAnnotation annotation) {
    final withId = annotation.id.isEmpty
        ? EditAnnotation(
            id: _allocateId(),
            kind: annotation.kind,
            bounds: annotation.bounds,
            start: annotation.start,
            end: annotation.end,
            points: annotation.points,
            text: annotation.text,
            color: annotation.color,
            strokeWidth: annotation.strokeWidth,
            fontSize: annotation.fontSize,
          )
        : annotation;
    _push(_AddAnnotationCommand(withId));
    return withId.id;
  }

  /// annotation 为更新后的同 id 标注；找不到对应项时忽略，无返回值。
  void updateAnnotation(EditAnnotation annotation) {
    final index = _annotations.indexWhere((item) => item.id == annotation.id);
    if (index < 0) return;
    final before = _annotations[index];
    _push(_UpdateAnnotationCommand(before, annotation));
  }

  /// 无参数；撤销最近一次标注变更，无返回值。
  void undo() {
    if (_undo.isEmpty) return;
    final command = _undo.removeLast();
    command.revert(this);
    _redo.add(command);
    notifyListeners();
  }

  /// 无参数；重做最近一次撤销，无返回值。
  void redo() {
    if (_redo.isEmpty) return;
    final command = _redo.removeLast();
    command.apply(this);
    _undo.add(command);
    notifyListeners();
  }

  /// 无参数；按当前裁剪与标注合成 PNG；遮挡直接烤进像素，导出后不可还原原图。
  Future<Uint8List> renderPng() async {
    final sourceBytes = _sourcePng;
    if (sourceBytes == null || _width <= 0 || _height <= 0) {
      throw StateError('没有可导出的截图');
    }
    final codec = await ui.instantiateImageCodec(sourceBytes);
    final frame = await codec.getNextFrame();
    final source = frame.image;
    final crop = _clampCrop(_crop);
    final outWidth = crop.width.round().clamp(1, _width);
    final outHeight = crop.height.round().clamp(1, _height);
    final srcRect = Rect.fromLTWH(
      crop.left.roundToDouble(),
      crop.top.roundToDouble(),
      outWidth.toDouble(),
      outHeight.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final dst = Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble());
    // 1:1 像素拷贝关闭滤波；默认 medium 会在裁剪/导出时把锐边抹糊。
    canvas.drawImageRect(
      source,
      srcRect,
      dst,
      Paint()..filterQuality = ui.FilterQuality.none,
    );
    // 标注坐标相对源图；导出时平移到裁剪原点，并裁掉选区外笔划。
    canvas.save();
    canvas.clipRect(dst);
    canvas.translate(-srcRect.left, -srcRect.top);
    for (final annotation in _annotations) {
      _paintAnnotation(canvas, annotation);
    }
    canvas.restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(outWidth, outHeight);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    source.dispose();
    if (data == null) throw StateError('无法编码截图 PNG');
    return data.buffer.asUint8List();
  }

  /// canvas 为绘制目标，annotation 为源图像素坐标下的标注；无返回值。
  static void paintAnnotation(Canvas canvas, EditAnnotation annotation) {
    _paintAnnotation(canvas, annotation);
  }

  /// command为编辑命令；执行并入撤销栈，清空重做栈并通知监听者，无返回值。
  void _push(_EditCommand command) {
    command.apply(this);
    _undo.add(command);
    _redo.clear();
    notifyListeners();
  }

  /// annotation为既有id的新状态；找到时原位替换，找不到则不修改，无返回值。
  void _replaceAnnotation(EditAnnotation annotation) {
    final index = _annotations.indexWhere((item) => item.id == annotation.id);
    if (index < 0) return;
    _annotations[index] = annotation;
  }

  /// 无参数；递增计数并返回文档内唯一标注id。
  String _allocateId() {
    _nextId += 1;
    return 'a$_nextId';
  }

  /// crop为源图像素坐标候选框；返回夹紧到图像边界且至少1像素的框，不改变状态。
  Rect _clampCrop(Rect crop) {
    final left = crop.left.clamp(0, _width.toDouble()).toDouble();
    final top = crop.top.clamp(0, _height.toDouble()).toDouble();
    final right = crop.right.clamp(left + 1, _width.toDouble()).toDouble();
    final bottom = crop.bottom.clamp(top + 1, _height.toDouble()).toDouble();
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// a/b为像素坐标裁剪框；返回四边差值是否均小于半像素，避免无意义通知。
  static bool _nearlySameRect(Rect a, Rect b) {
    return (a.left - b.left).abs() < 0.5 &&
        (a.top - b.top).abs() < 0.5 &&
        (a.right - b.right).abs() < 0.5 &&
        (a.bottom - b.bottom).abs() < 0.5;
  }

  /// canvas为源图坐标目标，annotation为标注；按类型绘制导出像素，不改变文档，无返回值。
  static void _paintAnnotation(Canvas canvas, EditAnnotation annotation) {
    switch (annotation.kind) {
      case AnnotationKind.rectangle:
        final paint = Paint()
          ..color = annotation.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = annotation.strokeWidth
          ..isAntiAlias = false;
        canvas.drawRect(annotation.bounds, paint);
      case AnnotationKind.mask:
        // 纯色遮挡必须不透明填充，导出后无法通过“去掉对象”恢复原像素。
        final paint = Paint()
          ..color = annotation.color.withValues(alpha: 1)
          ..style = PaintingStyle.fill
          ..isAntiAlias = false;
        canvas.drawRect(annotation.bounds, paint);
      case AnnotationKind.arrow:
        final start = annotation.start;
        final end = annotation.end;
        if (start == null || end == null) return;
        final paint = Paint()
          ..color = annotation.color
          ..strokeWidth = annotation.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = false;
        canvas.drawLine(start, end, paint);
        final direction = end - start;
        if (direction.distance < 1) return;
        final unit = direction / direction.distance;
        final tipSize = 8 + annotation.strokeWidth * 2;
        final left = end - unit * tipSize + _perp(unit) * (tipSize * 0.45);
        final right = end - unit * tipSize - _perp(unit) * (tipSize * 0.45);
        final tip = Paint()
          ..color = annotation.color
          ..style = PaintingStyle.fill;
        final path = Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(left.dx, left.dy)
          ..lineTo(right.dx, right.dy)
          ..close();
        canvas.drawPath(path, tip);
      case AnnotationKind.stroke:
        if (annotation.points.length < 2) return;
        final paint = Paint()
          ..color = annotation.color
          ..strokeWidth = annotation.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true;
        final path = Path()
          ..moveTo(annotation.points.first.dx, annotation.points.first.dy);
        for (final point in annotation.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      case AnnotationKind.text:
        final builder =
            ui.ParagraphBuilder(
                ui.ParagraphStyle(fontSize: annotation.fontSize),
              )
              ..pushStyle(
                ui.TextStyle(
                  color: annotation.color,
                  fontSize: annotation.fontSize,
                ),
              )
              ..addText(annotation.text.isEmpty ? ' ' : annotation.text);
        final paragraph = builder.build()
          ..layout(
            ui.ParagraphConstraints(
              width: annotation.bounds.width.clamp(1, 4000).toDouble(),
            ),
          );
        canvas.drawParagraph(paragraph, annotation.bounds.topLeft);
    }
  }

  /// unit为单位方向；返回逆时针垂直向量，供箭头顶点计算，不改变输入。
  static Offset _perp(Offset unit) => Offset(-unit.dy, unit.dx);
}
