import '../common/constants/glass_metrics.dart';
import '../common/constants/text_mode.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/native_glass.dart';

import '../selection/selection_session.dart';
import 'dictionary_definition.dart';
import '../translation/translation_types.dart';

/// 当前选区的触发按钮和译文卡片；窗口位置由 macOS 管理。
class TranslationOverlay extends StatefulWidget {
  /// session 提供状态；三个无参回调分别翻译、关闭、拖动，onMode 切换处理模式；构造浮层内容。
  const TranslationOverlay({
    super.key,
    required this.session,
    required this.onActivate,
    required this.onDismiss,
    required this.onDrag,
    required this.onMode,
    required this.onSpeak,
    required this.onAddVocabulary,
  });

  /// 视觉按钮84×30，透明命中窗口额外提供上下各1pt点击空间。
  static const triggerSize = Size(84, 30);
  static const triggerWindowSize = Size(84, 32);
  final SelectionSession session;
  final VoidCallback onActivate;
  final VoidCallback onDismiss;
  final VoidCallback onDrag;
  final ValueChanged<TextMode> onMode;

  /// source 为 true 时朗读原文栏，否则朗读结果栏；同一栏正在朗读时再次点击停止（#101）。
  final ValueChanged<bool> onSpeak;

  /// 把当前单词、译文与词典释义加入生词本（#102）。
  final VoidCallback onAddVocabulary;

  /// 模式菜单的选项名称，也是左栏标题；顺序即菜单顺序（#100）。
  static const modeLabels = {
    TextMode.translate: '翻译',
    TextMode.polish: '润色',
    TextMode.correct: '纠错',
    TextMode.explain: '解释',
  };

  /// 无参数；创建只保存当前悬停段落的界面状态。
  @override
  State<TranslationOverlay> createState() => _TranslationOverlayState();
}

/// 根据会话呈现触发按钮或结果；仅持有段落悬停状态，翻译由会话管理。
class _TranslationOverlayState extends State<TranslationOverlay> {
  (String?, int)? _hoveredParagraph;

