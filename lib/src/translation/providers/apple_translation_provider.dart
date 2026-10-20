import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../common/constants/channel_names.dart';
import '../../common/constants/error_codes.dart';
import '../../common/constants/method_names.dart';
import '../../common/constants/system_translation.dart';
import '../../settings/app_settings.dart';
import '../../settings/service_config.dart';
import '../model_result.dart';
import '../paragraph_translation.dart';
import '../translation_types.dart';

/// Apple 系统翻译：经 Swift 调用 macOS Translation 框架在本机翻译。
/// 本类负责段落切分、编号配对、取消与错误分类；Swift 只按语言对翻译一组段落并按下标返回译文。
class AppleTranslationProvider implements BatchTranslationProvider {
  /// config 为系统翻译服务配置；channel 为主引擎平台通道，省略时使用 macOS 默认通道。
  AppleTranslationProvider({required this.config, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(ChannelNames.macos);

  final ServiceConfig config;
  final MethodChannel _channel;

  /// 主引擎内递增的请求序号；作为原生按请求取消的定位键。
  static var _nextRequest = 0;

  /// 语言包缺失时告知用户的下载位置；失败卡片与测试连接共用。
  static const downloadHint = '请到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载。';

  @override
  String get id => config.id;

  /// 系统翻译逐片独立翻译，不携带前片上下文。
  @override
  bool get usesSlidingContext => false;

  /// 本机模型同一时刻只处理一个批次，避免多个批次争用计算资源。
  @override
  bool get allowsParallelBatches => false;

  /// request 为一个分片的原文与方向；返回整片完成后一次发布的译文与段落配对。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    // translateParagraphs 处理原文已是目标语言的直通与取消传播；其余整片交给 _translateSegment 一次翻译。
    return translateParagraphs(
      _translateSegment,
      request,
      keepWholeSource: true,
    );
  }

  /// request 为整片原文；按非空段落批量翻译，返回整片译文更新与带原文分隔符的配对。
  Stream<TranslationEvent> _translateSegment(TranslationRequest request) {
    // modelSourceParagraphs 切出含前后分隔空白的段落，拼接后完整覆盖原文。
    final paragraphs = modelSourceParagraphs(request.sourceText);
    final requestId = 'apple-${_nextRequest++}';
    final events = StreamController<TranslationEvent>();
    var active = true;
    events.onListen = () async {
      try {
        // _translateTexts 调用原生翻译，返回与 texts 下标一一对应的译文。
        final translations = await _translateTexts(
          requestId,
          [for (final paragraph in paragraphs) paragraph.trim()],
          source: request.detectedLanguage,
          target: request.targetLanguage,
          // 单篇翻译优先质量，使用高保真策略。
          strategy: SystemTranslationStrategy.highFidelity,
        );
        if (!active) return;
        // pairParagraph 把原段首尾空白套回译文，配对只依赖下标，不依赖译文句数。
        final pairs = [
          for (final (index, paragraph) in paragraphs.indexed)
            pairParagraph(paragraph, translations[index]),
        ];
        events.add(
          TranslationUpdate(pairs.map((pair) => pair.translation).join()),
        );
        events.add(TranslationCompleted(pairs: pairs));
      } on _SystemFailure catch (failure) {
        if (active) events.add(TranslationFailure(failure.message));
      } finally {
        active = false;
        await events.close();
      }
    };
    events.onCancel = () {
      // 订阅方取消后丢弃迟到结果；正常结束时 active 已为 false，不再通知原生。
      if (!active) return;
      active = false;
      _cancelNative(requestId);
    };
    return events.stream;
  }

  /// request 为实时翻译的一批段落；client 为会话连接，本机翻译不使用网络。
  /// 返回按下标发布的各段译文及整批完成或失败事件，取消订阅即停止原生计算。
  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    final requestId = 'apple-${_nextRequest++}';
    final events = StreamController<BatchTranslationEvent>();
    var active = true;
    events.onListen = () async {
      try {
        // _translateTexts 调用原生翻译，返回与 texts 下标一一对应的译文。
        final translations = await _translateTexts(
          requestId,
          request.texts,
          source: request.detectedLanguage,
          target: request.targetLanguage,
          // 实时翻译请求频繁，优先低延迟。
          strategy: SystemTranslationStrategy.lowLatency,
        );
        if (!active) return;
        for (final (index, translation) in translations.indexed) {
          events.add(BatchItemUpdate(index, translation));
        }
        events.add(const BatchCompleted());
      } on _SystemFailure catch (failure) {
        if (active) events.add(BatchFailure(failure.message, failure.kind));
      } finally {
        active = false;
        await events.close();
      }
    };
    events.onCancel = () {
      // 订阅方取消后丢弃迟到结果；正常结束时 active 已为 false，不再通知原生。
      if (!active) return;
      active = false;
      _cancelNative(requestId);
    };
    return events.stream;
  }

