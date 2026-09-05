import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../translation/language_direction.dart';
import '../translation/translation_types.dart';

/// Dart 侧 Selection Session。激活前不请求 Provider。
class SelectionSession extends ChangeNotifier {
  SelectionSession({
    required this.provider,
    required this.detectLanguage,
    LanguageDirection? language,
  }) : language = language ?? LanguageDirection.systemDefault();

  static const selectionLimit = 50000;

  // 保存默认服务后替换 Provider；切换前由主引擎取消旧会话。
  TranslationProvider provider;
  LanguageDirection language;
  final Future<String?> Function(String text) detectLanguage;

  TranslationSnapshot snapshot = TranslationSnapshot.idle;
  String? sessionId;
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
        if (text == null || text.trim().isEmpty) {
          // 原生已确认读取失效，不能继续发送捕获时缓存的文字。
          dismiss();
          return;
        }
        source = text;
        snapshot = TranslationSnapshot(
          phase: TranslationPhase.translating,
          sourceText: source,
          translatedText: '',
        );
        notifyListeners();
      }
      // 候选按钮尚未取得文字时不能产生空文本请求。
      if (source.trim().isEmpty) {
        dismiss();
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
    final direction = language.resolve(detected);
    final request = TranslationRequest(
      sourceText: source,
      detectedLanguage: direction.detectedLanguage,
      targetLanguage: direction.targetLanguage,
    );

    final completion = Completer<void>();
    _completion = completion;
    // 保存真实流订阅，使关闭会话能即时取消 Provider 的网络连接。
    _translation = provider
        .translate(request)
        .listen(
          (event) {
            if (generation != _generation) return;
            switch (event) {
              case TranslationUpdate(:final addition):
                snapshot = snapshot.copyWith(
                  phase: TranslationPhase.translating,
                  translatedText: snapshot.translatedText + addition,
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
                  message: message,
                );
            }
            notifyListeners();
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
