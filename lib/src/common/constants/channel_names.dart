/// 平台通道协议；与Swift对应值保持一致，调用方不重复定义。
abstract final class ChannelNames {
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
