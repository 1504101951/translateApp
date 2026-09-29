/// 采集窗口可见状态；原生资源回调与Dart界面共享这些协议值。
enum CapturePhase {
  idle,
  preparing,
  recording,
  pausing,
  paused,
  finalizing,
  videoReady,
  scrolling,
  imageReady,
  converting,
  failed;

  /// wire为原生协议值；返回对应状态，未知值直接抛错，避免显示错误成功状态。
  static CapturePhase parse(String wire) => values.byName(wire);
}
