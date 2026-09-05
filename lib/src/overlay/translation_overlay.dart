import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../selection/selection_session.dart';
import '../translation/translation_types.dart';

/// 当前选区的触发按钮和译文卡片；窗口位置由 macOS 管理。
class TranslationOverlay extends StatefulWidget {
  /// session 提供状态；三个无参回调分别翻译、关闭、拖动；构造浮层内容。
  const TranslationOverlay({
    super.key,
    required this.session,
    required this.onActivate,
    required this.onDismiss,
    required this.onDrag,
  });

  static const triggerSize = Size(84, 36);
  final SelectionSession session;
  final VoidCallback onActivate;
  final VoidCallback onDismiss;
  final VoidCallback onDrag;

  /// 无参数；创建只保存当前悬停段落的界面状态。
  @override
  State<TranslationOverlay> createState() => _TranslationOverlayState();
}

class _TranslationOverlayState extends State<TranslationOverlay> {
  (String?, int)? _hoveredParagraph;

  /// context 提供主题；返回随会话更新的单按钮或结果卡片。
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final snap = widget.session.snapshot;
        final pairs = snap.pairs.isEmpty
            ? [TranslationPair(snap.sourceText, snap.translatedText)]
            : snap.pairs;
        if (snap.phase == TranslationPhase.idle) {
          return const SizedBox.shrink();
        }
        if (snap.phase == TranslationPhase.trigger) {
          // 触发态整块区域就是按钮，拖动手势胜出时不会误发翻译请求。
          return Material(
            color: Colors.transparent,
            child: GestureDetector(
              onPanStart: (_) => widget.onDrag(),
              child: FilledButton.icon(
                onPressed: widget.onActivate,
                icon: const Icon(Icons.translate_rounded, size: 16),
                label: const Text('翻译'),
                style: FilledButton.styleFrom(
                  foregroundColor: const Color(0xFF285FCB),
                  backgroundColor: const Color(0xFFFAFBFE),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  // 保留主题字体，让中文和系统字体设置使用同一套字形回退。
                  textStyle: Theme.of(context).textTheme.labelLarge!
                      .copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                    side: const BorderSide(color: Color(0xFFDCE2ED)),
                  ),
                ),
              ),
            ),
          );
        }

        final busy = snap.phase == TranslationPhase.translating;
        final title = switch (snap.phase) {
          TranslationPhase.translating => '翻译中…',
          TranslationPhase.failed => snap.message ?? '翻译失败',
          TranslationPhase.sizeLimited => snap.message ?? '选区过长',
          _ => '双语对照',
        };
        return Material(
          color: const Color(0xFFFAFBFE),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 结果标题提供拖动区域，无需额外占用一条原生标题栏。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => widget.onDrag(),
                  child: Row(
                    children: [
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: widget.onDismiss,
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, size: 16),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    for (final part in [
                      ('译文', snap.translatedText),
                      ('原文', snap.sourceText),
                    ])
                      Expanded(
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                part.$1,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF687080),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '复制${part.$1}',
                              onPressed: part.$2.isEmpty
                                  ? null
                                  : () => Clipboard.setData(
                                      ClipboardData(text: part.$2),
                                    ),
                              icon: const Icon(Icons.copy_rounded, size: 14),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
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
                                        style: const TextStyle(
                                          fontSize: 14,
                                          height: 1.5,
                                          color: Color(0xFF1C2434),
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
                                              (widget.session.sessionId, index)
                                          ? const Color(0xFFDFEBFF)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: SelectableText(
                                      pairs[index].source,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                        color: Color(0xFF687080),
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
              ],
            ),
          ),
        );
      },
    );
  }
}
