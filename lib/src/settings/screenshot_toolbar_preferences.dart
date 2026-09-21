import 'package:flutter/services.dart';

import '../common/constants/preference_keys.dart';
import '../common/constants/screenshot_actions.dart';

/// keyId为Flutter逻辑键，modifiers按Control=1/Option=2/Shift=4/Command=8存储。
class ToolbarShortcut {
  const ToolbarShortcut(this.keyId, this.modifiers);
  final int keyId;
  final int modifiers;

  /// map为存储字典；返回键组合，结构错误由边界抛出，不能静默忽略。
  factory ToolbarShortcut.fromMap(Map<Object?, Object?> map) =>
      ToolbarShortcut(map['keyId'] as int, map['modifiers'] as int);

  /// 无参数；返回可经UserDefaults保存的标量字典。
  Map<String, int> toMap() => {'keyId': keyId, 'modifiers': modifiers};

  /// event为当前按键；修饰键从框架按下集合读取，不注册系统热键。
  factory ToolbarShortcut.fromEvent(KeyEvent event) => ToolbarShortcut(
    event.logicalKey.keyId,
    (HardwareKeyboard.instance.isControlPressed ? 1 : 0) |
        (HardwareKeyboard.instance.isAltPressed ? 2 : 0) |
        (HardwareKeyboard.instance.isShiftPressed ? 4 : 0) |
        (HardwareKeyboard.instance.isMetaPressed ? 8 : 0),
  );

  /// 无参数；返回用户可读组合键，不保存依赖键盘布局的展示字符串。
  String get label =>
      '${modifiers & 1 != 0 ? '⌃' : ''}${modifiers & 2 != 0 ? '⌥' : ''}${modifiers & 4 != 0 ? '⇧' : ''}${modifiers & 8 != 0 ? '⌘' : ''}${LogicalKeyboardKey(keyId).keyLabel.toUpperCase()}';

  /// other为候选组合；返回是否相同，用于查重和按键分派。
  bool matches(ToolbarShortcut other) =>
      keyId == other.keyId && modifiers == other.modifiers;

  /// 无参数；只接受数字或修饰字母数字，保留系统与文本编辑组合。
  void validate() {
    final digit =
        keyId >= LogicalKeyboardKey.digit0.keyId &&
        keyId <= LogicalKeyboardKey.digit9.keyId;
    final letter =
        keyId >= LogicalKeyboardKey.keyA.keyId &&
        keyId <= LogicalKeyboardKey.keyZ.keyId;
    if (modifiers < 0 ||
        modifiers & ~15 != 0 ||
        (!digit && !letter) ||
        modifiers & 11 == 0 && (!digit || modifiers != 0)) {
      throw const FormatException('使用单数字键，或 Command/Control/Option 加字母或数字。');
    }
    // 文本编辑、窗口与应用命令始终归系统，不允许局部设置覆盖它们。
    final key = LogicalKeyboardKey(keyId).keyLabel.toLowerCase();
    final systemScreenshot = modifiers & 12 == 12 && '3456'.contains(key);
    final systemDock = modifiers & 10 == 10 && key == 'd';
    if (systemScreenshot ||
        systemDock ||
        modifiers & 8 != 0 && 'acvxyzqwhmofns'.contains(key)) {
      throw const FormatException('该组合用于系统或文本编辑，请换一个快捷键。');
    }
  }
}

/// 完整顺序和局部快捷键的不可变快照，修改不会污染正在保存的事务。
class ScreenshotToolbarPreferences {
  ScreenshotToolbarPreferences({
    List<String>? order,
    Map<String, ToolbarShortcut>? shortcuts,
    Set<String>? hidden,
  }) : order = List.unmodifiable(order ?? ScreenshotActions.icons.keys),
       shortcuts = Map.unmodifiable(shortcuts ?? const {}),
       hidden = Set.unmodifiable(hidden ?? const {});
  final List<String> order;
  final Map<String, ToolbarShortcut> shortcuts;

  /// 只控制按钮可见性，绑定和顺序保持，隐藏工具仍可通过快捷键调用。
  final Set<String> hidden;

  /// map为完整应用偏好；缺省采用当前完整动作目录，返回已校验快照。
  factory ScreenshotToolbarPreferences.fromMap(Map<Object?, Object?> map) {
    final storedOrder = (map[PreferenceKeys.screenshotToolbarOrder] as List?)
        ?.cast<String>();
    final storedShortcuts =
        (map[PreferenceKeys.screenshotToolbarShortcuts] as Map?);
    // 产品只保留顶层自定义：移除已取消的上下文设置，未知ID仍由校验报错。
    bool keep(String id) =>
        ScreenshotActions.icons.containsKey(id) ||
        !ScreenshotActions.labels.containsKey(id);
    final result = ScreenshotToolbarPreferences(
      hidden: (map[PreferenceKeys.screenshotToolbarHidden] as List?)
          ?.cast<String>()
          .toSet(),
      order: storedOrder?.where(keep).toList(),
      shortcuts: storedShortcuts?.map(
        (key, value) => MapEntry(
          key as String,
          ToolbarShortcut.fromMap(Map<Object?, Object?>.from(value as Map)),
        ),
      )?..removeWhere((key, value) => !keep(key)),
    );
    result.validate();
    return result;
  }

  /// 无参数；返回完整顺序和绑定字典，调用方合并到同一偏好事务。
  Map<String, Object> toMap() => {
    PreferenceKeys.screenshotToolbarHidden: hidden.toList(),
    PreferenceKeys.screenshotToolbarOrder: order,
    PreferenceKeys.screenshotToolbarShortcuts: shortcuts.map(
      (key, value) => MapEntry(key, value.toMap()),
    ),
  };

  /// 无参数；拒绝缺项/重复/未知动作与冲突绑定，保留调用方原配置。
  void validate() {
    if (order.length != ScreenshotActions.icons.length ||
        order.toSet().length != order.length ||
        order.any((id) => !ScreenshotActions.icons.containsKey(id))) {
      throw const FormatException('工具栏顺序必须包含每个动作且不能重复。');
    }
    if (hidden.any((id) => !ScreenshotActions.icons.containsKey(id))) {
      throw const FormatException('只能隐藏顶层截图工具。');
    }
    final seen = <ToolbarShortcut>[];
    for (final entry in shortcuts.entries) {
      if (!ScreenshotActions.icons.containsKey(entry.key)) {
        throw const FormatException('未知截图动作。');
      }
      entry.value.validate();
      if (seen.any(entry.value.matches)) {
        throw const FormatException('快捷键已绑定其他截图动作。');
      }
      seen.add(entry.value);
    }
  }
}
