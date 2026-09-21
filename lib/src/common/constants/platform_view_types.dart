/// 原生平台视图类型；与Swift对应值保持一致，调用方不重复定义。
abstract final class PlatformViewTypes {
  /// translateapp/native-glass 的稳定协议值，变更须同步两端及持久化调用方。
  static const nativeGlass = 'translateapp/native-glass';
}
