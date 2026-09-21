import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/history/translation_history.dart';
import 'package:translate_app/src/screenshot/screenshot_translation.dart';
import 'package:translate_app/src/translation/language_direction.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 用受控事件驱动真实截图翻译业务；不替换历史库或成功判断。
class _Provider extends TranslationProvider {
  /// events 为一次请求产生的完整业务事件序列。
  _Provider(this.events);
  final Stream<TranslationEvent> events;
  @override
  String get id => 'test-model';

  /// request 为 OCR 原文及方向；返回受控事件流以覆盖完成、失败及取消边界。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) => events;
}

/// 无参数；验证截图来源记录只在全篇完成且截图有效时产生。
void main() {
  test('完整截图译文落库，重复翻译分别记录，关闭开关后只返回译文', () async {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(database);
    // 主要语言命中时要记录次要目标语言；同一原文翻译三次检验不去重及开关。
    for (var i = 0; i < 3; i++) {
      if (i == 2) store.recordingEnabled = false;
      final translated = await translateScreenshotText(
        text: '你好',
        provider: _Provider(
          Stream.fromIterable([
            const TranslationUpdate('Hello'),
            const TranslationCompleted(),
          ]),
        ),
        model: 'example-model',
        language: const LanguageDirection(
          primaryCode: 'zh-CN',
          secondaryCode: 'en',
        ),
        detectLanguage: (_) async => 'zh-Hans',
        isCurrent: () async => true,
        history: store,
      );
      expect(translated, 'Hello');
    }
    expect(store.page(), hasLength(2));
    final row = store.page().first;
    expect(row.sourceLabel, '截图');
    expect(row.targetLanguage, 'en');
    expect(row.detectedLanguage, 'zh-CN');
    expect(row.model, 'example-model');
  });

  test('部分流结束、业务失败和关闭截图的迟到成功均不写入', () async {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(database);
    // 三种非成功边界使用同一真实流程；只改变实际输入的事件和截图生命周期。
    for (final ending in ['incomplete', 'failed', 'closed']) {
      final events = StreamController<TranslationEvent>();
      var current = true;
      final started = Completer<void>();
      final translation = translateScreenshotText(
        text: 'Hello',
        provider: _Provider(events.stream),
        model: null,
        language: const LanguageDirection(primaryCode: 'zh-CN'),
        detectLanguage: (_) async => 'en',
        isCurrent: () async {
          if (!started.isCompleted) started.complete();
          return current;
        },
        history: store,
      );
      final assertion = expectLater(
        translation,
        throwsA(isA<PlatformException>()),
      );
      await started.future;
      events.add(const TranslationUpdate('部分'));
      if (ending == 'failed') events.add(const TranslationFailure('无有效结果'));
      if (ending == 'closed') {
        current = false;
        events.add(const TranslationCompleted());
      }
      await events.close();
      await assertion;
      expect(store.page(), isEmpty);
    }
  });
}
