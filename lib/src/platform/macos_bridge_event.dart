import '../common/constants/method_names.dart';
import '../common/constants/bridge_event_types.dart';

/// Swift 桥上报的事件。所有事件携带 sessionId，过期 Session 直接丢弃。
sealed class MacosBridgeEvent {
  /// sessionId标识所属原生会话；构造供路由过滤过期事件的基类。
  const MacosBridgeEvent({required this.sessionId});

  final String sessionId;

  /// map为Swift事件字典；按type解析事件，未知类型返回UnknownBridgeEvent，不改变门控状态。
  factory MacosBridgeEvent.fromMap(Map<Object?, Object?> map) {
    final type = map['type'] as String? ?? '';
    final sessionId = map['sessionId'] as String? ?? '';
    switch (type) {
      case BridgeEventTypes.selectionCaptured:
        return SelectionCaptured(
          sessionId: sessionId,
          text: map['text'] as String? ?? '',
          gesture: map['gesture'] as String? ?? '',
          sourceAppName: map['sourceAppName'] as String?,
          x: (map['x'] as num?)?.toDouble() ?? 0,
          y: (map['y'] as num?)?.toDouble() ?? 0,
        );
      case BridgeEventTypes.selectionInvalidated:
        return SelectionInvalidated(sessionId: sessionId);
      case MethodNames.escapePressed:
        return EscapePressed(sessionId: sessionId);
      default:
        return UnknownBridgeEvent(sessionId: sessionId, type: type);
    }
  }
}

/// 已捕获选区事件；携带原文、手势、来源和锚点，供会话创建或替换。
final class SelectionCaptured extends MacosBridgeEvent {
  /// sessionId标识选区，text为原文，gesture为触发方式，x/y为锚点，sourceAppName为可选来源；构造不可变事件。
  const SelectionCaptured({
    required super.sessionId,
    required this.text,
    required this.gesture,
    required this.x,
    required this.y,
    this.sourceAppName,
  });

  final String text;
  final String gesture;
  final double x;
  final double y;

  /// 捕获选区时的应用显示名；不使用翻译完成时可能已经切换的前台应用。
  final String? sourceAppName;
}

/// 原生选区失效事件；仅针对sessionId对应的未展开会话。
final class SelectionInvalidated extends MacosBridgeEvent {
  /// sessionId标识失效选区；构造事件，由路由方决定清理。
  const SelectionInvalidated({required super.sessionId});
}

/// 原生Escape事件；通知路由关闭对应会话的触发按钮或结果卡片。
final class EscapePressed extends MacosBridgeEvent {
  /// sessionId标识按键所属会话；构造事件本身不取消请求。
  const EscapePressed({required super.sessionId});
}

/// 未知协议事件；保留原始类型，供调用方安全忽略。
final class UnknownBridgeEvent extends MacosBridgeEvent {
  /// sessionId为所属会话，type为未知类型；构造事件不改变现有状态。
  const UnknownBridgeEvent({required super.sessionId, required this.type});

  final String type;
}

/// 只接受当前 sessionId 的指令，避免过期 Overlay 命令生效。
class OverlaySessionGate {
  String? currentSessionId;

  /// sessionId为待处理命令会话；返回是否与当前会话一致，不改变门控状态。
  bool accept(String sessionId) {
    return currentSessionId != null && currentSessionId == sessionId;
  }

  /// sessionId为新接管浮层的会话；将其设为唯一可接受身份，无返回值。
  void begin(String sessionId) {
    currentSessionId = sessionId;
  }

  /// 无参数；清除当前身份，后续命令全部拒绝，直到新会话接管，无返回值。
  void clear() {
    currentSessionId = null;
  }
}
