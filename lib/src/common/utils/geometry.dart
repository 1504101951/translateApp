import 'dart:ui';

/// points 为点列；返回包围盒，单点时给 1px 以免空矩形。
Rect boundsForPoints(List<Offset> points) {
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
  return Rect.fromLTRB(
    minX,
    minY,
    maxX == minX ? minX + 1 : maxX,
    maxY == minY ? minY + 1 : maxY,
  );
}

/// src 为源图像素矩形，image 为源图尺寸，fitted 为显示矩形。
/// 返回映射到显示坐标的矩形。
Rect mapRectToFitted(Rect src, Size image, Rect fitted) {
  return Rect.fromLTRB(
    fitted.left + src.left / image.width * fitted.width,
    fitted.top + src.top / image.height * fitted.height,
    fitted.left + src.right / image.width * fitted.width,
    fitted.top + src.bottom / image.height * fitted.height,
  );
}

/// src 为源图像素点，image 为源图尺寸，fitted 为显示矩形。
/// 返回映射到显示坐标的点。
Offset mapPointToFitted(Offset src, Size image, Rect fitted) {
  return Offset(
    fitted.left + src.dx / image.width * fitted.width,
    fitted.top + src.dy / image.height * fitted.height,
  );
}

/// crop 为源图像素裁剪框（左上原点），display 为 AppKit 屏幕矩形，image 为冻结帧像素尺寸。
/// 返回选区左下角的 AppKit 点，贴图钉在选区而不是指针处。
Offset pinOriginAppKit({
  required Rect crop,
  required Rect display,
  required Size image,
}) {
  final scaleX = display.width / image.width;
  final scaleY = display.height / image.height;
  return Offset(
    display.left + crop.left * scaleX,
    display.top + (image.height - crop.bottom) * scaleY,
  );
}

/// bounds/point 为同一坐标系；pad 为控制点命中半径，edgePad 为边线半宽。
/// 返回 nw/n/ne/e/se/s/sw/w/move，未命中为 null。角优先于边，边优先于框内。
String? editHandleAt(Rect bounds, Offset point, double pad, {double? edgePad}) {
  final edge = edgePad ?? pad;
  final corners = <String, Offset>{
    'nw': bounds.topLeft,
    'ne': bounds.topRight,
    'sw': bounds.bottomLeft,
    'se': bounds.bottomRight,
  };
  for (final entry in corners.entries) {
    if ((entry.value.dx - point.dx).abs() <= pad &&
        (entry.value.dy - point.dy).abs() <= pad) {
      return entry.key;
    }
  }
  final edges = <String, Offset>{
    'n': bounds.topCenter,
    's': bounds.bottomCenter,
    'w': bounds.centerLeft,
    'e': bounds.centerRight,
  };
  for (final entry in edges.entries) {
    if ((entry.value.dx - point.dx).abs() <= pad &&
        (entry.value.dy - point.dy).abs() <= pad) {
      return entry.key;
    }
  }
  if ((point.dy - bounds.top).abs() <= edge &&
      point.dx >= bounds.left &&
      point.dx <= bounds.right) {
    return 'n';
  }
  if ((point.dy - bounds.bottom).abs() <= edge &&
      point.dx >= bounds.left &&
      point.dx <= bounds.right) {
    return 's';
  }
  if ((point.dx - bounds.left).abs() <= edge &&
      point.dy >= bounds.top &&
      point.dy <= bounds.bottom) {
    return 'w';
  }
  if ((point.dx - bounds.right).abs() <= edge &&
      point.dy >= bounds.top &&
      point.dy <= bounds.bottom) {
    return 'e';
  }
  if (bounds.contains(point)) return 'move';
  return null;
}
