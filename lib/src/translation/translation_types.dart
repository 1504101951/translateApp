enum TranslationPhase {
  idle,
  trigger,
  translating,
  completed,
  failed,
  sizeLimited,
}

class TranslationSnapshot {
  const TranslationSnapshot({
    required this.phase,
    required this.sourceText,
    required this.translatedText,
    this.message,
    this.detectedLanguage,
    this.pairs = const [],
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
  /// 设备识别出的来源语言；写入历史时必须用这次识别结果，不能再 resolve(null)。
  final String? detectedLanguage;
  final List<TranslationPair> pairs;

  TranslationSnapshot copyWith({
    TranslationPhase? phase,
    String? sourceText,
    String? translatedText,
    String? message,
    String? detectedLanguage,
    List<TranslationPair>? pairs,
  }) {
    return TranslationSnapshot(
      phase: phase ?? this.phase,
      sourceText: sourceText ?? this.sourceText,
      translatedText: translatedText ?? this.translatedText,
      message: message,
      detectedLanguage: detectedLanguage ?? this.detectedLanguage,
      pairs: pairs ?? this.pairs,
    );
  }
}

/// 一组已校验原文范围的双语段落；不保存模型未经核验的源文副本。
class TranslationPair {
  const TranslationPair(this.source, this.translation);
  final String source;
  final String translation;
}

class TranslationRequest {
  const TranslationRequest({
    required this.sourceText,
    required this.targetLanguage,
    this.detectedLanguage,
    this.previousSourceTail,
    this.previousTranslationTail,
  });

  final String sourceText;
  final String? detectedLanguage;
  final String targetLanguage;
  /// 模型后续片的前一片原文尾部，最多 1000 字符；Google 忽略。
  final String? previousSourceTail;
  /// 模型后续片的前一片译文尾部，最多 1000 字符；Google 忽略。
  final String? previousTranslationTail;
}

sealed class TranslationEvent {
  const TranslationEvent();
}

final class TranslationUpdate extends TranslationEvent {
  const TranslationUpdate(this.addition);
  final String addition;
}

final class TranslationCompleted extends TranslationEvent {
  const TranslationCompleted({this.pairs = const []});
  final List<TranslationPair> pairs;
}

final class TranslationFailure extends TranslationEvent {
  const TranslationFailure(this.message);
  final String message;
}

abstract class TranslationProvider {
  String get id;
  /// 模型后续片携带滑动上下文；Google 系为 false。
  bool get usesSlidingContext => false;
  Stream<TranslationEvent> translate(TranslationRequest request);
}
