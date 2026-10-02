import '../common/constants/method_names.dart';
import '../common/constants/channel_names.dart';

import 'package:flutter/services.dart';

import 'macos_bridge_event.dart';
import 'settings_platform.dart';

/// Dart 侧平台通道客户端。不包含翻译业务。
class MacosPlatformBridge implements SettingsPlatform {
  /// methods/events为可注入通道，省略时使用macOS默认通道；构造不发起原生调用。
  MacosPlatformBridge({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(ChannelNames.macos),
      _events = events ?? const EventChannel(ChannelNames.macosEvents);

  final MethodChannel _methods;
  final EventChannel _events;

  /// 无参数；返回Swift广播字典解析后的事件流，不改变选区会话。
  Stream<MacosBridgeEvent> get events =>
      _events.receiveBroadcastStream().map((raw) {
        final map = Map<Object?, Object?>.from(raw as Map);
        return MacosBridgeEvent.fromMap(map);
      });

  /// 通知现有历史窗口重载；无参数，返回原生转发完成的Future。
  Future<void> notifyHistoryChanged() =>
      _methods.invokeMethod<void>(MethodNames.historyChanged);

  /// sessionId绑定会话，x/y为屏幕锚点，width/height为逻辑尺寸；请求显示定位，返回操作完成的Future。
  Future<void> showOverlay({
    required String sessionId,
    required double x,
    required double y,
    double width = 240,
    double height = 140,
  }) {
    return _methods.invokeMethod<void>(MethodNames.showOverlay, {
      'sessionId': sessionId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
    });
  }

  /// sessionId标识待隐藏浮层；只隐藏对应会话窗口，返回原生操作完成的Future。
  Future<void> hideOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>(MethodNames.hideOverlay, {
      'sessionId': sessionId,
    });
  }

  /// sessionId 为即将展开的会话；保留原生窗口至显式关闭，返回命令完成的 Future。
  Future<void> retainOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>(MethodNames.retainOverlay, {
      'sessionId': sessionId,
    });
  }

  /// sessionId标识目标窗口，width/height为逻辑尺寸；请求调整大小，返回原生操作完成的Future。
  Future<void> setOverlaySize({
    required String sessionId,
    required double width,
    required double height,
  }) {
    return _methods.invokeMethod<void>(MethodNames.setOverlaySize, {
      'sessionId': sessionId,
      'width': width,
      'height': height,
    });
  }

  /// 拖动当前浮层；sessionId 标识会话，返回原生拖动完成的 Future。
  Future<void> dragOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>(MethodNames.dragOverlay, {
      'sessionId': sessionId,
    });
  }

  /// sessionId 绑定当前选区；明确点击翻译后补读格式，返回原文，失效时返回 null。
  Future<String?> readSelectionForTranslation({required String sessionId}) {
    return _methods.invokeMethod<String>(
      MethodNames.readSelectionForTranslation,
      {'sessionId': sessionId},
    );
  }

  /// 让 Swift 上报一条探测用选区事件，验证通道而不是实现 #2。
  Future<void> probeEmitSelection() {
    return _methods.invokeMethod<void>(MethodNames.probeEmitSelection);
  }

  /// 无参数；返回 UserDefaults 偏好及 macOS 首选语言。
  Future<Map<Object?, Object?>> loadSettings() async => (await _methods
      .invokeMapMethod<Object?, Object?>(MethodNames.loadSettings))!;

  /// 无参数；返回应用支持目录路径，供 SQLite 历史库使用。
  Future<String> applicationSupportPath() async => (await _methods
      .invokeMethod<String>(MethodNames.applicationSupportPath))!;

  /// captureId 为 OCR 发起时的截图 ID；返回原生截图是否仍存在且未被替换。
  Future<bool> isCurrentScreenshot(String captureId) async => (await _methods
      .invokeMethod<bool>(MethodNames.isCurrentScreenshot, {'id': captureId}))!;

  /// settings 为经 Dart 校验的偏好字典；成功保存并应用系统能力后完成。
  @override
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  }) => _methods.invokeMethod<void>(MethodNames.applySettings, {
    'settings': settings,
    'credentials': credentials,
  });

  /// id 为服务账户；返回仅在主引擎内存使用的凭据字典，不写入偏好。
  @override
  Future<Map<String, String>> readCredentials(String id) async =>
      (await _methods.invokeMapMethod<String, String>(
        MethodNames.readCredentials,
        {'id': id},
      ))!;

  /// ids 为服务账户列表；返回已保存凭据的账户 ID，不返回密钥。
  @override
  Future<List<String>> credentialIds(List<String> ids) async => (await _methods
      .invokeListMethod<String>(MethodNames.credentialIds, {'ids': ids}))!;

  /// handler路由跨窗口业务请求；设置、翻译与历史由主引擎对应模块处理，无返回值。
  void handleApplicationRequests(
    Future<Object?> Function(MethodCall) handler,
  ) => _methods.setMethodCallHandler(handler);

  /// text 为待翻译原文；返回设备识别的 BCP-47 语言或 null，不联网。
  Future<String?> detectLanguage(String text) =>
      _methods.invokeMethod<String>(MethodNames.detectLanguage, {'text': text});

  /// 无参数；通知原生首次启动界面可用，Future 在窗口调度后完成。
  Future<void> appReady() => _methods.invokeMethod<void>(MethodNames.appReady);
}
