import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/utils/permission_utils.dart';

/// 无参数；验证两项权限齐备才允许进入应用，不点击系统TCC。
void main() {
  test('只有两项权限均授权才允许进入应用', () {
    // 两项权限有四种组合；缺少任一项都不能完成向导。
    expect(
      canEnterApp(accessibilityGranted: false, screenRecordingGranted: false),
      isFalse,
    );
    expect(
      canEnterApp(accessibilityGranted: true, screenRecordingGranted: false),
      isFalse,
    );
    expect(
      canEnterApp(accessibilityGranted: false, screenRecordingGranted: true),
      isFalse,
    );
    expect(
      canEnterApp(accessibilityGranted: true, screenRecordingGranted: true),
      isTrue,
    );
  });
}
