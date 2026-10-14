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

/// 工具栏结构和局部快捷键的不可变快照，修改不会污染正在保存的事务。
///
/// 结构最多两级：order 是一级功能的顺序，children 是父级到子级列表。
/// 每个可拼接功能在两者中恰好出现一次；只有“工具”类功能可以作为父级。
class ScreenshotToolbarPreferences {
  /// 已从产品移除的顶层动作；已保存配置中它们的顺序、隐藏状态和快捷键直接丢弃。
  /// 撤销与重做只保留系统快捷键 ⌘Z 与 ⇧⌘Z。
  static const _removed = {'screenshot-undo', 'screenshot-redo'};

  /// order 为一级功能顺序，children 为父子结构；两者都缺省时采用默认结构。
  /// 只给 order 时视为全部一级之外没有子级。
  ScreenshotToolbarPreferences({
    List<String>? order,
    Map<String, List<String>>? children,
    Map<String, ToolbarShortcut>? shortcuts,
    Set<String>? hidden,
  }) : order = List.unmodifiable(order ?? _defaultOrder),
       children = Map.unmodifiable({
         for (final entry
             in (children ??
                     (order == null
                         ? ScreenshotActions.defaultChildren
                         : const <String, List<String>>{}))
                 .entries)
           if (entry.value.isNotEmpty)
             entry.key: List<String>.unmodifiable(entry.value),
       }),
       shortcuts = Map.unmodifiable(shortcuts ?? const {}),
       hidden = Set.unmodifiable(hidden ?? const {});

  /// 默认的一级顺序：注册表顺序里去掉默认作为子级的功能。
  static List<String> get _defaultOrder {
    final nested = {
      for (final list in ScreenshotActions.defaultChildren.values) ...list,
    };
    return [
      for (final id in ScreenshotActions.composable.keys)
        if (!nested.contains(id)) id,
    ];
  }

  final List<String> order;

  /// 父级ID到按顺序排列的子级ID；没有子级的功能不出现在这里。
  final Map<String, List<String>> children;
  final Map<String, ToolbarShortcut> shortcuts;

  /// 只控制按钮可见性，绑定和顺序保持，隐藏的功能仍可通过快捷键调用。
  final Set<String> hidden;

  /// id 为功能ID；返回它的父级，一级功能返回 null。
  String? parentOf(String id) {
    for (final entry in children.entries) {
      if (entry.value.contains(id)) return entry.key;
    }
    return null;
  }

  /// 只替换给出的部分，返回新的快照。
  ScreenshotToolbarPreferences copyWith({
    List<String>? order,
    Map<String, List<String>>? children,
    Map<String, ToolbarShortcut>? shortcuts,
    Set<String>? hidden,
  }) => ScreenshotToolbarPreferences(
    order: order ?? this.order,
    children: children ?? this.children,
    shortcuts: shortcuts ?? this.shortcuts,
    hidden: hidden ?? this.hidden,
  );

