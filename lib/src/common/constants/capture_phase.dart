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

/// 录制结果的导出类型；name 是 converting 阶段 exporting 详情的协议值，与 Swift RecordingExport 逐项对应（#110）。
enum RecordingExport {
  mp4,
  gif,
  apng;

  /// wire为原生协议值；返回对应导出类型，未知值直接抛错。
  static RecordingExport parse(String wire) => values.byName(wire);
}
