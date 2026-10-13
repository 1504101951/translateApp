/// 翻译输入的长度上限，单位为字素。
abstract final class TextLimits {
  /// 一次翻译可携带的原文上限；超过时只在本地提示，不发送网络请求。
  static const translationInput = 50000;
}
