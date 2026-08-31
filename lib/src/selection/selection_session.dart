import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../translation/language_direction.dart';
import '../translation/translation_types.dart';

/// Dart 侧 Selection Session。激活前不请求 Provider。
class SelectionSession extends ChangeNotifier {
  SelectionSession({
    required this.provider,
    LanguageDirection? language,
  }) : language = language ?? LanguageDirection.systemDefault();

  static const selectionLimit = 50000;

  final TranslationProvider provider;
  final LanguageDirection language;

  TranslationSnapshot snapshot = TranslationSnapshot.idle;
  String? sessionId;
  int _generation = 0;

  void begin({required String sessionId, required String? text}) {
    this.sessionId = sessionId;
    _generation += 1;
    if (text == null || text.trim().isEmpty) {
      snapshot = TranslationSnapshot.idle;
      notifyListeners();
      return;
    }
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.trigger,
      sourceText: text,
      translatedText: '',
    );
    notifyListeners();
  }

  Future<void> activate() async {
    if (snapshot.phase != TranslationPhase.trigger) return;
    if (snapshot.sourceText.characters.length > selectionLimit) {
      snapshot = TranslationSnapshot(
        phase: TranslationPhase.sizeLimited,
        sourceText: snapshot.sourceText,
        translatedText: '',
        message: '选区超过 50,000 个字符，未发送翻译请求。',
      );
      notifyListeners();
      return;
    }

    final generation = _generation;
    final source = snapshot.sourceText;
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.translating,
      sourceText: source,
      translatedText: '',
    );
    notifyListeners();

    final direction = language.resolve(source);
    final request = TranslationRequest(
      sourceText: source,
      detectedLanguage: direction.detectedLanguage,
      targetLanguage: direction.targetLanguage,
    );

    await for (final event in provider.translate(request)) {
      if (generation != _generation) return;
      switch (event) {
        case TranslationUpdate(:final addition):
          snapshot = snapshot.copyWith(
            phase: TranslationPhase.translating,
            translatedText: snapshot.translatedText + addition,
            message: null,
          );
        case TranslationCompleted():
          snapshot = snapshot.copyWith(
            phase: TranslationPhase.completed,
            message: null,
          );
        case TranslationFailure(:final message):
          snapshot = snapshot.copyWith(
            phase: TranslationPhase.failed,
            message: message,
          );
      }
      notifyListeners();
    }
  }

  void dismiss() {
    _generation += 1;
    sessionId = null;
    snapshot = TranslationSnapshot.idle;
    notifyListeners();
  }
}
