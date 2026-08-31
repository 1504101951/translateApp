enum TranslationPhase { idle, trigger, translating, completed, failed, sizeLimited }

class TranslationSnapshot {
  const TranslationSnapshot({
    required this.phase,
    required this.sourceText,
    required this.translatedText,
    this.message,
  });

  static const idle = TranslationSnapshot(
    phase: TranslationPhase.idle,
    sourceText: '',
    translatedText: '',
  );

  final TranslationPhase phase;
  final String sourceText;
  final String translatedText;
  final String? message;

  TranslationSnapshot copyWith({
    TranslationPhase? phase,
    String? sourceText,
    String? translatedText,
    String? message,
  }) {
    return TranslationSnapshot(
      phase: phase ?? this.phase,
      sourceText: sourceText ?? this.sourceText,
      translatedText: translatedText ?? this.translatedText,
      message: message,
    );
  }
}

class TranslationRequest {
  const TranslationRequest({
    required this.sourceText,
    required this.targetLanguage,
    this.detectedLanguage,
  });

  final String sourceText;
  final String? detectedLanguage;
  final String targetLanguage;
}

sealed class TranslationEvent {
  const TranslationEvent();
}

final class TranslationUpdate extends TranslationEvent {
  const TranslationUpdate(this.addition);
  final String addition;
}

final class TranslationCompleted extends TranslationEvent {
  const TranslationCompleted();
}

final class TranslationFailure extends TranslationEvent {
  const TranslationFailure(this.message);
  final String message;
}

abstract class TranslationProvider {
  String get id;
  Stream<TranslationEvent> translate(TranslationRequest request);
}