  /// pairs 为（源语言, 目标语言）列表；返回一一对应的语言包安装状态，不触发下载。
  Future<List<SystemTranslationStatus>> statuses(
    List<(String, String)> pairs,
  ) async {
    final raw = await _channel.invokeListMethod<String>(
      MethodNames.systemTranslationStatus,
      {
        'pairs': [
          for (final (source, target) in pairs) [source, target],
        ],
      },
    );
    return [
      for (final name in raw!) SystemTranslationStatus.values.byName(name),
    ];
  }

  /// source/target 为服务语言码；返回「源语言 → 目标语言」的界面名称，未登记的语言码原样显示。
  static String pairLabel(String source, String target) =>
      '${AppSettings.languages[source] ?? source} → '
      '${AppSettings.languages[target] ?? target}';

  /// requestId 定位原生会话，texts 为待译段落，source/target 为语言码，strategy 为翻译策略。
  /// 返回与 texts 等长的译文；原文语言未知或原生失败时抛出带类别的 _SystemFailure。
  Future<List<String>> _translateTexts(
    String requestId,
    List<String> texts, {
    required String? source,
    required String target,
    required SystemTranslationStrategy strategy,
  }) async {
    // 无界面会话必须指定源语言，识别失败不发起翻译；只影响本段原文，实时翻译可单段重发。
    if (source == null) {
      throw const _SystemFailure('无法识别原文语言。', TranslationFailureKind.paragraph);
    }
    try {
      final translations = await _channel.invokeListMethod<String>(
        MethodNames.systemTranslate,
        {
          'requestId': requestId,
          'texts': texts,
          'source': source,
          'target': target,
          'strategy': strategy.name,
        },
      );
      return translations!;
    } on PlatformException catch (error) {
      // 语言包缺失与语言对不支持对后续请求同样成立，归为服务级；其余为可重试的临时失败。
      final label = pairLabel(source, target);
      throw switch (error.code) {
        ErrorCodes.translationNotInstalled => _SystemFailure(
          '缺少「$label」语言包，$downloadHint',
          TranslationFailureKind.service,
        ),
        ErrorCodes.translationUnsupported => _SystemFailure(
          'Apple 系统翻译不支持「$label」。',
          TranslationFailureKind.service,
        ),
        _ => const _SystemFailure(
          'Apple 系统翻译失败，请重试。',
          TranslationFailureKind.transient,
        ),
      };
    }
  }

  /// requestId 为被取消的请求；通知原生停止对应会话的本机计算，避免与下一批次争用资源，无返回值。
  void _cancelNative(String requestId) {
    unawaited(
      _channel.invokeMethod<void>(MethodNames.cancelSystemTranslation, {
        'requestId': requestId,
      }),
    );
  }
}

/// 原生翻译失败；message 为用户可读原因，kind 决定实时翻译停止、单段放弃或重试。
class _SystemFailure implements Exception {
  /// message 为界面文案，kind 为失败类别。
  const _SystemFailure(this.message, this.kind);
  final String message;
  final TranslationFailureKind kind;
}