  /// context 提供主题；返回随会话更新的单按钮或结果卡片。
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final snap = widget.session.snapshot;
        final definition = widget.session.definition;
        // 已校验的语义段落成对展示；没有配对时整段作为一对。词典释义单独成栏。
        final pairs = snap.pairs.isEmpty
            ? [TranslationPair(snap.sourceText, snap.translatedText)]
            : snap.pairs;
        if (snap.phase == TranslationPhase.idle) {
          return const SizedBox.shrink();
        }
        if (snap.phase == TranslationPhase.trigger) {
          // 触发态整块区域就是按钮，拖动手势胜出时不会误发翻译请求。
          return Center(
            child: GestureDetector(
              onPanStart: (_) => widget.onDrag(),
              child: NativeGlassSurface(
                material: true,
                radius: GlassMetrics.primaryRadius,
                child: FilledButton(
                  onPressed: widget.onActivate,
                  style: FilledButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: TranslationOverlay.triggerSize,
                    fixedSize: TranslationOverlay.triggerSize,
                    alignment: Alignment.center,
                    visualDensity: VisualDensity.standard,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    // 保留主题字体，让中文和系统字体设置使用同一套字形回退。
                    textStyle: Theme.of(context).textTheme.labelLarge!
                        .copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.translate_rounded, size: 16),
                      SizedBox(width: 6),
                      Text('翻译', textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final busy = snap.phase == TranslationPhase.translating;
        final mode = widget.session.mode;
        final modeLabel = TranslationOverlay.modeLabels[mode]!;
        final title = switch (snap.phase) {
          TranslationPhase.translating => '$modeLabel中…',
          TranslationPhase.failed => snap.message ?? '$modeLabel失败',
          TranslationPhase.sizeLimited => snap.message ?? '选区过长',
          _ => mode == TextMode.translate ? '双语对照' : '$modeLabel结果',
        };
        final colors = Theme.of(context).colorScheme;
        final resultLabel = mode == TextMode.translate ? '译文' : modeLabel;
        // 查到词典时左侧译文与原文用 18/26 大字号，否则正文 14/22（#134）。
        final large = definition != null;
        final resultPane = _pane(
          title: resultLabel,
          text: snap.translatedText,
          speakSource: false,
          body: _paragraphs(pairs, translated: true, large: large),
        );
        final sourcePane = _pane(
          title: '原文',
          text: snap.sourceText,
          speakSource: true,
          body: _paragraphs(pairs, translated: false, large: large),
        );
        // 三种布局：词典（左 2/5 上下分屏、右 3/5 词典）、同语言（只有原文）、普通（左右各半）。
        final Widget body;
        if (definition != null) {
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    Expanded(child: resultPane),
                    const Divider(),
                    Expanded(child: sourcePane),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 3,
                // 词典栏朗读原文单词作为发音，复制释义原文。
                child: _pane(
                  title: '词典',
                  text: definition,
                  speakSource: true,
                  vocabulary: snap.phase == TranslationPhase.completed,
                  body: DictionaryDefinitionView(definition: definition),
                ),
              ),
            ],
          );
        } else if (widget.session.sourceIsTarget) {
          body = sourcePane;
        } else {
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: resultPane),
              const VerticalDivider(width: 1),
              Expanded(child: sourcePane),
            ],
          );
        }
        return NativeGlassSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 44pt 标题区保留玻璃材料；左侧拖动区与右侧按钮各自响应手势。
              SizedBox(
                height: 44,
                child: Padding(
                  // 关闭按钮命中区比 28pt 可见尺寸各边多 2pt，右内边距相应减为 10pt。
                  padding: const EdgeInsets.only(left: 10, right: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.move,
                          child: GestureDetector(
                            key: const ValueKey('result-drag-area'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => widget.onDrag(),
                            child: SizedBox.expand(
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.drag_indicator,
                                    size: 16,
                                    color: colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  if (busy)
                                    const Padding(
                                      padding: EdgeInsets.only(right: 8),
                                      child: SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 模式菜单在重试与关闭左侧；处理中禁用，避免同一卡片并发两个请求。
                      SizedBox(
                        width: 120,
                        height: 28,
                        child: NativeGlassMenuButton<TextMode>(
                          value: mode,
                          items: TranslationOverlay.modeLabels,
                          onChanged: busy ? null : widget.onMode,
                        ),
                      ),
                      if (widget.session.canRetry) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 28,
                          child: NativeGlassSurface(
                            material: true,
                            child: TextButton.icon(
                              onPressed: widget.onActivate,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重试'),
                            ),
                          ),
                        ),
                      ],
                      // 关闭命中区与可见按钮的 2pt 差额计入 8pt 元素间距。
                      const SizedBox(width: 6),
                      _CardButton(
                        tooltip: '关闭',
                        icon: Icons.close,
                        onPressed: widget.onDismiss,
                        visual: 28,
                        radius: GlassMetrics.controlRadius,
                        iconSize: GlassMetrics.icon,
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 0.5, thickness: 0.5),
              // 正文使用 95% 不透明阅读底色，不随玻璃透明度变化，来源应用的内容不会透出。
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardTheme.color,
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(GlassMetrics.panelRadius),
                    ),
                  ),
                  child: body,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// title 为栏名，text 为该栏可朗读与复制的全文，speakSource 为朗读原文（true）或结果（false），
  /// vocabulary 为是否在栏头最前显示「加入生词本」，body 为可滚动正文；返回 28pt 栏头加独立滚动正文的一栏。
  Widget _pane({
    required String title,
    required String text,
    required bool speakSource,
    required Widget body,
    bool vocabulary = false,
  }) {
    final saved = widget.session.savedToVocabulary;
    final actions = [
      // 查到释义且翻译完成后可加入生词本；本卡片加入后改为已加入并禁用（#102）。
      if (vocabulary)
        (
          saved ? '已加入生词本' : '加入生词本',
          saved ? Icons.bookmark_added : Icons.bookmark_add_outlined,
          saved ? null : widget.onAddVocabulary,
        ),
      // 朗读与复制在栏为空时禁用。
      (
        '朗读$title',
        Icons.volume_up_rounded,
        text.isEmpty ? null : () => widget.onSpeak(speakSource),
      ),
      (
        '复制$title',
        Icons.copy_rounded,
        text.isEmpty
            ? null
            : () => Clipboard.setData(ClipboardData(text: text)),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 栏头：上 6pt、下 4pt、高 28pt；按钮组命中区向外多出 4pt，因此右侧定位为 16−4=12pt。
        SizedBox(
          height: 38,
          child: Stack(
            children: [
              Positioned(
                left: 16,
                top: 6,
                height: 28,
                right: 16 + actions.length * 28.0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                top: 4,
                width: actions.length * 28.0 + 4,
                height: 32,
                child: Stack(
                  children: [
                    // 可见 24pt 按钮间距 4pt，步长 28pt；32pt 命中区相邻重叠 4pt。
                    for (final (index, action) in actions.indexed)
                      Positioned(
                        left: index * 28.0,
                        top: 0,
                        child: _CardButton(
                          tooltip: action.$1,
                          icon: action.$2,
                          onPressed: action.$3,
                          visual: 24,
                          radius: 6,
                          iconSize: 14,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
            child: body,
          ),
        ),
      ],
    );
  }

  /// pairs 为已校验的段落配对，translated 选择译文（true）或原文（false），large 为词典布局的 18/26 字号；
  /// 返回段间距 8pt 的段落列，悬停译文段落时高亮对应原文段落。
  Widget _paragraphs(
    List<TranslationPair> pairs, {
    required bool translated,
    required bool large,
  }) {
    final colors = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: large ? 18 : 14,
      height: large ? 26 / 18 : 22 / 14,
      fontWeight: large ? FontWeight.w500 : null,
      color: translated ? colors.onSurface : colors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (var index = 0; index < pairs.length; index++)
          translated
              ? MouseRegion(
                  key: ValueKey('translated-paragraph-$index'),
                  onEnter: (_) => setState(() {
                    _hoveredParagraph = (widget.session.sessionId, index);
                  }),
                  onExit: (_) => setState(() => _hoveredParagraph = null),
                  child: SelectableText(pairs[index].translation, style: style),
                )
              : Container(
                  key: ValueKey('source-paragraph-$index'),
                  decoration: BoxDecoration(
                    color:
                        _hoveredParagraph == (widget.session.sessionId, index)
                        ? colors.primaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(pairs[index].source, style: style),
                ),
      ],
    );
  }
}

/// 卡片中的玻璃图标按钮：中心绘制 visual×visual 的可见按钮，外围 32×32 命中区同样触发动作。
class _CardButton extends StatelessWidget {
  /// tooltip 为提示与可访问名，icon 为图标，onPressed 为空表示禁用；visual、radius、iconSize 为可见尺寸、圆角与图标边长。
  const _CardButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.visual,
    required this.radius,
    required this.iconSize,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double visual;
  final double radius;
  final double iconSize;

  /// context 未使用；返回 32×32 命中区与居中的玻璃按钮。
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: GlassMetrics.hitSize,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // 可见按钮外的命中环；可见按钮本身在上层处理悬停、按压与提示。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
          ),
        ),
        SizedBox.square(
          dimension: visual,
          child: NativeGlassSurface(
            material: true,
            radius: radius,
            child: IconButton(
              tooltip: tooltip,
              onPressed: onPressed,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tight(Size.square(visual)),
              iconSize: iconSize,
              icon: Icon(icon),
            ),
          ),
        ),
      ],
    ),
  );
}
