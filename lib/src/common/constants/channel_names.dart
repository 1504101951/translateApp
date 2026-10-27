/// Dart 使用的平台通道名协议值；与 Swift AppConstants 同名值字面量一致，改名须两端同步。
abstract final class ChannelNames {
  /// 连续采集与媒体输出的独立窗口通道。
  static const capture = 'translateapp/capture';

  /// 录制结果中的系统播放器视图。
  static const captureVideoPreview = 'translateapp/capture_video_preview';

  static const appearance = 'translateapp/appearance';

  static const macos = 'translateapp/macos';

  static const macosEvents = 'translateapp/macos/events';

  static const screenshot = 'translateapp/screenshot';

  static const settings = 'translateapp/settings';
}
