import '../constants/method_names.dart';
import '../constants/channel_names.dart';
import '../constants/preference_keys.dart';
import '../constants/platform_view_types.dart';
import '../constants/glass_metrics.dart';
import '../constants/appearance_modes.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 普通窗口的连续阅读底色；四角由AppKit统一裁剪，Flutter不再形成第二个面板。
class NativeGlassWindowPage extends StatelessWidget {
  /// child为窗口内容；与原生标题区使用同一不透明语义色。
  const NativeGlassWindowPage({super.key, required this.child});
  final Widget child;

  /// context提供当前外观；返回无内部圆角或顶部接缝的页面背景。
  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Theme.of(context).colorScheme.surface, child: child);
}

/// macOS 原生玻璃材料；AppKit 处理折射及系统可访问性，Flutter 保留业务和交互。
class NativeGlassSurface extends StatelessWidget {
  /// child 为前景控件，radius 为逻辑点圆角；创建单个材料层，不对子内容做图像滤镜。
  const NativeGlassSurface({
    super.key,
    required this.child,
    this.radius,
    this.material = false,
  });

  final Widget child;
  final double? radius;

  /// 页面只绘制阅读背景，独立交互控件才启用原生折射，避免嵌套。
  final bool material;

  /// context 提供主题；返回原生材料与前景的有序叠放，材料不抢占手势。
  @override
  Widget build(BuildContext context) {
    final radius =
        this.radius ??
        (material
            ? (child is FilledButton
                  ? GlassMetrics.primaryRadius
                  : GlassMetrics.controlRadius)
            : GlassMetrics.panelRadius);
    final isButton = child is ButtonStyleButton || child is IconButton;
    final onPressed = switch (child) {
      ButtonStyleButton(:final onPressed) => onPressed,
      IconButton(:final onPressed) => onPressed,
      _ => null,
    };
    final foreground = isButton
        ? _GlassButtonFeedback(
            radius: radius,
            enabled: onPressed != null,
            child: child,
          )
        : child;
    // 材料配置也是依赖；只改透明度时主题颜色可能不变，仍需更新原生视图。
    context.dependOnInheritedWidgetOfExactType<_GlassAppearanceScope>();
    final brightness = Theme.of(context).brightness;
    final highContrast = MediaQuery.highContrastOf(context);
    // 新弹窗成为活动层时，下面的页面使用普通内容底色，避免叠加两层折射。
    final activeLayer = ModalRoute.isCurrentOf(context) != false;
    if (material &&
        context.dependOnInheritedWidgetOfExactType<_GlassMaterialScope>() !=
            null) {
      // 下拉已选项等共享父材料；弹出路由脱离此scope后才创建自己的玻璃。
      return foreground;
    }
    if (!material) {
      return ClipRSuperellipse(
        borderRadius: BorderRadius.circular(radius),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.78),
          // 浮层不经过Scaffold，必须在阅读表面建立Material文本基底，避免继承诊断双下划线。
          child: Material(type: MaterialType.transparency, child: child),
        ),
      );
    }
    // 放松列表的横向紧约束，让材料跟随前景尺寸；输入框/滑块自身仍填满可用宽度。
    final surface = Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      heightFactor: 1,
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            if (!activeLayer)
              Positioned.fill(
                child: ColoredBox(color: Theme.of(context).colorScheme.surface),
              )
            else
              Positioned.fill(
                // 原生材料只绘图，Flutter平台视图包装层也必须退出键盘遍历。
                child: ExcludeFocus(
                  child: ExcludeSemantics(
                    child: AppKitView(
                      key: ValueKey((
                        brightness,
                        highContrast,
                        radius,
                        GlassAppearance.current.value.opacity,
                      )),
                      viewType: PlatformViewTypes.nativeGlass,
                      creationParams: {
                        'cornerRadius': radius,
                        'brightness': brightness.name,
                        'highContrast': highContrast,
                        'opacity': GlassAppearance.current.value.opacity,
                      },
                      creationParamsCodec: const StandardMessageCodec(),
                      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                    ),
                  ),
                ),
              ),
            Material(
              type: MaterialType.transparency,
              child: _GlassMaterialScope(child: foreground),
            ),
          ],
        ),
      ),
    );
    if (!isButton) return surface;
    // 可见按钮保持28/30pt，外围透明命中区域至少32pt；标准按钮仍处理自身语义和键盘。
    return GestureDetector(
      excludeFromSemantics: true,
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: GlassMetrics.hitSize,
          minHeight: GlassMetrics.hitSize,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          heightFactor: 1,
          child: surface,
        ),
      ),
    );
  }
}

