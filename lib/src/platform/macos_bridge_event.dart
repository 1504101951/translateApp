/// Swift 桥上报的事件。所有事件携带 sessionId，过期 Session 直接丢弃。
sealed class MacosBridgeEvent {
  const MacosBridgeEvent({required this.sessionId});

  final String sessionId;

  factory MacosBridgeEvent.fromMap(Map<Object?, Object?> map) {
    final type = map['type'] as String? ?? '';
    final sessionId = map['sessionId'] as String? ?? '';
    switch (type) {
      case 'selectionCaptured':
        return SelectionCaptured(
          sessionId: sessionId,
          text: map['text'] as String? ?? '',
          gesture: map['gesture'] as String? ?? '',
          x: (map['x'] as num?)?.toDouble() ?? 0,
          y: (map['y'] as num?)?.toDouble() ?? 0,
        );
      case 'selectionInvalidated':
        return SelectionInvalidated(sessionId: sessionId);
      case 'escapePressed':
        return EscapePressed(sessionId: sessionId);
      default:
        return UnknownBridgeEvent(sessionId: sessionId, type: type);
    }
  }
}

final class SelectionCaptured extends MacosBridgeEvent {
  const SelectionCaptured({
    required super.sessionId,
    required this.text,
    required this.gesture,
    required this.x,
    required this.y,
  });

  final String text;
  final String gesture;
  final double x;
  final double y;
}

final class SelectionInvalidated extends MacosBridgeEvent {
  const SelectionInvalidated({required super.sessionId});
}

final class EscapePressed extends MacosBridgeEvent {
  const EscapePressed({required super.sessionId});
}

final class UnknownBridgeEvent extends MacosBridgeEvent {
  const UnknownBridgeEvent({required super.sessionId, required this.type});

  final String type;
}

/// 只接受当前 sessionId 的指令，避免过期 Overlay 命令生效。
class OverlaySessionGate {
  String? currentSessionId;

  bool accept(String sessionId) {
    return currentSessionId != null && currentSessionId == sessionId;
  }

  void begin(String sessionId) {
    currentSessionId = sessionId;
  }

  void clear() {
    currentSessionId = null;
  }
}
