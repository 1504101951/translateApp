import '../common/constants/translation_phase.dart';
export '../common/constants/translation_phase.dart';

/// 浮层消费的统一会话快照；不暴露分片调度和Provider内部状态。
class TranslationSnapshot {
  /// phase/sourceText/translatedText 为可见状态；message为失败说明，pairs为完整配对。
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

  /// 参数为需替换的可见字段；返回新快照，未指定字段保留，message可清除。
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
  /// source为本地原文范围，translation为对应译文；创建不可变配对。
  const TranslationPair(this.source, this.translation);
  final String source;
  final String translation;
}

/// 一次服务请求及有界前片上下文；不含凭据或更早的全篇历史。
class TranslationRequest {
  /// sourceText为本片，targetLanguage为目标；两个previous尾部可空且各最多1000字。
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

/// 翻译层向会话发布的事件；表达增量、完成或失败，不直接修改界面状态。
sealed class TranslationEvent {
  /// 无参数；创建事件基类，载荷由具体子类提供。
  const TranslationEvent();
}

/// 流式新增文本事件；内容按顺序追加，不表示整篇完成。
final class TranslationUpdate extends TranslationEvent {
  /// addition为本次新增译文；构造增量事件，不修改会话。
  const TranslationUpdate(this.addition);
  final String addition;
}

/// 请求完整完成的终态；可携带已验证的原文译文配对。
final class TranslationCompleted extends TranslationEvent {
  /// pairs为完整双语配对，可为空；该事件允许调用方提交结果和历史。
  const TranslationCompleted({this.pairs = const []});
  final List<TranslationPair> pairs;
}

/// 无法继续翻译的终态；用户可读错误与已完成片的恢复状态分别管理。
final class TranslationFailure extends TranslationEvent {
  /// message为用户可读失败原因；构造停止事件，由会话决定是否可重试。
  const TranslationFailure(this.message);
  final String message;
}

/// 翻译服务统一契约；实现负责翻译，会话层负责取消、恢复和界面状态。
abstract class TranslationProvider {
  /// 无参数；返回用于历史记录的稳定服务标识，不改变服务状态。
  String get id;

  /// 模型后续片携带滑动上下文；Google 系为 false。
  bool get usesSlidingContext => false;
  /// request提供文本、语言方向及前片上下文；返回有序增量、完成或失败事件流。
  Stream<TranslationEvent> translate(TranslationRequest request);
}
