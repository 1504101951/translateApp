import 'dart:io';

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

/// 请求超过时限时的用户可读原因；各翻译服务共用（#114）。
const translationTimeoutMessage = '翻译请求超时，请重试。';

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

/// 批量翻译请求；texts 为同一批次的段落原文，下标即批次内编号。
class BatchTranslationRequest {
  /// texts 为待译段落；detectedLanguage 为整批的识别语言，可为空；targetLanguage 为目标语言。
  const BatchTranslationRequest({
    required this.texts,
    required this.targetLanguage,
    this.detectedLanguage,
  });
  final List<String> texts;
  final String? detectedLanguage;
  final String targetLanguage;
}

/// 批量翻译失败的类别；会话据此决定停止发送、放弃该段落或重试。
enum TranslationFailureKind {
  /// 认证失败、额度或余额不足、服务拒绝配置。
  service,

  /// 请求频率受限；稍后可恢复，会话按退避间隔重试（#118）。
  rateLimited,

  /// 模型拒绝翻译或输出达到长度上限，只与本次原文有关。
  paragraph,

  /// 无法连接、超时、服务端错误、响应不完整或无法解析。
  transient,
}

/// 批量翻译向会话发布的事件；增量带批次内下标。
sealed class BatchTranslationEvent {
  /// 无参数；创建事件基类。
  const BatchTranslationEvent();
}

/// 批次内某个段落的新增译文；按顺序追加。
final class BatchItemUpdate extends BatchTranslationEvent {
  /// index 为批次内下标，addition 为该段落新增的译文。
  const BatchItemUpdate(this.index, this.addition);
  final int index;
  final String addition;
}

/// 整批完成的终态；此前没有收到译文的段落视为缺失。
final class BatchCompleted extends BatchTranslationEvent {
  /// 无参数；构造完成事件。
  const BatchCompleted();
}

/// 整批失败的终态；本批次已收到的译文不作为结果。
final class BatchFailure extends BatchTranslationEvent {
  /// message 为用户可读原因，kind 为错误类别，retryAfter 为服务要求的最短重试等待（频率受限时可能提供）。
  const BatchFailure(this.message, this.kind, {this.retryAfter});
  final String message;
  final TranslationFailureKind kind;
  final Duration? retryAfter;
}

/// 支持一次请求翻译一批段落的服务；实时翻译使用这一契约。
abstract class BatchTranslationProvider implements TranslationProvider {
  /// 无参数；返回是否允许多个批次同时在途。
  bool get allowsParallelBatches;

  /// request 为一批段落与语言方向，client 为会话持有的连接；
  /// 返回带下标的增量及整批完成或失败事件，取消订阅即中止本次请求。
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  });
}

/// value 为 HTTP Retry-After 头；返回秒数形式的等待时长，缺省、日期格式或不合法时为 null（#118）。
Duration? parseRetryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}