  /// map为完整应用偏好；缺省采用默认结构，返回已校验快照。
  /// 已保存配置里没有的功能按默认结构补上，已移除的功能丢弃。
  factory ScreenshotToolbarPreferences.fromMap(Map<Object?, Object?> map) {
    final storedOrder = (map[PreferenceKeys.screenshotToolbarOrder] as List?)
        ?.cast<String>();
    final storedChildren =
        (map[PreferenceKeys.screenshotToolbarChildren] as Map?);
    final storedShortcuts =
        (map[PreferenceKeys.screenshotToolbarShortcuts] as Map?);
    // 移除已取消的上下文设置和已移除的顶层动作，未知ID仍由校验报错。
    bool keep(String id) =>
        ScreenshotActions.icons.containsKey(id) ||
        !ScreenshotActions.labels.containsKey(id) && !_removed.contains(id);
    final rawHidden =
        (map[PreferenceKeys.screenshotToolbarHidden] as List?)
            ?.cast<String>()
            .toSet() ??
        <String>{};
    final order = storedOrder?.where(keep).toList();
    final hadMask = storedOrder?.contains(ScreenshotActions.mask) ?? false;
    // 合并优先保留原矩形位置；旧遮挡的唯一绑定转给图形，不维持两个入口。
    if (order != null &&
        storedOrder!.contains(ScreenshotActions.mask) &&
        !order.contains(ScreenshotActions.rect)) {
      order.insert(
        storedOrder
            .takeWhile((id) => id != ScreenshotActions.mask)
            .where(keep)
            .length
            .clamp(0, order.length),
        ScreenshotActions.rect,
      );
    }
    Map<String, List<String>>? children;
    if (order != null) {
      children = {
        for (final entry in (storedChildren ?? {}).entries)
          entry.key as String: (entry.value as List)
              .cast<String>()
              .where(keep)
              .toList(),
      };
      final placed = {...order, for (final list in children.values) ...list};
      final defaults = ScreenshotActions.composable.keys.toList();
      // 已保存结构里没有的功能：默认父级仍是一级时放回它下面，否则插到默认顺序中前一个一级功能之后。
      for (final (index, id) in defaults.indexed) {
        if (placed.contains(id)) continue;
        final parent = ScreenshotActions.defaultChildren.entries
            .where((entry) => entry.value.contains(id))
            .map((entry) => entry.key)
            .firstOrNull;
        if (parent != null && order.contains(parent)) {
          (children[parent] ??= []).add(id);
        } else {
          final previous = defaults
              .take(index)
              .lastWhere(order.contains, orElse: () => '');
          order.insert(previous.isEmpty ? 0 : order.indexOf(previous) + 1, id);
        }
        placed.add(id);
      }
    }
    final shortcuts = <String, ToolbarShortcut>{};
    for (final entry in (storedShortcuts ?? {}).entries) {
      final key = entry.key as String;
      if (keep(key) && key != ScreenshotActions.mask) {
        shortcuts[key] = ToolbarShortcut.fromMap(
          Map<Object?, Object?>.from(entry.value as Map),
        );
      }
    }
    if (!shortcuts.containsKey(ScreenshotActions.rect) &&
        storedShortcuts?[ScreenshotActions.mask] != null) {
      shortcuts[ScreenshotActions.rect] = ToolbarShortcut.fromMap(
        Map<Object?, Object?>.from(
          storedShortcuts![ScreenshotActions.mask] as Map,
        ),
      );
    }
    final hidden = {...rawHidden}
      ..remove(ScreenshotActions.mask)
      ..removeAll(_removed);
    if (hadMask && !rawHidden.contains(ScreenshotActions.mask)) {
      hidden.remove(ScreenshotActions.rect);
    }
    final result = ScreenshotToolbarPreferences(
      order: order,
      children: children,
      shortcuts: shortcuts,
      hidden: hidden,
    );
    result.validate();
    return result;
  }

  /// 无参数；返回完整结构和绑定字典，调用方合并到同一偏好事务。
  Map<String, Object> toMap() => {
    PreferenceKeys.screenshotToolbarHidden: hidden.toList(),
    PreferenceKeys.screenshotToolbarOrder: order,
    PreferenceKeys.screenshotToolbarChildren: children,
    PreferenceKeys.screenshotToolbarShortcuts: shortcuts.map(
      (key, value) => MapEntry(key, value.toMap()),
    ),
  };

  /// 无参数；拒绝缺项/重复/未知功能、不合法的父子关系与冲突绑定，保留调用方原配置。
  void validate() {
    final nested = [for (final list in children.values) ...list];
    final all = [...order, ...nested];
    if (all.length != ScreenshotActions.composable.length ||
        all.toSet().length != all.length ||
        all.any((id) => !ScreenshotActions.composable.containsKey(id))) {
      throw const FormatException('工具栏必须包含每个功能且不能重复。');
    }
    for (final parent in children.keys) {
      // 父级必须是一级功能，并且是点击后停留的“工具”。
      if (!order.contains(parent) ||
          !ScreenshotActions.composable[parent]!.hostsChildren) {
        throw const FormatException('只有一级的工具可以包含子级。');
      }
    }
    if (hidden.any((id) => !ScreenshotActions.composable.containsKey(id))) {
      throw const FormatException('只能隐藏可拼接的截图功能。');
    }
    final seen = <ToolbarShortcut>[];
    for (final entry in shortcuts.entries) {
      if (!ScreenshotActions.composable.containsKey(entry.key)) {
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
