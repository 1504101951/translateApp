/// accessibilityGranted / screenRecordingGranted 为本进程当前授权。
/// 两项都有才能点「进入应用」。
bool canEnterApp({
  required bool accessibilityGranted,
  required bool screenRecordingGranted,
}) {
  return accessibilityGranted && screenRecordingGranted;
}
