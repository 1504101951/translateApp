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

  /// sessionId 绑定当前选区；明确点击翻译后补读格式，返回原文，失效时返回 null。
  Future<String?> readSelectionForTranslation({required String sessionId}) {
    return _methods.invokeMethod<String>('readSelectionForTranslation', {
      'sessionId': sessionId,
    });
  }

  /// 让 Swift 上报一条探测用选区事件，验证通道而不是实现 #2。
  Future<void> probeEmitSelection() {
    return _methods.invokeMethod<void>('probeEmitSelection');
  }

  /// 无参数；返回 UserDefaults 偏好及 macOS 首选语言。
  Future<Map<Object?, Object?>> loadSettings() async =>
      (await _methods.invokeMapMethod<Object?, Object?>('loadSettings'))!;

  /// settings 为经 Dart 校验的偏好字典；成功保存并应用系统能力后完成。
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  }) => _methods.invokeMethod<void>('applySettings', {
    'settings': settings,
    'credentials': credentials,
  });

  /// id 为服务账户；返回仅在主引擎内存使用的凭据字典，不写入偏好。
  Future<Map<String, String>> readCredentials(String id) async =>
      (await _methods.invokeMapMethod<String, String>('readCredentials', {
        'id': id,
      }))!;

  /// ids 为服务账户列表；返回已保存凭据的账户 ID，不返回密钥。
  Future<List<String>> credentialIds(List<String> ids) async =>
      (await _methods.invokeListMethod<String>('credentialIds', {'ids': ids}))!;

  /// handler 处理设置窗口及菜单请求；响应来自主 Dart 实例，避免双引擎状态分叉。
  void handleSettings(Future<Object?> Function(MethodCall) handler) =>
      _methods.setMethodCallHandler(handler);

  /// text 为待翻译原文；返回设备识别的 BCP-47 语言或 null，不联网。
  Future<String?> detectLanguage(String text) =>
      _methods.invokeMethod<String>('detectLanguage', {'text': text});

  /// 无参数；通知原生首次启动界面可用，Future 在窗口调度后完成。
  Future<void> appReady() => _methods.invokeMethod<void>('appReady');
}
