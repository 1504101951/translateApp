import 'package:flutter/services.dart';

import '../constants/method_names.dart';

/// 画笔的原生圆点光标；Flutter macOS引擎不支持自绘光标图像。
/// channel是当前截图引擎的通道；diameter为圆点直径（屏幕点）；
/// color为画笔颜色的ARGB值，null表示没有颜色的马赛克画笔，显示空心圆。
class NativeBrushCursor extends MouseCursor {
  const NativeBrushCursor({
    required this.diameter,
    required this.color,
    required this.channel,
  });

  /// 圆点的最小直径（屏幕点）；细画笔不低于这个尺寸，保证看得见。
  static const minimumDiameter = 6.0;
  final double diameter;
  final int? color;
  final MethodChannel channel;

  /// device为框架指针ID；返回跟随MouseRegion命中生命周期的原生会话。
  @override
  MouseCursorSession createSession(int device) =>
      _NativeBrushCursorSession(this, device);

  /// 无参数；返回便于诊断的光标描述。
  @override
  String get debugDescription => 'native-brush-$diameter-$color';

  /// other为当前光标；直径、颜色和引擎都相同时无需重复激活。
  @override
  bool operator ==(Object other) =>
      other is NativeBrushCursor &&
      other.diameter == diameter &&
      other.color == color &&
      other.channel.name == channel.name;

  @override
  int get hashCode => Object.hash(diameter, color, channel.name);
}

/// 生命周期由Flutter鼠标追踪管理。
class _NativeBrushCursorSession extends MouseCursorSession {
  _NativeBrushCursorSession(NativeBrushCursor super.cursor, super.device);

  /// 无参数；激活时请求AppKit绘制并设置圆点光标。
  @override
  Future<void> activate() {
    final brush = cursor as NativeBrushCursor;
    return brush.channel.invokeMethod<void>(MethodNames.setBrushCursor, {
      'diameter': brush.diameter,
      'color': brush.color,
    });
  }

  /// 无参数；下一会话负责设置新光标，避免异步复位覆盖新光标。
  @override
  void dispose() {}
}
