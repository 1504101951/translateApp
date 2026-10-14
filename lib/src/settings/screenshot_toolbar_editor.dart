import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_actions.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_toolbar_preferences.dart';

/// 截图工具配置：拖拽排序与拼接父子级、录制快捷键、显示或隐藏；仅修改偏好，不注册全局热键。
class ScreenshotToolbarEditor extends StatefulWidget {
  const ScreenshotToolbarEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final ScreenshotToolbarPreferences value;
  final ValueChanged<ScreenshotToolbarPreferences> onChanged;

  /// 每一行的固定高度。
  static const rowHeight = 56.0;

  /// 子级相对一级的缩进；落点指示线也按这个距离缩进。
  static const indent = 24.0;

  /// 拖动中指示落点的横线高度。
  static const dropLineHeight = 2.0;

  /// 被拖动行的不透明度。
  static const draggingOpacity = 0.6;

  /// 拖动中，可以挂载的行在右半边铺的选中蓝底色的不透明度。
  static const attachTint = 0.08;

  /// 拖动中，不能挂载的行在右半边盖的遮罩的不透明度；遮罩越重，这一行右半边越淡。
  static const blockedVeil = 0.6;

  /// 挂载目标（父级行）整行高亮的不透明度。
  static const hostHighlight = 0.18;

  /// 无参数；创建局部录制与排序状态，提交沿用父页自动保存。
  @override
  State<ScreenshotToolbarEditor> createState() =>
      _ScreenshotToolbarEditorState();
}

/// 一次拖动的落点：next 为松手后的配置；line 为指示线在列表中的行位置，null 表示不画线；
/// level 为落点层级；host 为挂载时要高亮的父级，排序时为 null。
typedef _Drop = ({
  ScreenshotToolbarPreferences next,
  int? line,
  int level,
  String? host,
});

class _ScreenshotToolbarEditorState extends State<ScreenshotToolbarEditor> {
  late ScreenshotToolbarPreferences _value = widget.value;
  final _recorder = FocusNode();
  final _list = GlobalKey();
  String? _recording;
  String? _error;

  /// 正在拖动的功能与当前落点；落点为空表示这个位置不允许放下。
  String? _dragging;
  _Drop? _drop;

