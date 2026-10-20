import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../common/constants/text_limits.dart';
import '../common/constants/text_mode.dart';
import '../translation/language_direction.dart';
import '../translation/segmented_translation.dart';
import '../translation/translation_types.dart';

/// Dart 侧选区会话。激活前不请求翻译服务。
class SelectionSession extends ChangeNotifier {
  /// provider/detectLanguage/language 为默认服务、设备语言识别与方向；lookupDefinition 查询词典释义，省略时不查词典。
  SelectionSession({
    required this.provider,
    required this.detectLanguage,
    LanguageDirection? language,
    Future<String?> Function(String text)? lookupDefinition,
  }) : language = language ?? LanguageDirection.systemDefault(),
       lookupDefinition = lookupDefinition ?? _noDefinition;

  /// text 为待查文字；未接入词典时始终返回 null。
  static Future<String?> _noDefinition(String text) async => null;

  /// 1–3 个拉丁字母词（可含连字符与撇号），由单个空格分隔。
  static final _latinTerm = RegExp(
    r"^[A-Za-z][A-Za-z'’-]*(?: [A-Za-z][A-Za-z'’-]*){0,2}$",
  );

  /// 1–4 个汉字。
  static final _cjkTerm = RegExp(r'^[\u4e00-\u9fff]{1,4}$');

  /// text 为原文；去首尾空白后为 1–3 个拉丁字母词且不超过 40 个字符，或为 1–4 个汉字时返回 true（#102）。
  static bool isDictionaryTerm(String text) {
    final term = text.trim();
    return term.length <= 40 &&
        (_latinTerm.hasMatch(term) || _cjkTerm.hasMatch(term));
  }

  static const selectionLimit = TextLimits.translationInput;

  // 设置更新供下一次翻译使用；已激活的请求保留自己的服务与语言方向。
  TranslationProvider provider;
  LanguageDirection language;
  final Future<String?> Function(String text) detectLanguage;

  /// 查询 macOS 词典释义；查不到返回 null。
  final Future<String?> Function(String text) lookupDefinition;

  /// 翻译模式下查到的词典释义；为 null 时卡片按普通双语对照展示。
  String? definition;

  /// 本卡片的单词是否已加入生词本；新选区或重新处理时清除，由 markSavedToVocabulary 置位。
  bool savedToVocabulary = false;

  TranslationSnapshot snapshot = TranslationSnapshot.idle;
  String? sessionId;

  /// 卡片当前的处理模式；新选区回到翻译，切换模式对同一原文重新处理（#100）。
  TextMode mode = TextMode.translate;

  /// mode 为润色、纠错或解释；返回按已提交设置构造的模型服务，默认服务不是模型服务时返回 null。
  TranslationProvider? Function(TextMode mode) assistProviderFor = (_) => null;

  /// 默认服务不是模型服务时，非翻译模式的失败说明。
  static const assistUnavailable =
      '润色、纠错与解释需要把默认翻译服务设为模型服务（OpenAI、DeepSeek 或 Anthropic）。';

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

  /// 无参数；返回当前请求的输出语言（翻译为目标语言，解释为主要语言，润色与纠错为原文语言），未发出请求时为 null。
  String? get outputLanguage => _progress?.request.targetLanguage;
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
    // 新选区结束旧请求，避免后台继续消耗连接；模式回到翻译。
    _cancelTranslation();
    mode = TextMode.translate;
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
    } catch (error) {
      if (generation != _generation) return;
      snapshot = snapshot.copyWith(
        phase: TranslationPhase.failed,
        message: '无法准备选区翻译：$error',
      );
      notifyListeners();
      return;
    }
    // _translateSource 校验原文、识别语言并按当前模式发起请求。
    await _translateSource(source, generation, activeProvider, activeLanguage);
  }

  /// mode 为目标处理模式；对卡片当前原文重新处理，翻译进行中或未展开时忽略，返回完成或取消的 Future。
  Future<void> switchMode(TextMode mode) async {
    if (!isExpanded || snapshot.phase == TranslationPhase.translating) return;
    final source = snapshot.sourceText;
    // 语言方向沿用本卡片冻结的设置，服务按目标模式取得。
    final language = activeLanguage;
    _cancelTranslation();
    this.mode = mode;
    final generation = _generation;
    final provider = mode == TextMode.translate
        ? this.provider
        : assistProviderFor(mode);
    if (provider == null) {
      snapshot = TranslationSnapshot(
        phase: TranslationPhase.failed,
        sourceText: source,
        translatedText: '',
        message: assistUnavailable,
      );
      notifyListeners();
      return;
    }
    _activeProvider = provider;
    _activeLanguage = language;
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.translating,
      sourceText: source,
      translatedText: '',
    );
    notifyListeners();
    await _translateSource(source, generation, provider, language);
  }

  /// source 为已读取的原文，generation 为发起时代次，provider/language 为冻结的服务与方向。
  /// 校验空文本与长度上限，识别语言并按当前模式确定目标语言后运行请求；返回完成或取消的 Future。
  Future<void> _translateSource(
    String source,
    int generation,
    TranslationProvider provider,
    LanguageDirection language,
  ) async {
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
    final String? detected;
    try {
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
    final direction = language.resolve(detected);
    snapshot = snapshot.copyWith(detectedLanguage: direction.detectedLanguage);
    final request = TranslationRequest(
      sourceText: source,
      detectedLanguage: direction.detectedLanguage,
      targetLanguage: switch (mode) {
        TextMode.translate => direction.targetLanguage,
        // 解释给用户自己看，使用主要语言。
        TextMode.explain => language.primaryCode,
        // 润色与纠错保持原文语言；无法识别时按主要语言处理。
        TextMode.polish || TextMode.correct =>
          direction.detectedLanguage ??
              LanguageDirection.normalize(language.primaryCode),
      },
    );

    // 翻译模式下的单词或短语同时查询词典，释义与译文各自到达，互不阻塞。
    if (mode == TextMode.translate && isDictionaryTerm(source)) {
      unawaited(_lookup(source.trim(), generation));
    }
    _progress = TranslationProgress(request);
    // 共享运行路径让初次翻译、模式切换和失败恢复遵循同一个取消、配对和完成边界。
    await _runTranslation(provider, _progress!);
  }

  /// 无参数；标记本卡片单词已加入生词本并刷新卡片按钮，无返回值。
  void markSavedToVocabulary() {
    savedToVocabulary = true;
    notifyListeners();
  }

  /// term 为去空白的原文，generation 为发起时代次；查到释义且会话未变时更新卡片，返回查询结束的 Future。
  Future<void> _lookup(String term, int generation) async {
    final found = await lookupDefinition(term);
    if (generation != _generation || found == null) return;
    definition = found;
    notifyListeners();
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
    // 释义与生词状态属于被取消的这次处理；重新翻译时重新查询。
    definition = null;
    savedToVocabulary = false;
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