/// 复用标准按钮的动作/语义，只统一数值化的悬停、按下和焦点绘制。
class _GlassButtonFeedback extends StatefulWidget {
  /// child 为原有可操作控件，enabled决定是否绘制反馈；inset供菜单留出2pt行间命中空间。
  const _GlassButtonFeedback({
    required this.child,
    required this.radius,
    required this.enabled,
    this.inset = EdgeInsets.zero,
  });
  final Widget child;
  final double radius;
  final bool enabled;
  final EdgeInsets inset;
  @override
  /// 无参数；创建按钮瞬时交互状态，不持有业务数据。
  State<_GlassButtonFeedback> createState() => _GlassButtonFeedbackState();
}

/// 维护控件悬停、按下和焦点绘制；业务动作仍由标准按钮处理。
class _GlassButtonFeedbackState extends State<_GlassButtonFeedback> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  /// context 提供主题与动态效果偏好；状态层不拦截按钮的原有事件。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final alpha = !widget.enabled
        ? 0.0
        : _pressed
        ? GlassMetrics.pressedOpacity
        : _hovered
        ? GlassMetrics.hoverOpacity
        : 0.0;
    return Focus(
      canRequestFocus: false,
      onFocusChange: (value) => setState(() => _focused = value),
      onKeyEvent: (_, event) {
        if (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          setState(() => _pressed = event is! KeyUpEvent);
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: Listener(
          onPointerDown: (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: Stack(
            children: [
              widget.child,
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: widget.inset,
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : GlassMetrics.transition,
                      decoration: ShapeDecoration(
                        color: colors.onSurface.withValues(alpha: alpha),
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(widget.radius),
                          side: _focused && widget.enabled
                              ? BorderSide(color: colors.primary, width: 2)
                              : BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 字段标题和说明位于材料外，避免浮动标签越过原生视图裁剪边界。
class NativeGlassField extends StatefulWidget {
  /// label 是可访问名称，helper 为补充说明；child 是不带浮动标签的输入或选择控件。
  const NativeGlassField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
  });
  final String label;
  final String? helper;
  final Widget child;

  /// 无参数；创建仅跟踪键盘焦点的状态，不持有业务输入。
  @override
  State<NativeGlassField> createState() => _NativeGlassFieldState();
}

/// 跟踪字段焦点以绘制连续曲线边框，不持有输入内容。
class _NativeGlassFieldState extends State<NativeGlassField> {
  bool _focused = false;

  /// context 提供主题；返回外置标题、连续圆角焦点边框及说明，保留输入子树状态。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Semantics(
            label: widget.label,
            child: Focus(
              canRequestFocus: false,
              onFocusChange: (focused) => setState(() => _focused = focused),
              child: NativeGlassSurface(
                material: true,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(
                        GlassMetrics.controlRadius,
                      ),
                      side: BorderSide(
                        color: _focused
                            ? colors.primary
                            : colors.outlineVariant,
                        width: _focused ? 2 : 1,
                      ),
                    ),
                  ),
                  // 标题由外层承担；移除输入框自带圆弧边框，焦点只绘制一层连续曲线。
                  child: InputDecorationTheme(
                    data: const InputDecorationThemeData(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
          if (widget.helper != null) ...[
            const SizedBox(height: 6),
            Text(widget.helper!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// 设置行只给开关本身提供胶囊材料，标题与说明直接融入页面。
class NativeGlassSwitchTile extends StatelessWidget {
  /// title/subtitle 为文字语义，value 是开关状态，onChanged 为空表示禁用。
  const NativeGlassSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// context 提供控件主题；返回只有右侧按钮可交互的设置项。
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    // 标题和说明只读，避免点击文字意外更改并自动保存偏好。
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    splashColor: Colors.transparent,
    minVerticalPadding: 0,
    minTileHeight: subtitle == null
        ? GlassMetrics.rowHeight
        : GlassMetrics.captionRowHeight,
    trailing: NativeGlassSwitch(
      value: value,
      onChanged: onChanged,
      label: title,
    ),
  );
}

/// 紧凑选择器；当前值与菜单分别布局，避免菜单内边距裁切选中值。
class NativeGlassDropdown<T> extends StatefulWidget {
  /// label/value/items 是字段名称、选中值和有序选项；onChanged 为空表示禁用。
  const NativeGlassDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;

  /// 无参数；创建触发器和当前菜单项的焦点状态。
  @override
  State<NativeGlassDropdown<T>> createState() => _NativeGlassDropdownState<T>();
}

/// 管理触发器与当前菜单选项焦点；选中值由调用方持有。
class _NativeGlassDropdownState<T> extends State<NativeGlassDropdown<T>> {
  final _buttonFocus = FocusNode();
  final _selectedFocus = FocusNode();

  /// 无参数；释放窗口内持有的两个焦点节点。
  @override
  void dispose() {
    _buttonFocus.dispose();
    _selectedFocus.dispose();
    super.dispose();
  }

  /// context 提供主题；菜单共享一层材料，值超过一行时按18pt行高增长。
  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final value = widget.value;
    final items = widget.items;
    final onChanged = widget.onChanged;
    return NativeGlassSettingRow(
      title: label,
      child: MenuAnchor(
        childFocusNode: _buttonFocus,
        onOpen: () {
          // 菜单挂载后聚焦当前值，使鼠标和键盘打开都能直接用方向键选择。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _selectedFocus.context != null) {
              _selectedFocus.requestFocus();
            }
          });
        },
        style: const MenuStyle(
          padding: WidgetStatePropertyAll(EdgeInsets.zero),
          backgroundColor: WidgetStatePropertyAll(Colors.transparent),
          elevation: WidgetStatePropertyAll(0),
        ),
        menuChildren: [
          NativeGlassSurface(
            material: true,
            radius: GlassMetrics.menuRadius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: GlassMetrics.menuMinWidth,
                maxWidth: GlassMetrics.menuMaxWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final option in items.entries)
                      _GlassButtonFeedback(
                        radius: GlassMetrics.menuItemRadius,
                        enabled: onChanged != null,
                        inset: const EdgeInsets.symmetric(vertical: 2),
                        child: MenuItemButton(
                          focusNode: option.key == value
                              ? _selectedFocus
                              : null,
                          onPressed: onChanged == null
                              ? null
                              : () => onChanged(option.key),
                          style: ButtonStyle(
                            overlayColor: const WidgetStatePropertyAll(
                              Colors.transparent,
                            ),
                            minimumSize: const WidgetStatePropertyAll(
                              Size(0, GlassMetrics.hitSize),
                            ),
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            ),
                            shape: WidgetStatePropertyAll(
                              RoundedSuperellipseBorder(
                                borderRadius: BorderRadius.circular(
                                  GlassMetrics.menuItemRadius,
                                ),
                              ),
                            ),
                          ),
                          child: Text(option.value),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
        builder: (context, controller, _) => ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: GlassMetrics.dropdownMinWidth,
            maxWidth: GlassMetrics.dropdownMaxWidth,
          ),
          child: NativeGlassSurface(
            material: true,
            child: TextButton(
              focusNode: _buttonFocus,
              onPressed: onChanged == null
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(items[value]!, textAlign: TextAlign.left),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.unfold_more, size: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 常规设置行；文字与右侧控件不足时按Spec换行，不压缩字号。
class NativeGlassSettingRow extends StatelessWidget {
  /// title 为独立字段名称，child 为宽度最多240pt的控件，caption为可换行说明。
  const NativeGlassSettingRow({
    super.key,
    required this.title,
    required this.child,
    this.caption,
  });
  final String title;
  final String? caption;
  final Widget child;

  /// context 提供文字缩放；以可用宽度判断是否保持左右两列。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title),
          if (caption != null)
            Text(caption!, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
      // 160pt文字列+16pt列间距+240pt控件列，低于该值时明确换行。
      return ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: caption == null
              ? GlassMetrics.rowHeight
              : GlassMetrics.captionRowHeight,
        ),
        child: constraints.maxWidth < 416
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [label, const SizedBox(height: 8), child],
              )
            : Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 16),
                  child,
                ],
              ),
      );
    },
  );
}

/// 同组设置共享阅读背景；材料不逐行重复折射。
class NativeGlassGroup extends StatelessWidget {
  /// children 为按顺序排列的设置行；高度由实际行高和32pt内边距决定。
  const NativeGlassGroup({super.key, required this.children});
  final List<Widget> children;

  /// context 提供语义底色；返回16pt连续圆角的分组。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: GlassMetrics.groupGap),
    // 分组本身承载Material，组内ListTile的焦点与悬停层才绘制在背景之上。
    child: Material(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.035),
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(GlassMetrics.panelRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(GlassMetrics.panelPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// 外观与导航共用平整分段；选中背景铺满单段，蓝底白字不随明暗反转。
class NativeGlassSegments<T> extends StatelessWidget {
  /// value/options/onChanged 为选中状态；navigation决定72×32导航或76×28外观分段。
  const NativeGlassSegments({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icons = const {},
    this.navigation = false,
  });
  final T value;
  final Map<T, String> options;
  final Map<T, IconData> icons;
  final ValueChanged<T> onChanged;
  final bool navigation;

  /// context 提供主题与文字缩放；可见高度固定基线，点击区域至少32pt。
  @override
  Widget build(BuildContext context) {
    final width = navigation
        ? GlassMetrics.navigationWidth
        : GlassMetrics.appearanceSegmentWidth;
    final height = navigation
        ? GlassMetrics.hitSize
        : GlassMetrics.buttonHeight;
    final radius = navigation
        ? GlassMetrics.primaryRadius
        : GlassMetrics.controlRadius;
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      excludeFromSemantics: true,
      behavior: HitTestBehavior.opaque,
      onTapUp: (event) => onChanged(
        options.keys.elementAt(
          (event.localPosition.dx / width).floor().clamp(0, options.length - 1),
        ),
      ),
      child: SizedBox(
        width: width * options.length,
        height: GlassMetrics.hitSize,
        child: Center(
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: colors.onSurface.withValues(alpha: 0.10),
              child: SizedBox(
                height: height,
                child: Stack(
                  children: [
                    Row(
                      children: [
                        for (final option in options.entries)
                          SizedBox(
                            width: width,
                            height: height,
                            child: Padding(
                              padding: EdgeInsets.zero,
                              child: Semantics(
                                selected: value == option.key,
                                child: _GlassButtonFeedback(
                                  radius: radius,
                                  enabled: true,
                                  child: TextButton(
                                    onPressed: () => onChanged(option.key),
                                    style: TextButton.styleFrom(
                                      // 反馈Stack会放松子约束；显式轮廓尺寸确保蓝底不缩为18pt文字行。
                                      minimumSize: Size(width, height),
                                      fixedSize: Size(width, height),
                                      padding: EdgeInsets.zero,
                                      foregroundColor: value == option.key
                                          ? Colors.white
                                          : colors.onSurface,
                                      backgroundColor: value == option.key
                                          ? NativeGlassTheme.selectionBlue
                                          : Colors.transparent,
                                      shape: RoundedSuperellipseBorder(
                                        borderRadius: BorderRadius.circular(
                                          radius,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (icons[option.key] != null) ...[
                                          Icon(
                                            icons[option.key],
                                            size: GlassMetrics.icon,
                                          ),
                                          const SizedBox(
                                            width: GlassMetrics.iconGap,
                                          ),
                                        ],
                                        Text(option.value),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    // 仅相邻未选项之间保留1pt分隔，选中蓝块边缘不叠线。
                    for (var index = 1; index < options.length; index++)
                      if (options.keys.elementAt(index - 1) != value &&
                          options.keys.elementAt(index) != value)
                        Positioned(
                          left: width * index - 0.5,
                          top: 7,
                          bottom: 7,
                          width: 1,
                          child: IgnorePointer(
                            child: ColoredBox(
                              color: colors.onSurface.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 固定36×20轨道和16×16滑块；系统Switch没有这些几何尺寸的公开配置。
class NativeGlassSwitch extends StatefulWidget {
  /// value 为当前开关值，onChanged为空时禁用；label提供可访问名称。
  const NativeGlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  /// 无参数；创建键盘焦点状态，业务值由调用方持有。
  @override
  State<NativeGlassSwitch> createState() => _NativeGlassSwitchState();
}

/// 维护开关键盘焦点；将用户动作映射为值反转，不保存业务偏好。
class _NativeGlassSwitchState extends State<NativeGlassSwitch> {
  bool _focused = false;

  /// 无参数；仅在启用时向业务层发布反转后的值。
  void _toggle() => widget.onChanged?.call(!widget.value);

  /// context 提供主题与减少动态效果；返回带键盘、语义和32pt命中高度的开关。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : GlassMetrics.transition;
    return Semantics(
      label: widget.label,
      toggled: widget.value,
      enabled: widget.onChanged != null,
      onTap: widget.onChanged == null ? null : _toggle,
      child: FocusableActionDetector(
        // 仅开关36×32命中区显示可点击手形；标题区域保持默认指针。
        mouseCursor: widget.onChanged == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        enabled: widget.onChanged != null,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onChanged == null ? null : _toggle,
          child: SizedBox(
            width: GlassMetrics.switchWidth,
            height: GlassMetrics.hitSize,
            child: Center(
              child: Opacity(
                opacity: widget.onChanged == null ? 0.38 : 1,
                child: NativeGlassSurface(
                  material: true,
                  radius: GlassMetrics.switchHeight / 2,
                  child: AnimatedContainer(
                    duration: duration,
                    width: GlassMetrics.switchWidth,
                    height: GlassMetrics.switchHeight,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: widget.value
                          ? colors.primary
                          : colors.outlineVariant,
                      borderRadius: BorderRadius.circular(
                        GlassMetrics.switchHeight / 2,
                      ),
                    ),
                    foregroundDecoration: _focused
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              GlassMetrics.switchHeight / 2,
                            ),
                            border: Border.all(
                              color: colors.onSurface,
                              width: 2,
                            ),
                          )
                        : null,
                    child: AnimatedAlign(
                      alignment: widget.value
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      duration: duration,
                      child: const SizedBox.square(
                        dimension: GlassMetrics.switchThumb,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 服务配置等模态表单的玻璃容器；内容不重复折射，长表单由内容自身滚动。
class NativeGlassDialog extends StatelessWidget {
  /// title/content/actions 为标题、表单及操作列表；创建保持键盘和弹窗语义的对话框。
  const NativeGlassDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });
  final Widget title;
  final Widget content;
  final List<Widget> actions;

  /// context 提供主题；返回宽度受限、可容纳长表单的独立玻璃弹窗。
  @override
  Widget build(BuildContext context) => Dialog(
    // 弹窗使用95%阅读底色，避免底层设置文字透过表单干扰阅读。
    backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 568),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DefaultTextStyle(
              style: Theme.of(context).textTheme.headlineSmall!,
              child: title,
            ),
            const SizedBox(height: 20),
            Flexible(child: content),
            const SizedBox(height: 20),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: actions,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Material默认将激活轨道增高2pt；统一轨道厚度使两侧均符合6pt规格。
class _UniformSliderTrack extends RoundedRectSliderTrackShape {
  const _UniformSliderTrack();

  /// 参数为Slider布局、状态和位置；仅取消激活轨道额外厚度，保留原生绘制/命中。
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
    double additionalActiveTrackHeight = 0,
  }) => super.paint(
    context,
    offset,
    parentBox: parentBox,
    sliderTheme: sliderTheme,
    enableAnimation: enableAnimation,
    thumbCenter: thumbCenter,
    secondaryOffset: secondaryOffset,
    isEnabled: isEnabled,
    isDiscrete: isDiscrete,
    textDirection: textDirection,
    additionalActiveTrackHeight: 0,
  );
}

/// 五类窗口共用的语义主题；材料保持系统原生，内容区域以普通颜色保证可读性。
abstract final class NativeGlassTheme {
  /// 分段选中的蓝色与白字固定配对，避免深色主题反转为黑字。
  static const selectionBlue = Color(0xFF007AFF);

  /// brightness 为当前明暗模式；返回统一控件、输入框、卡片与弹窗的 Material 主题。
  static ThemeData data(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A84FF),
          brightness: brightness,
        ).copyWith(
          surface: dark ? const Color(0xFF171717) : const Color(0xFFF7F7F7),
          onSurface: dark ? Colors.white : Colors.black,
          onSurfaceVariant: dark
              ? const Color(0xFFCCCCCC)
              : const Color(0xFF454545),
          outline: dark ? const Color(0xFF929292) : const Color(0xFF696969),
          outlineVariant: dark
              ? const Color(0xFF505050)
              : const Color(0xFFC5C5C5),
          primary: dark ? const Color(0xFF64ACFF) : const Color(0xFF005BC5),
          onPrimary: dark ? Colors.black : Colors.white,
        );
    final controlShape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
    );
    final text = TextStyle(
      fontSize: GlassMetrics.bodyFont,
      height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
      color: colors.onSurface,
    );
    final typography = Typography.material2021(platform: TargetPlatform.macOS);
    final baseText = dark ? typography.white : typography.black;
    final content = dark ? const Color(0xF2232323) : const Color(0xF2FFFFFF);
    return ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.macOS,
      typography: typography,
      textTheme: baseText.copyWith(
        bodyLarge: text,
        bodyMedium: text,
        labelLarge: text,
        titleMedium: text,
        bodySmall: text.copyWith(
          fontSize: GlassMetrics.captionFont,
          height: GlassMetrics.captionLine / GlassMetrics.captionFont,
          color: colors.onSurfaceVariant,
        ),
        titleSmall: text.copyWith(
          fontSize: 14,
          height: 20 / 14,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: text.copyWith(
          fontSize: 20,
          height: 26 / 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      iconTheme: IconThemeData(
        size: GlassMetrics.icon,
        color: colors.onSurface,
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      colorScheme: colors,
      brightness: brightness,
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: content,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.panelRadius),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: content,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.panelRadius),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(GlassMetrics.primaryRadius),
          ),
          minimumSize: const Size(
            GlassMetrics.primaryMinWidth,
            GlassMetrics.primaryHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          textStyle: text,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          animationDuration: GlassMetrics.transition,
          overlayColor: Colors.transparent,
          foregroundColor: colors.onPrimary,
          backgroundColor: colors.primary,
          disabledBackgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: controlShape,
          minimumSize: const Size(
            GlassMetrics.buttonMinWidth,
            GlassMetrics.buttonHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          textStyle: text,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          animationDuration: GlassMetrics.transition,
          overlayColor: Colors.transparent,
          foregroundColor: colors.onSurface,
          backgroundColor: Colors.transparent,
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurface,
          minimumSize: const Size(
            GlassMetrics.buttonMinWidth,
            GlassMetrics.buttonHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          textStyle: text,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          animationDuration: GlassMetrics.transition,
          overlayColor: Colors.transparent,
          shape: controlShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(GlassMetrics.hitSize),
          maximumSize: const Size.square(GlassMetrics.hitSize),
          iconSize: GlassMetrics.icon,
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          animationDuration: GlassMetrics.transition,
          overlayColor: Colors.transparent,
          shape: controlShape,
          foregroundColor: colors.onSurface,
          backgroundColor: Colors.transparent,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(controlShape),
          foregroundColor: WidgetStatePropertyAll(colors.onSurface),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? colors.primary.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: content,
        surfaceTintColor: Colors.transparent,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(backgroundColor: WidgetStatePropertyAll(content)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(colors.onSurface),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.primary.withValues(alpha: 0.65)
              : colors.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: selectionBlue,
        inactiveTrackColor: colors.onSurface.withValues(alpha: 0.20),
        thumbColor: Colors.white,
        trackHeight: GlassMetrics.sliderTrack,
        trackShape: const _UniformSliderTrack(),
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: GlassMetrics.sliderThumbRadius,
          disabledThumbRadius: GlassMetrics.sliderThumbRadius,
          elevation: 0,
          pressedElevation: 0,
        ),
        overlayShape: SliderComponentShape.noOverlay,
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.transparent,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          borderSide: BorderSide(color: colors.error),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.inverseSurface,
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        ),
        textStyle: TextStyle(color: colors.onInverseSurface),
      ),
    );
  }
}

/// 每个引擎仅持有视觉快照，业务设置仍归主引擎；改变主题不会替换表单或截图状态。
class GlassAppearance {
  /// mode 为 system/light/dark；opacity 为材料不透明度0.2–1，前景始终不透明。
  const GlassAppearance({
    this.mode = AppearanceModes.system,
    this.opacity = 0.8,
  });
  final String mode;
  final double opacity;
  static final current = ValueNotifier(const GlassAppearance());
  static const channel = MethodChannel(ChannelNames.appearance);

  /// map 为原生视觉偏好；校验边界后返回不可变配置。
  factory GlassAppearance.fromMap(Map<Object?, Object?> map) {
    final mode =
        map[PreferenceKeys.glassAppearance] as String? ??
        AppearanceModes.system;
    final opacity =
        (map[PreferenceKeys.glassOpacity] as num?)?.toDouble() ?? 0.8;
    if (!AppearanceModes.values.contains(mode) ||
        !opacity.isFinite ||
        opacity < 0.2 ||
        opacity > 1) {
      throw const FormatException('外观模式或玻璃透明度无效。');
    }
    return GlassAppearance(mode: mode, opacity: opacity);
  }

  /// 无参数；返回Material主题模式，跟随系统由Flutter现有亮度通知驱动。
  ThemeMode get themeMode => switch (mode) {
    AppearanceModes.light => ThemeMode.light,
    AppearanceModes.dark => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

/// 五类窗口共享的外观入口；专用视觉通道不覆盖任何业务通道的回调。
class NativeGlassApp extends StatefulWidget {
  /// home 为保留状态的业务根，title 为窗口语义名称；创建统一主题应用。
  const NativeGlassApp({super.key, required this.home, this.title = ''});
  final Widget home;
  final String title;

  /// 无参数；返回仅订阅视觉偏好的状态，业务状态由home持有。
  @override
  State<NativeGlassApp> createState() => _NativeGlassAppState();
}

/// 订阅当前引擎视觉广播；dispose解除回调，不管理业务会话。
class _NativeGlassAppState extends State<NativeGlassApp> {
  /// 无参数；先注册广播再读取快照，不接管业务通道。
  @override
  void initState() {
    super.initState();
    GlassAppearance.channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.appearanceChanged) {
        GlassAppearance.current.value = GlassAppearance.fromMap(
          Map<Object?, Object?>.from(call.arguments as Map),
        );
      }
    });
    unawaited(_load());
  }

  /// 无参数；读取本引擎启动时的视觉快照，返回加载完成的Future。
  Future<void> _load() async {
    final value = await GlassAppearance.channel
        .invokeMapMethod<Object?, Object?>(MethodNames.getAppearance);
    if (mounted && value != null) {
      GlassAppearance.current.value = GlassAppearance.fromMap(value);
    }
  }

  /// 无参数；解除当前引擎回调，不清除已保存偏好。
  @override
  void dispose() {
    GlassAppearance.channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// context 为当前引擎；仅重建主题，home的元素身份保持不变。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GlassAppearance>(
    valueListenable: GlassAppearance.current,
    builder: (context, appearance, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: widget.title,
      themeMode: appearance.themeMode,
      theme: NativeGlassTheme.data(Brightness.light),
      darkTheme: NativeGlassTheme.data(Brightness.dark),
      builder: (context, child) => _GlassAppearanceScope(child: child!),
      home: widget.home,
    ),
  );
}

/// 把视觉广播传到已保留的子树，透明度更新不要求重建业务页面。
class _GlassAppearanceScope
    extends InheritedNotifier<ValueNotifier<GlassAppearance>> {
  /// child 为当前Navigator；订阅引擎视觉状态而不修改业务对象。
  _GlassAppearanceScope({required super.child})
    : super(notifier: GlassAppearance.current);
}

/// 标记单个原生材料的前景子树，避免共享控件重复折射。
class _GlassMaterialScope extends InheritedWidget {
  /// child为共享当前材料的内容；不保存业务状态。
  const _GlassMaterialScope({required super.child});

  /// oldWidget为上次作用域；标记恒定，无需通知。
  @override
  bool updateShouldNotify(_GlassMaterialScope oldWidget) => false;
}
