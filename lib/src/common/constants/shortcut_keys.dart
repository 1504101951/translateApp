/// 全局快捷键的 Carbon 修饰键位与键码；与 Swift 使用的 Carbon cmdKey/shiftKey/optionKey/controlKey 及 AppConstants.escapeKeyCode 一致（#131）。
abstract final class ShortcutKeys {
  static const command = 256;
  static const shift = 512;
  static const option = 2048;
  static const control = 4096;

  /// 组合必须至少包含其中一个：Control、Option 或 Command。
  static const required = command | option | control;

  /// 组合只允许出现的修饰键：Control、Option、Command 与 Shift。
  static const allowed = required | shift;

  /// Esc 保留给取消录制，不能作为快捷键主键。
  static const escape = 53;

  /// 注册接口接受的最大键码。
  static const maxKeyCode = 127;

  /// 组合不满足上述规则时的提示，与 Swift 注册校验同一文案。
  static const invalidMessage =
      '快捷键至少需要 Control、Option 或 Command，并搭配一个非 Esc 按键。';
}