  /// 无参数；释放局部键盘焦点，离开配置后不再捕获输入。
  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  /// next为完整配置；校验成功才提交，错误保留原值并给出原因。
  void _submit(ScreenshotToolbarPreferences next) {
    try {
      next.validate();
      setState(() {
        _value = next;
        _error = null;
      });
      widget.onChanged(next);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  /// 无参数；返回按显示顺序排列的行：每个一级功能后面紧跟它的子级。
  List<({String id, int level})> get _rows => [
    for (final id in _value.order) ...[
      (id: id, level: 0),
      for (final child in _value.children[id] ?? const <String>[])
        (id: child, level: 1),
    ],
  ];

  /// 无参数；返回可修改的父子结构副本。
  Map<String, List<String>> _childrenCopy() => {
    for (final entry in _value.children.entries) entry.key: [...entry.value],
  };

  /// id 为一行上的功能；返回这一行所属的一级功能：一级为它自己，子级为它的父级。
  String _hostOf(String id) => _value.parentOf(id) ?? id;

  /// dragged 为被拖动的功能，id 为列表中的某一行；返回 dragged 能否挂到这一行所属的一级功能之下。
  /// 只有工具可以包含子级；自己带着子级的功能不能再成为别人的子级；不能挂到自己之下。
  bool _canAttach(String dragged, String id) {
    final host = _hostOf(id);
    return host != dragged &&
        ScreenshotActions.composable[host]!.hostsChildren &&
        (_value.children[dragged] ?? const []).isEmpty;
  }

  /// id 为被拖动的功能，local 为指针相对列表左上角的位置，width 为列表宽度。
  /// 返回松手后的落点；该位置不允许放下时返回 null。
  /// 左半边是一级：按纵向位置插到一级功能之间，子级拖到这里即变回一级。
  /// 右半边是挂载：指针所在行属于哪个一级工具，就成为它的子级；
  /// 指在父级行上排到子级末尾，指在某个子级行上则插到它的前后。
  _Drop? _dropAt(String id, Offset local, double width) {
    final rows = _rows;
    // 父级带着自己的子级一起移动。
    final moving = {id, ...?_value.children[id]};
    final order = [..._value.order]..remove(id);
    final children = _childrenCopy();
    for (final list in children.values) {
      list.remove(id);
    }
    if (local.dx > width / 2) {
      final exact = local.dy / ScreenshotToolbarEditor.rowHeight;
      final index = exact.floor().clamp(0, rows.length - 1);
      final target = rows[index];
      if (moving.contains(target.id) || !_canAttach(id, target.id)) {
        return null;
      }
      final host = _hostOf(target.id);
      final siblings = children[host] ??= [];
      // 指在父级行上：排到末尾，只高亮父级，不画指示线。
      if (target.level == 0) {
        siblings.add(id);
        return (
          next: _value.copyWith(order: order, children: children),
          line: null,
          level: 1,
          host: host,
        );
      }
      // 指在子级行上：上半行插到它之前，下半行插到它之后。
      final after = exact - index >= 0.5;
      siblings.insert(siblings.indexOf(target.id) + (after ? 1 : 0), id);
      return (
        next: _value.copyWith(order: order, children: children),
        line: index + (after ? 1 : 0),
        level: 1,
        host: host,
      );
    }
    final rest = [
      for (final row in rows)
        if (!moving.contains(row.id)) row,
    ];
    final pointed = (local.dy / ScreenshotToolbarEditor.rowHeight)
        .round()
        .clamp(0, rows.length);
    var gap =
        pointed -
        rows.take(pointed).where((row) => moving.contains(row.id)).length;
    // 间隙落在某个父级的子级之间时，移到这一组的上方或下方中较近的一处。
    if (gap < rest.length && rest[gap].level == 1) {
      var start = gap;
      while (rest[start].level == 1) {
        start -= 1;
      }
      var end = gap;
      while (end < rest.length && rest[end].level == 1) {
        end += 1;
      }
      gap = gap - start < end - gap ? start : end;
    }
    order.insert(rest.take(gap).where((row) => row.level == 0).length, id);
    return (
      next: _value.copyWith(order: order, children: children),
      // 指示线画在落点间隙的下一行之上；落在末尾时画在列表底部。
      line: gap < rest.length
          ? rows.indexWhere((row) => row.id == rest[gap].id)
          : rows.length,
      level: 0,
      host: null,
    );
  }

  /// id 为功能，delta 为 -1 或 1；在同一层级的相邻位置之间移动一位，到头则不动。
  void _shift(String id, int delta) {
    final parent = _value.parentOf(id);
    final siblings = [
      ...(parent == null ? _value.order : _value.children[parent]!),
    ];
    final index = siblings.indexOf(id) + delta;
    if (index < 0 || index >= siblings.length) return;
    siblings
      ..remove(id)
      ..insert(index, id);
    _submit(
      parent == null
          ? _value.copyWith(order: siblings)
          : _value.copyWith(children: _childrenCopy()..[parent] = siblings),
    );
  }

  /// id 为一级功能；放到它上方那个一级功能的子级末尾。上方不是工具或它自己有子级时不动。
  void _nest(String id) {
    final index = _value.order.indexOf(id);
    if (index <= 0 || (_value.children[id] ?? const []).isNotEmpty) return;
    final host = _value.order[index - 1];
    if (!ScreenshotActions.composable[host]!.hostsChildren) return;
    _submit(
      _value.copyWith(
        order: [..._value.order]..remove(id),
        children: _childrenCopy()..[host] = [...?_value.children[host], id],
      ),
    );
  }

  /// id 为子级功能；变回一级，放在原父级之后。
  void _unnest(String id) {
    final parent = _value.parentOf(id);
    if (parent == null) return;
    _submit(
      _value.copyWith(
        order: [..._value.order]..insert(_value.order.indexOf(parent) + 1, id),
        children: _childrenCopy()..[parent]!.remove(id),
      ),
    );
  }

  /// id 为被拖动的功能，global 为指针的屏幕位置；更新落点。
  void _dragTo(String id, Offset global) {
    final box = _list.currentContext!.findRenderObject()! as RenderBox;
    setState(() {
      _dragging = id;
      _drop = _dropAt(id, box.globalToLocal(global), box.size.width);
    });
  }

  /// commit 为真表示松手；有合法落点时提交，否则保持原位。
  void _endDrag({required bool commit}) {
    final drop = _drop;
    setState(() {
      _dragging = null;
      _drop = null;
    });
    if (commit && drop != null) _submit(drop.next);
  }

  /// oldWidget为父级旧快照；外部重新加载时采用父级配置，不覆盖正在录制的按键。
  @override
  void didUpdateWidget(covariant ScreenshotToolbarEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _value = widget.value;
  }

  /// event为配置局部键；仅录制期间消费，Escape/失焦取消且不写配置。
  KeyEventResult _record(FocusNode node, KeyEvent event) {
    final id = _recording;
    if (id == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = null);
      return KeyEventResult.handled;
    }
    if ({
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
    }.contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    _submit(
      _value.copyWith(
        shortcuts: {..._value.shortcuts, id: ToolbarShortcut.fromEvent(event)},
      ),
    );
    setState(() => _recording = null);
    return KeyEventResult.handled;
  }

  /// context为页面主题；列表随设置正文滚动，不创建弹窗或独立滚动区域。
  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final drop = _drop;
    final moving = _dragging == null
        ? const <String>{}
        : {_dragging!, ...?_value.children[_dragging]};
    return Focus(
      focusNode: _recorder,
      onKeyEvent: _record,
      onFocusChange: (focused) {
        if (!focused && _recording != null) setState(() => _recording = null);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Stack(
            key: _list,
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (index, row) in rows.indexed)
                    Opacity(
                      key: ValueKey('toolbar-row-${row.id}'),
                      opacity: moving.contains(row.id)
                          ? ScreenshotToolbarEditor.draggingOpacity
                          : 1,
                      child: Stack(
                        children: [
                          // 挂载目标整行高亮。
                          if (drop?.host == row.id)
                            Positioned.fill(
                              key: const ValueKey('toolbar-host-highlight'),
                              child: IgnorePointer(
                                child: ColoredBox(
                                  color: NativeGlassTheme.selectionBlue
                                      .withValues(
                                        alpha: ScreenshotToolbarEditor
                                            .hostHighlight,
                                      ),
                                ),
                              ),
                            ),
                          _row(
                            context,
                            row.id,
                            row.level,
                            last: index == rows.length - 1,
                          ),
                          // 拖动中右半边是挂载区：能挂的行铺淡蓝，不能挂的行盖上遮罩变淡。
                          if (_dragging != null && !moving.contains(row.id))
                            Positioned.fill(
                              child: IgnorePointer(
                                child: FractionallySizedBox(
                                  alignment: Alignment.centerRight,
                                  widthFactor: 0.5,
                                  child: ColoredBox(
                                    key: ValueKey(
                                      _canAttach(_dragging!, row.id)
                                          ? 'toolbar-attach-${row.id}'
                                          : 'toolbar-blocked-${row.id}',
                                    ),
                                    color: _canAttach(_dragging!, row.id)
                                        ? NativeGlassTheme.selectionBlue
                                              .withValues(
                                                alpha: ScreenshotToolbarEditor
                                                    .attachTint,
                                              )
                                        : Theme.of(context).colorScheme.surface
                                              .withValues(
                                                alpha: ScreenshotToolbarEditor
                                                    .blockedVeil,
                                              ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
              // 指示线的左端跟随落点层级缩进：看线就知道会落在一级还是子级。
              if (drop?.line != null)
                Positioned(
                  key: const ValueKey('toolbar-drop-line'),
                  left: drop!.level * ScreenshotToolbarEditor.indent,
                  right: 0,
                  top:
                      drop.line! * ScreenshotToolbarEditor.rowHeight -
                      ScreenshotToolbarEditor.dropLineHeight / 2,
                  height: ScreenshotToolbarEditor.dropLineHeight,
                  child: const IgnorePointer(
                    child: ColoredBox(color: NativeGlassTheme.selectionBlue),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// id 为功能，level 为 0（一级）或 1（子级），last 表示列表最后一行；返回一行编辑控件。
  Widget _row(
    BuildContext context,
    String id,
    int level, {
    required bool last,
  }) {
    final label = ScreenshotActions.labels[id]!;
    final visible = !_value.hidden.contains(id);
    return SizedBox(
      height: ScreenshotToolbarEditor.rowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(
                  bottom: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
        ),
        child: Row(
          children: [
            SizedBox(width: level * ScreenshotToolbarEditor.indent),
            Semantics(
              label: '排序 $label',
              onIncrease: () => _shift(id, 1),
              onDecrease: () => _shift(id, -1),
              child: Focus(
                onKeyEvent: (node, event) {
                  if (_recording != null || event is! KeyDownEvent) {
                    return KeyEventResult.ignored;
                  }
                  // 上下在同级之间移动；右键成为上方工具的子级，左键变回一级。
                  final move = switch (event.logicalKey) {
                    LogicalKeyboardKey.arrowUp => () => _shift(id, -1),
                    LogicalKeyboardKey.arrowDown => () => _shift(id, 1),
                    LogicalKeyboardKey.arrowRight => () => _nest(id),
                    LogicalKeyboardKey.arrowLeft => () => _unnest(id),
                    _ => null,
                  };
                  if (move == null) return KeyEventResult.ignored;
                  move();
                  return KeyEventResult.handled;
                },
                child: Builder(
                  builder: (context) {
                    final focused = Focus.of(context).hasFocus;
                    return Tooltip(
                      message: '拖拽排序或拼接 $label；聚焦后使用方向键',
                      child: GestureDetector(
                        key: ValueKey('drag-$id'),
                        onPanStart: (details) =>
                            _dragTo(id, details.globalPosition),
                        onPanUpdate: (details) =>
                            _dragTo(id, details.globalPosition),
                        onPanEnd: (_) => _endDrag(commit: true),
                        onPanCancel: () => _endDrag(commit: false),
                        child: Listener(
                          onPointerDown: (event) {
                            // 排序与按键录制互斥，手柄获得焦点后方向键只负责移动行。
                            if (_recording != null) {
                              setState(() => _recording = null);
                            }
                            Focus.of(context).requestFocus();
                          },
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: ShapeDecoration(
                                shape: RoundedSuperellipseBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: focused
                                      ? BorderSide(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          width: 2,
                                        )
                                      : BorderSide.none,
                                ),
                              ),
                              child: const Icon(Icons.drag_handle, size: 16),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: GlassMetrics.actionGap),
            Icon(ScreenshotActions.icons[id], size: GlassMetrics.icon),
            const SizedBox(width: GlassMetrics.actionGap),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: visible
                      ? null
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: TextButton(
                key: ValueKey('bind-$id'),
                onPressed: () {
                  setState(() {
                    _recording = id;
                    _error = null;
                  });
                  _recorder.requestFocus();
                },
                child: Text(
                  _recording == id
                      ? '按键… Esc取消'
                      : _value.shortcuts[id]?.label ?? '设置快捷键',
                ),
              ),
            ),
            const SizedBox(width: GlassMetrics.actionGap),
            NativeGlassSurface(
              material: true,
              child: IconButton(
                tooltip: '清除 $label 快捷键',
                icon: const Icon(Icons.backspace_outlined),
                onPressed: _value.shortcuts.containsKey(id)
                    ? () => _submit(
                        _value.copyWith(
                          shortcuts: {..._value.shortcuts}..remove(id),
                        ),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: GlassMetrics.actionGap),
            Semantics(
              toggled: visible,
              child: IconButton(
                key: ValueKey('visibility-$id'),
                tooltip: '${visible ? '隐藏' : '显示'} $label',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  foregroundColor: visible
                      ? NativeGlassTheme.selectionBlue
                      : const Color(0xFF929292),
                ),
                icon: Icon(
                  visible ? Icons.visibility : Icons.visibility_off,
                  size: 18,
                ),
                // 可见性与结构、绑定独立保存，隐藏不丢失用户配置。
                onPressed: () => _submit(
                  _value.copyWith(
                    hidden: visible
                        ? {..._value.hidden, id}
                        : ({..._value.hidden}..remove(id)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
