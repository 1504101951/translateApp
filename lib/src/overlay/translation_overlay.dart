import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../selection/selection_session.dart';
import '../translation/translation_types.dart';

/// 当前选区的触发按钮和译文卡片；窗口位置由 macOS 管理。
class TranslationOverlay extends StatelessWidget {
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

  /// context 提供主题；返回随会话更新的单按钮或结果卡片。
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final snap = session.snapshot;
        if (snap.phase == TranslationPhase.idle) {
          return const SizedBox.shrink();
        }
        if (snap.phase == TranslationPhase.trigger) {
          // 触发态整块区域就是按钮，拖动手势胜出时不会误发翻译请求。
          return Material(
            color: Colors.transparent,
            child: GestureDetector(
              onPanStart: (_) => onDrag(),
              child: FilledButton.icon(
                onPressed: onActivate,
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
                  onPanStart: (_) => onDrag(),
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
                        onPressed: onDismiss,
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, size: 16),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 只有已校验的模型对齐结果才拆段；其他结果始终显示完整原文和译文。
                        for (final pair
                            in snap.pairs.isEmpty
                                ? [
                                    TranslationPair(
                                      snap.sourceText,
                                      snap.translatedText,
                                    ),
                                  ]
                                : snap.pairs)
                          for (final part in [
                            ('原文', pair.source),
                            ('译文', pair.translation),
                          ]) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    part.$1,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF767D88),
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
                                  icon: const Icon(
                                    Icons.copy_rounded,
                                    size: 13,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            SelectableText(
                              part.$2.isEmpty && busy ? '正在翻译…' : part.$2,
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.5,
                                color: part.$1 == '原文'
                                    ? const Color(0xFF687080)
                                    : const Color(0xFF1C2434),
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (part.$1 == '译文') const Divider(height: 12),
                          ],
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
