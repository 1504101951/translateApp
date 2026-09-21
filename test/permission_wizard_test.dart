import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/permission_enums.dart';
import 'package:translate_app/src/common/utils/permission_utils.dart';

/// 无参数；验证首次授权向导的下一步决策，不点击系统 TCC。
void main() {
  test('未授权时先辅助功能，再屏幕录制；都授权才结束', () {
    // 冷启动两项都缺：从辅助功能开始。
    expect(
      permissionWizardStep(
        accessibilityGranted: false,
        screenRecordingGranted: false,
      ),
      PermissionWizardStep.accessibility,
    );
    expect(
      permissionWizardStep(
        accessibilityGranted: true,
        screenRecordingGranted: false,
      ),
      PermissionWizardStep.screenRecording,
    );
    expect(
      permissionWizardStep(
        accessibilityGranted: true,
        screenRecordingGranted: true,
      ),
      PermissionWizardStep.done,
    );
    // 稍后只关窗口；缺权限时下一步仍是辅助功能，不能当成已完成。
    expect(
      permissionWizardStep(
        accessibilityGranted: false,
        screenRecordingGranted: false,
      ),
      PermissionWizardStep.accessibility,
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
