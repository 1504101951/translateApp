/// 平台通道协议；与Swift对应值保持一致，调用方不重复定义。
abstract final class ChannelNames {
  /// 连续采集与媒体输出的独立窗口通道。
  static const capture = 'translateapp/capture';

  /// 录制结果中的系统播放器视图。
  static const captureVideoPreview = 'translateapp/capture_video_preview';

  /// translateapp/appearance 的稳定协议值，变更须同步两端及持久化调用方。
  static const appearance = 'translateapp/appearance';

  /// translateapp/macos 的稳定协议值，变更须同步两端及持久化调用方。
  static const macos = 'translateapp/macos';

  /// translateapp/macos/events 的稳定协议值，变更须同步两端及持久化调用方。
  static const macosEvents = 'translateapp/macos/events';

  /// translateapp/screenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const screenshot = 'translateapp/screenshot';

  /// translateapp/settings 的稳定协议值，变更须同步两端及持久化调用方。
  static const settings = 'translateapp/settings';
}
