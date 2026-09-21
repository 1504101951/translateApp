import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../translation/language_direction.dart';
import '../translation/segmented_translation.dart';
import '../translation/translation_types.dart';

/// Dart 侧 Selection Session。激活前不请求 Provider。
class SelectionSession extends ChangeNotifier {
  SelectionSession({
    required this.provider,
    required this.detectLanguage,
    LanguageDirection? language,
  }) : language = language ?? LanguageDirection.systemDefault();

  static const selectionLimit = 50000;

  // 设置更新供下一次翻译使用；已激活的请求保留自己的服务与语言方向。
  TranslationProvider provider;
  LanguageDirection language;
  final Future<String?> Function(String text) detectLanguage;

  TranslationSnapshot snapshot = TranslationSnapshot.idle;
  String? sessionId;

  /// 无参数；返回当前是否为需要显式关闭的展开卡片。
  bool get isExpanded =>
      snapshot.phase != TranslationPhase.idle &&
      snapshot.phase != TranslationPhase.trigger;

  /// 活跃请求与服务冻结到重试完成，不受期间设置修改影响。
  TranslationProgress? _progress;
  TranslationProvider? _activeProvider;
  LanguageDirection? _activeLanguage;

  /// 无参数；返回当前失败是否有可恢复的分片请求。
  bool get canRetry =>
      snapshot.phase == TranslationPhase.failed && _progress != null;

  /// 无参数；返回本会话实际服务，供成功历史使用。
  TranslationProvider get activeProvider => _activeProvider ?? provider;

  /// 无参数；返回本会话冻结语言方向，供重试和成功历史使用。
  LanguageDirection get activeLanguage => _activeLanguage ?? language;
  int _generation = 0;
  StreamSubscription<TranslationEvent>? _translation;
  Completer<void>? _completion;

