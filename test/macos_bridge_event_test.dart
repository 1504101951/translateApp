import 'package:translate_app/src/common/constants/selection_gesture_types.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/bridge_event_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/platform/macos_bridge_event.dart';

void main() {
  test('parses selectionCaptured with sessionId', () {
    final event = MacosBridgeEvent.fromMap({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 's1',
      'text': 'hello',
      'gesture': SelectionGestureTypes.drag,
      'x': 10,
      'y': 20,
    });
    expect(event, isA<SelectionCaptured>());
    final captured = event as SelectionCaptured;
    expect(captured.sessionId, 's1');
    expect(captured.text, 'hello');
    expect(captured.gesture, SelectionGestureTypes.drag);
    expect(captured.x, 10);
    expect(captured.y, 20);
  });

  test('parses escapePressed', () {
    final event = MacosBridgeEvent.fromMap({
      'type': MethodNames.escapePressed,
      'sessionId': 's2',
    });
    expect(event, isA<EscapePressed>());
    expect(event.sessionId, 's2');
  });

  test('overlay session gate drops stale ids', () {
    final gate = OverlaySessionGate();
    expect(gate.accept('s1'), isFalse);
    gate.begin('s1');
    expect(gate.accept('s1'), isTrue);
    expect(gate.accept('old'), isFalse);
    gate.clear();
    expect(gate.accept('s1'), isFalse);
  });
}
