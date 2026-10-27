/// 系统选区手势协议中 Dart 使用的值；与Swift SelectionGesture.rawValue一致。
abstract final class SelectionGestureTypes {
  /// drag 对应系统选区触发原因，不能作为待翻译文字。
  static const drag = 'drag';

  /// selectAll 对应系统选区触发原因，不能作为待翻译文字。
  static const selectAll = 'selectAll';

  /// keyboard 对应系统选区触发原因，不能作为待翻译文字。
  static const keyboard = 'keyboard';

  /// hotkey 对应系统选区触发原因，不能作为待翻译文字。
  static const hotkey = 'hotkey';

  /// inputHotkey 为输入翻译快捷键；翻译完成后用译文替换来源应用中的原文。
  static const inputHotkey = 'inputHotkey';
}
