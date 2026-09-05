import 'package:flutter/services.dart';

import 'macos_bridge_event.dart';

/// Dart 侧平台通道客户端。不包含翻译业务。
class MacosPlatformBridge {
  MacosPlatformBridge({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('translateapp/macos'),
      _events = events ?? const EventChannel('translateapp/macos/events');

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<MacosBridgeEvent> get events =>
      _events.receiveBroadcastStream().map((raw) {
        final map = Map<Object?, Object?>.from(raw as Map);
        return MacosBridgeEvent.fromMap(map);
      });

  Future<void> showOverlay({
    required String sessionId,
    required double x,
    required double y,
    double width = 240,
    double height = 140,
  }) {
    return _methods.invokeMethod<void>('showOverlay', {
      'sessionId': sessionId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
    });
  }

  Future<void> hideOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>('hideOverlay', {'sessionId': sessionId});
  }

  Future<void> setOverlaySize({
    required String sessionId,
    required double width,
    required double height,
  }) {
    return _methods.invokeMethod<void>('setOverlaySize', {
      'sessionId': sessionId,
      'width': width,
      'height': height,
    });
  }

  /// 拖动当前浮层；sessionId 标识会话，返回原生拖动完成的 Future。
  Future<void> dragOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>('dragOverlay', {'sessionId': sessionId});
  }

  /// 让 Swift 上报一条探测用选区事件，验证通道而不是实现 #2。
  Future<void> probeEmitSelection() {
    return _methods.invokeMethod<void>('probeEmitSelection');
  }
}
