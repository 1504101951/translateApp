import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../translation/language_direction.dart';
import '../translation/translation_types.dart';

/// Dart 侧 Selection Session。激活前不请求 Provider。
class SelectionSession extends ChangeNotifier {
  SelectionSession({required this.provider, LanguageDirection? language})
    : language = language ?? LanguageDirection.systemDefault();

  static const selectionLimit = 50000;

  final TranslationProvider provider;
  final LanguageDirection language;

  TranslationSnapshot snapshot = TranslationSnapshot.idle;
  String? sessionId;
  int _generation = 0;
  StreamSubscription<TranslationEvent>? _translation;
  Completer<void>? _completion;

  /// sessionId 标识选区，text 为原文；进入触发态或空闲态，无返回值。
  void begin({required String sessionId, required String? text}) {
    this.sessionId = sessionId;
    // 新选区结束旧请求，避免后台继续消耗连接。
    _cancelTranslation();
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

  /// 无参数；翻译当前选区，Future 在请求结束或会话被取消时完成。
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
