import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_actions.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_toolbar_preferences.dart';

/// 截图工具配置：顶层动作拖拽排序和录制，仅修改偏好，不注册全局热键。
class ScreenshotToolbarEditor extends StatefulWidget {
  const ScreenshotToolbarEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final ScreenshotToolbarPreferences value;
  final ValueChanged<ScreenshotToolbarPreferences> onChanged;

  /// 无参数；创建局部录制与排序状态，提交沿用父页自动保存。
  @override
  State<ScreenshotToolbarEditor> createState() =>
      _ScreenshotToolbarEditorState();
}

class _ScreenshotToolbarEditorState extends State<ScreenshotToolbarEditor> {
  late ScreenshotToolbarPreferences _value = widget.value;
  final _recorder = FocusNode();
  String? _recording;
  String? _error;

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

  /// oldIndex/newIndex为移动前后实际索引；框架已扣除移出行，返回无。
  void _reorder(int oldIndex, int newIndex) {
    final order = [..._value.order];
    final id = order.removeAt(oldIndex);
    order.insert(newIndex, id);
    // 顺序只改变顶层工具，提交沿用同一自动保存事务。
    _submit(
      ScreenshotToolbarPreferences(
        order: order,
        shortcuts: _value.shortcuts,
        hidden: _value.hidden,
      ),
    );
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
      ScreenshotToolbarPreferences(
        order: _value.order,
        hidden: _value.hidden,
        shortcuts: {..._value.shortcuts, id: ToolbarShortcut.fromEvent(event)},
      ),
    );
    setState(() => _recording = null);
    return KeyEventResult.handled;
  }

  /// context为页面主题；列表随设置正文滚动，不创建弹窗或独立滚动区域。
  @override
  Widget build(BuildContext context) => Focus(
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
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          padding: EdgeInsets.zero,
          itemCount: _value.order.length,
          onReorderItem: _reorder,
          // 拖动影像使用同一阅读背景，不在原生材料外再加阴影。
          proxyDecorator: (child, index, animation) => Material(
            color: Theme.of(context).colorScheme.surface,
            child: child,
          ),
          itemBuilder: (context, index) {
            final id = _value.order[index];
            final label = ScreenshotActions.labels[id]!;
            final visible = !_value.hidden.contains(id);
            return ConstrainedBox(
              key: ValueKey('toolbar-row-$id'),
              constraints: const BoxConstraints(minHeight: 56),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: index < _value.order.length - 1
                      ? Border(
                          bottom: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    Semantics(
                      label: '排序 $label',
                      onIncrease: index < _value.order.length - 1
                          ? () => _reorder(index, index + 1)
                          : null,
                      onDecrease: index > 0
                          ? () => _reorder(index, index - 1)
                          : null,
                      child: Focus(
                        onKeyEvent: (node, event) {
                          if (_recording != null || event is! KeyDownEvent) {
                            return KeyEventResult.ignored;
                          }
                          if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                              index > 0) {
                            _reorder(index, index - 1);
                            return KeyEventResult.handled;
                          }
                          if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown &&
                              index < _value.order.length - 1) {
                            _reorder(index, index + 1);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Builder(
                          builder: (context) {
                            final focused = Focus.of(context).hasFocus;
                            return Tooltip(
                              message: '拖拽排序 $label；聚焦后使用上下方向键',
                              child: ReorderableDragStartListener(
                                key: ValueKey('drag-$id'),
                                index: index,
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
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
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
                                      child: const Icon(
                                        Icons.drag_handle,
                                        size: 16,
                                      ),
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
                            ? () {
                                final shortcuts = {..._value.shortcuts}
                                  ..remove(id);
                                _submit(
                                  ScreenshotToolbarPreferences(
                                    order: _value.order,
                                    hidden: _value.hidden,
                                    shortcuts: shortcuts,
                                  ),
                                );
                              }
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
                        onPressed: () {
                          final hidden = {..._value.hidden};
                          if (visible) {
                            hidden.add(id);
                          } else {
                            hidden.remove(id);
                          }
                          // 可见性与排序、绑定独立保存，隐藏不丢失用户配置。
                          _submit(
                            ScreenshotToolbarPreferences(
                              order: _value.order,
                              shortcuts: _value.shortcuts,
                              hidden: hidden,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
}
