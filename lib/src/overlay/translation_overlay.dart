import 'package:flutter/material.dart';

import '../selection/selection_session.dart';
import '../translation/translation_types.dart';

class TranslationOverlay extends StatelessWidget {
  const TranslationOverlay({
    super.key,
    required this.session,
    required this.onActivate,
    required this.onDismiss,
  });

  final SelectionSession session;
  final VoidCallback onActivate;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final snap = session.snapshot;
        return Material(
          color: const Color(0xF2FFFFFF),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: switch (snap.phase) {
              TranslationPhase.idle => const SizedBox.shrink(),
              TranslationPhase.trigger => _Trigger(
                  onActivate: onActivate,
                  onDismiss: onDismiss,
                ),
              TranslationPhase.translating => _Result(
                  title: '翻译中…',
                  body: snap.translatedText,
                  busy: true,
                  onDismiss: onDismiss,
                ),
              TranslationPhase.completed => _Result(
                  title: '译文',
                  body: snap.translatedText,
                  busy: false,
                  onDismiss: onDismiss,
                ),
              TranslationPhase.failed => _Result(
                  title: snap.message ?? '翻译失败',
                  body: snap.translatedText,
                  busy: false,
                  onDismiss: onDismiss,
                ),
              TranslationPhase.sizeLimited => _Result(
                  title: snap.message ?? '选区过长',
                  body: '',
                  busy: false,
                  onDismiss: onDismiss,
                ),
            },
          ),
        );
      },
    );
  }
}

class _Trigger extends StatelessWidget {
  const _Trigger({required this.onActivate, required this.onDismiss});

  final VoidCallback onActivate;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        FilledButton(
          onPressed: onActivate,
          child: const Text('翻译'),
        ),
        const Spacer(),
        IconButton(
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 16),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.title,
    required this.body,
    required this.busy,
    required this.onDismiss,
  });

  final String title;
  final String body;
  final bool busy;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            child: SelectableText(
              body.isEmpty ? '' : body,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }
}
