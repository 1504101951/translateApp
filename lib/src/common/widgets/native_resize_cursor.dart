import 'package:flutter/services.dart';

import '../constants/method_names.dart';

/// macOS原生对角双向光标；Flutter macOS引擎未映射这两种系统光标。
/// channel是当前截图引擎的通道，direction只接受下面两个轴常量。
class NativeResizeCursor extends MouseCursor {
  const NativeResizeCursor(this.direction, {required this.channel});

  static const northWestSouthEast = 'nwse';
  static const northEastSouthWest = 'nesw';
  final String direction;
  final MethodChannel channel;

  /// device为框架指针ID；返回跟随MouseRegion命中生命周期的原生会话。
  @override
  MouseCursorSession createSession(int device) =>
      _NativeResizeCursorSession(this, device);

  /// 无参数；返回便于诊断的原生光标轴名。
  @override
  String get debugDescription => 'native-resize-$direction';

  /// other为当前光标；同轴同引擎无需在每次鼠标移动时重复激活。
  @override
  bool operator ==(Object other) =>
      other is NativeResizeCursor &&
      other.direction == direction &&
      other.channel.name == channel.name;

  @override
  int get hashCode => Object.hash(direction, channel.name);
}

/// 生命周期由Flutter鼠标追踪管理，横纵、文本和按钮光标仍使用原有系统会话。
class _NativeResizeCursorSession extends MouseCursorSession {
  _NativeResizeCursorSession(NativeResizeCursor super.cursor, super.device);

  /// 无参数；仅激活时请求AppKit光标，不独立监听鼠标或修改命中区域。
  @override
  Future<void> activate() {
    final resizeCursor = cursor as NativeResizeCursor;
    return resizeCursor.channel.invokeMethod<void>(
      MethodNames.setResizeCursor,
      {'direction': resizeCursor.direction},
    );
  }

  /// 无参数；下一会话负责设置新光标，避免异步复位覆盖新方向或按钮光标。
  @override
  void dispose() {}
}
