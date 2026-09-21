import '../common/constants/error_codes.dart';

import 'package:flutter/services.dart';

import '../history/translation_history.dart';
import '../translation/language_direction.dart';
import '../translation/segmented_translation.dart';
import '../translation/translation_types.dart';

/// text 为 OCR 原文，provider/language 为启动时配置，detectLanguage 使用本地识别，
/// isCurrent 核对截图生命周期，history 管理持久化；返回完整译文，失败或取消不写记录。
Future<String> translateScreenshotText({
  required String text,
  required TranslationProvider provider,
  required String? model,
  required LanguageDirection language,
  required Future<String?> Function(String) detectLanguage,
  required Future<bool> Function() isCurrent,
  required TranslationHistoryStore history,
}) async {
  if (text.trim().isEmpty) {
    throw PlatformException(code: ErrorCodes.ocrEmpty, message: '没有可翻译的文字。');
  }
  // 本地识别完成后再核对截图，关闭或替换的旧截图不能发起新的网络请求。
  final detected = await detectLanguage(text);
  if (!await isCurrent()) {
    throw PlatformException(
      code: ErrorCodes.staleCapture,
      message: '截图已关闭或被替换。',
    );
  }
  // 使用启动时冻结的语言方向，避免请求期间设置更新污染历史元数据。
  final direction = language.resolve(detected);
  final buffer = StringBuffer();
  var completed = false;
  // 分片只在全篇完成时报告成功；部分输出不构成一条历史记录。
  await for (final event in translateSegmented(
    provider.translate,
    TranslationRequest(
      sourceText: text,
      detectedLanguage: direction.detectedLanguage,
      targetLanguage: direction.targetLanguage,
    ),
    usesSlidingContext: provider.usesSlidingContext,
  )) {
    switch (event) {
      case TranslationUpdate(:final addition):
        buffer.write(addition);
      case TranslationCompleted():
        completed = true;
      case TranslationFailure(:final message):
        throw PlatformException(
          code: ErrorCodes.translateFailed,
          message: message,
        );
    }
  }
  if (!completed) {
    throw PlatformException(
      code: ErrorCodes.translateFailed,
      message: '服务未返回完整译文。',
    );
  }
  // 网络返回后再次核对原生 captureId，阻止已关闭截图的迟到结果写入历史。
  if (!await isCurrent()) {
    throw PlatformException(
      code: ErrorCodes.staleCapture,
      message: '截图已关闭或被替换。',
    );
  }
  final translated = buffer.toString();
  // Store 在写入时检查记录开关；关闭记录不会删除之前的结果。
  history.insert(
    sourceText: text,
    translatedText: translated,
    detectedLanguage: direction.detectedLanguage ?? '',
    targetLanguage: direction.targetLanguage,
    providerId: provider.id,
    model: model,
    completedAt: DateTime.now().millisecondsSinceEpoch,
    sourceLabel: '截图',
  );
  return translated;
}
