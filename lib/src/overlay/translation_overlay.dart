import '../common/constants/glass_metrics.dart';
import '../common/constants/text_mode.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/native_glass.dart';

import '../selection/selection_session.dart';
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
        // 查到词典释义时右栏展示释义全文（释义首行即原文单词），不按段落配对。
        final pairs = definition != null
            ? [TranslationPair(definition, snap.translatedText)]
            : snap.pairs.isEmpty
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
        return NativeGlassSurface(
          child: Padding(
            padding: const EdgeInsets.all(GlassMetrics.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 整块 56pt 标题区可拖动，关闭按钮与正文保留各自的点击/选字手势。
                SizedBox(
                  height: 56,
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
                                    size: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 查到释义且翻译完成后可加入生词本；本卡片加入后改为已加入并禁用。
                      if (definition != null &&
                          snap.phase == TranslationPhase.completed) ...[
                        NativeGlassSurface(
                          material: true,
                          child: IconButton(
                            onPressed: widget.session.savedToVocabulary
                                ? null
                                : widget.onAddVocabulary,
                            tooltip: widget.session.savedToVocabulary
                                ? '已加入生词本'
                                : '加入生词本',
                            icon: Icon(
                              widget.session.savedToVocabulary
                                  ? Icons.bookmark_added
                                  : Icons.bookmark_add_outlined,
                              size: 16,
                            ),
                            visualDensity: VisualDensity.standard,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // 模式菜单在重试与关闭左侧；处理中禁用，避免同一卡片并发两个请求。
                      NativeGlassMenuButton<TextMode>(
                        value: mode,
                        items: TranslationOverlay.modeLabels,
                        onChanged: busy ? null : widget.onMode,
                      ),
                      const SizedBox(width: 8),
                      if (widget.session.canRetry)
                        NativeGlassSurface(
                          material: true,
                          child: TextButton.icon(
                            onPressed: widget.onActivate,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('重试'),
                          ),
                        ),
                      NativeGlassSurface(
                        material: true,
                        child: IconButton(
                          onPressed: widget.onDismiss,
                          tooltip: '关闭',
                          icon: const Icon(Icons.close, size: 16),
                          visualDensity: VisualDensity.standard,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    for (final part in [
                      (
                        mode == TextMode.translate ? '译文' : modeLabel,
                        snap.translatedText,
                        false,
                      ),
                      // 词典栏复制释义，朗读仍读原文单词作为发音。
                      (
                        definition == null ? '原文' : '词典',
                        definition ?? snap.sourceText,
                        true,
                      ),
                    ])
                      Expanded(
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                part.$1,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                            // 朗读按钮在复制左侧，与复制共用玻璃按钮样式；栏为空时禁用。
                            NativeGlassSurface(
                              material: true,
                              child: IconButton(
                                tooltip: '朗读${part.$1}',
                                onPressed: part.$2.isEmpty
                                    ? null
                                    : () => widget.onSpeak(part.$3),
                                icon: const Icon(
                                  Icons.volume_up_rounded,
                                  size: GlassMetrics.icon,
                                ),
                                visualDensity: VisualDensity.standard,
                              ),
                            ),
                            NativeGlassSurface(
                              material: true,
                              child: IconButton(
                                tooltip: '复制${part.$1}',
                                onPressed: part.$2.isEmpty
                                    ? null
                                    : () => Clipboard.setData(
                                        ClipboardData(text: part.$2),
                                      ),
                                icon: const Icon(
                                  Icons.copy_rounded,
                                  size: GlassMetrics.icon,
                                ),
                                visualDensity: VisualDensity.standard,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface
                          .withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          // 每行共享已校验的配对边界；左右内容高度不同也不会错行。
                          for (var index = 0; index < pairs.length; index++)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: MouseRegion(
                                      key: ValueKey(
                                        'translated-paragraph-$index',
                                      ),
                                      onEnter: (_) => setState(() {
                                        _hoveredParagraph = (
                                          widget.session.sessionId,
                                          index,
                                        );
                                      }),
                                      onExit: (_) => setState(() {
                                        _hoveredParagraph = null;
                                      }),
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: SelectableText(
                                          pairs[index].translation,
                                          style: TextStyle(
                                            fontSize: GlassMetrics.bodyFont,
                                            height:
                                                GlassMetrics.bodyLine /
                                                GlassMetrics.bodyFont,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Container(
                                      key: ValueKey('source-paragraph-$index'),
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color:
                                            _hoveredParagraph ==
                                                (
                                                  widget.session.sessionId,
                                                  index,
                                                )
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: SelectableText(
                                        pairs[index].source,
                                        style: TextStyle(
                                          fontSize: GlassMetrics.bodyFont,
                                          height:
                                              GlassMetrics.bodyLine /
                                              GlassMetrics.bodyFont,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
