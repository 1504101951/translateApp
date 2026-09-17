/// 首次启动逐步授权的决策；不读写 TCC，只根据当前授权决定下一步。
enum PermissionWizardStep { accessibility, screenRecording, done }

/// accessibilityGranted / screenRecordingGranted 为本进程当前授权。
/// 返回下一步；缺哪项就停在哪项，稍后跳过不能当成已授权。
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
