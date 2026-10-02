import 'package:flutter/services.dart';

import '../common/constants/method_names.dart';
import 'translation_history.dart';

/// history为主引擎唯一存储，call为分页或记录开关请求；返回记录字典列表、布尔值或null。
Object? handleHistoryRequest(TranslationHistoryStore history, MethodCall call) {
  switch (call.method) {
    case MethodNames.historyPage:
      final map = Map<Object?, Object?>.from(call.arguments as Map? ?? {});
      final cursor = map['before'] as Map?;
      // page使用固定10条和时间/ID双游标，新插入记录不会挤动已读页面。
      return [
        for (final row in history.page(
          before: cursor == null
              ? null
              : (
                  completedAt: cursor['completedAt'] as int,
                  id: cursor['id'] as int,
                ),
        ))
          {
            'id': row.id,
            'sourceText': row.sourceText,
            'translatedText': row.translatedText,
            'detectedLanguage': row.detectedLanguage,
            'targetLanguage': row.targetLanguage,
            'providerId': row.providerId,
            'model': row.model,
            'completedAt': row.completedAt,
            'sourceLabel': row.sourceLabel,
          },
      ];
    case MethodNames.historyRecording:
      return history.recordingEnabled;
    case MethodNames.setHistoryRecording:
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      // Store在完整翻译落库时读取同一开关，不依赖设置提交或服务测试的进度。
      history.recordingEnabled = map['enabled'] == true;
      return null;
    default:
      throw MissingPluginException('未知历史操作：${call.method}');
  }
}