  /// sessionId 标识选区，text 为已读原文；awaitSelection 允许键盘手势先显示按钮，点击后补读。
  void begin({
    required String sessionId,
    required String? text,
    bool awaitSelection = false,
  }) {
    this.sessionId = sessionId;
    // 新选区结束旧请求，避免后台继续消耗连接。
    _cancelTranslation();
    if (!awaitSelection && (text == null || text.trim().isEmpty)) {
      snapshot = TranslationSnapshot.idle;
      notifyListeners();
      return;
    }
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.trigger,
      sourceText: text ?? '',
      translatedText: '',
    );
    notifyListeners();
  }

  /// readSelection 可在明确激活后补读原文；返回翻译结束或会话被取消时完成的 Future。
  Future<void> activate({Future<String?> Function()? readSelection}) async {
    if (snapshot.phase != TranslationPhase.trigger) return;

    final generation = _generation;
    final activeProvider = _activeProvider = provider;
    final activeLanguage = _activeLanguage = language;
    var source = snapshot.sourceText;
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.translating,
      sourceText: source,
      translatedText: '',
    );
    notifyListeners();

    String? detected;
    try {
      if (readSelection != null) {
        final text = await readSelection();
        if (generation != _generation) return;
        // 不发送失效选区的缓存；空读取由下方失败卡片统一说明。
        source = text ?? '';
        snapshot = TranslationSnapshot(
          phase: TranslationPhase.translating,
          sourceText: source,
          translatedText: '',
        );
        notifyListeners();
      }
      // 候选按钮尚未取得文字时不能产生空文本请求。
      if (source.trim().isEmpty) {
        snapshot = snapshot.copyWith(
          phase: TranslationPhase.failed,
          message: '未读取到选中文字，请重新选择后使用翻译快捷键。',
        );
        notifyListeners();
        return;
      }
      if (source.characters.length > selectionLimit) {
        snapshot = TranslationSnapshot(
          phase: TranslationPhase.sizeLimited,
          sourceText: source,
          translatedText: '',
          message: '选区超过 50,000 个字符，未发送翻译请求。',
        );
        notifyListeners();
        return;
      }
      detected = await detectLanguage(source);
    } catch (error) {
      if (generation != _generation) return;
      snapshot = snapshot.copyWith(
        phase: TranslationPhase.failed,
        message: '无法准备选区翻译：$error',
      );
      notifyListeners();
      return;
    }
    // 设备识别是异步桥调用；等待期间换选区或关闭不能发出旧请求。
    if (generation != _generation) return;
    final direction = activeLanguage.resolve(detected);
    snapshot = snapshot.copyWith(detectedLanguage: direction.detectedLanguage);
    final request = TranslationRequest(
      sourceText: source,
      detectedLanguage: direction.detectedLanguage,
      targetLanguage: direction.targetLanguage,
    );

    _progress = TranslationProgress(request);
    // 共享运行路径让初次翻译和失败恢复遵循同一个取消、配对和完成边界。
    await _runTranslation(activeProvider, _progress!);
  }

  /// 无参数；保留完整片并重新请求失败片，返回完成或取消的 Future。
  Future<void> retry() async {
    if (!canRetry) return;
    final progress = _progress!;
    snapshot = snapshot.copyWith(
      phase: TranslationPhase.translating,
      translatedText: progress.completedText,
      pairs: List.unmodifiable(progress.pairs),
    );
    notifyListeners();
    await _translation?.cancel();
    // 取消订阅期间关闭/换选区不允许重启旧请求。
    if (!identical(progress, _progress)) return;
    await _runTranslation(_activeProvider!, progress);
  }

  /// activeProvider 和 progress 为冻结服务及本次请求检查点；返回结束或取消的 Future。
  Future<void> _runTranslation(
    TranslationProvider activeProvider,
    TranslationProgress progress,
  ) async {
    final generation = _generation;
    final completion = Completer<void>();
    _completion = completion;
    // 保存真实流订阅，使关闭会话能即时取消 Provider 的网络连接。
    _translation =
        translateSegmented(
          activeProvider.translate,
          progress.request,
          progress: progress,
          usesSlidingContext: activeProvider.usesSlidingContext,
        ).listen(
          (event) {
            if (generation != _generation) return;
            switch (event) {
              case TranslationUpdate(:final addition):
                snapshot = snapshot.copyWith(
                  phase: TranslationPhase.translating,
                  translatedText: snapshot.translatedText + addition,
                  // 恢复期间仍显示正在增长的统一结果，不能让旧完整配对遮住新片增量。
                  pairs: const [],
                  message: null,
                );
              case TranslationCompleted(:final pairs):
                snapshot = snapshot.copyWith(
                  phase: TranslationPhase.completed,
                  pairs: pairs,
                  message: null,
                );
              case TranslationFailure(:final message):
                snapshot = snapshot.copyWith(
                  phase: TranslationPhase.failed,
                  translatedText: progress.completedText,
                  pairs: List.unmodifiable(progress.pairs),
                  message: message,
                );
            }
            notifyListeners();
            // 完整业务结果已经确定，不把历史提交拖到网络订阅清理之后。
            if ((event is TranslationCompleted ||
                    event is TranslationFailure) &&
                !completion.isCompleted) {
              completion.complete();
            }
          },
          onDone: () {
            if (!completion.isCompleted) completion.complete();
            if (generation == _generation) {
              _translation = null;
              _completion = null;
            }
          },
        );
    await completion.future;
  }

  /// 无参数；取消请求并清空当前选区，无返回值。
  void dismiss() {
    // 关闭会话即停止请求，迟到事件仍由 generation 拦截。
    _cancelTranslation();
    sessionId = null;
    snapshot = TranslationSnapshot.idle;
    notifyListeners();
  }

  /// 无参数；取消当前流并完成调用方等待，递增代次拒绝迟到事件，无返回值。
  void _cancelTranslation() {
    _generation += 1;
    _progress = null;
    _activeProvider = null;
    _activeLanguage = null;
    unawaited(_translation?.cancel());
    _translation = null;
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  /// 无参数；释放会话时取消网络订阅，无返回值。
  @override
  void dispose() {
    _cancelTranslation();
    super.dispose();
  }
}
