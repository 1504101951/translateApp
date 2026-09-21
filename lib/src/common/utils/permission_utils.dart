import '../constants/permission_enums.dart';

/// accessibilityGranted / screenRecordingGranted 为本进程当前授权。
/// 返回下一步；两项都授权才是 done，缺哪项停哪项。
PermissionWizardStep permissionWizardStep({
  required bool accessibilityGranted,
  required bool screenRecordingGranted,
}) {
  if (accessibilityGranted && screenRecordingGranted) {
    return PermissionWizardStep.done;
  }
  if (!accessibilityGranted) return PermissionWizardStep.accessibility;
  return PermissionWizardStep.screenRecording;
}

/// accessibilityGranted / screenRecordingGranted 为本进程当前授权。
/// 两项都有才能点「进入应用」。
bool canEnterApp({
  required bool accessibilityGranted,
  required bool screenRecordingGranted,
}) {
  return accessibilityGranted && screenRecordingGranted;
}
