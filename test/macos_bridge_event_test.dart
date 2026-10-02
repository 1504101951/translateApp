import 'package:translate_app/src/common/constants/selection_gesture_types.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/bridge_event_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/platform/macos_bridge_event.dart';

/// 无参数；验证原生事件到Dart事件的字段转换，不创建或修改翻译会话。
void main() {
  test('parses selectionCaptured with sessionId', () {
    // 原生事件携带会话、手势与坐标，解析结果必须保留这些业务字段。
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
    // Escape事件仍携带所属会话，供实际调用方拒绝过期关闭请求。
    final event = MacosBridgeEvent.fromMap({
      'type': MethodNames.escapePressed,
      'sessionId': 's2',
    });
    expect(event, isA<EscapePressed>());
    expect(event.sessionId, 's2');
  });
}
