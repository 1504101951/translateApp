/// 系统事件协议；与Swift对应值保持一致，调用方不重复定义。
abstract final class BridgeEventTypes {
  /// selectionCaptured 的稳定协议值，变更须同步两端及持久化调用方。
  static const selectionCaptured = 'selectionCaptured';

  /// selectionInvalidated 的稳定协议值，变更须同步两端及持久化调用方。
  static const selectionInvalidated = 'selectionInvalidated';
}
