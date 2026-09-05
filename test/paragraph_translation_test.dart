import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/paragraph_translation.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 按真实段落提供事件流；未定义的段落直接失败，避免额外请求被测试吞掉。
class _Provider implements TranslationProvider {
  _Provider(this.responses);

  final Map<String, Stream<TranslationEvent>> responses;

  @override
  String get id => 'paragraph-test';

  /// request 为段落及语言方向；返回对应事件流，意外的段落请求抛出错误。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      responses[request.sourceText] ??
      (throw StateError('Unexpected paragraph: ${request.sourceText}'));
}

/// 无参数；验证段落合并、失败、同语言与取消的真实流结果。
void main() {
  test(
    'semantic models retain full source context and validated pairs',
    () async {
      // 模型对齐需要完整上下文；只有整篇请求能取得结果，逐段请求会直接使测试失败。
      const source = 'First.\nSecond.';
      final events = await translateParagraphs(
        _Provider({
          source: Stream.fromIterable([
            const TranslationUpdate('第一段。\n第二段。'),
            const TranslationCompleted(
              pairs: [
                TranslationPair('First.', '第一段。'),
                TranslationPair('\nSecond.', '\n第二段。'),
              ],
            ),
          ]),
        }).translate,
        const TranslationRequest(
          sourceText: source,
          detectedLanguage: 'en',
          targetLanguage: 'zh-CN',
        ),
        keepWholeSource: true,
      ).toList();
      expect(
        (events.last as TranslationCompleted).pairs.map((e) => e.source).join(),
        source,
      );
      expect((events.last as TranslationCompleted).pairs, hasLength(2));
    },
  );
  test('keeps paragraph gaps and validated semantic subdivisions', () async {
    // CRLF、空段和末尾换行都必须保留；一段可含两组语义对照，另一段没有模型配对。
    final events = await translateParagraphs(
      _Provider({
        'First one. First two.': Stream.fromIterable([
          const TranslationUpdate('第一句。'),
          const TranslationUpdate('第二句。'),
          const TranslationCompleted(
            pairs: [
              TranslationPair('First one. ', '第一句。'),
              TranslationPair('First two.', '第二句。'),
            ],
          ),
        ]),
        'Second.': Stream.fromIterable([
          const TranslationUpdate('第二段。'),
          const TranslationCompleted(),
        ]),
      }).translate,
      const TranslationRequest(
        sourceText: 'First one. First two.\r\n\r\nSecond.\n',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      '第一句。第二句。\r\n\r\n第二段。\n',
    );
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(
      pairs.map((e) => e.source).join(),
      'First one. First two.\r\n\r\nSecond.\n',
    );
    expect(pairs.map((e) => e.translation), ['第一句。', '第二句。', '\r\n\r\n第二段。\n']);
  });

  test('failure ends the translation before later paragraphs', () async {
    // 第二段失败后不能翻译第三段，也不能把部分结果标为完成。
    final events = await translateParagraphs(
      _Provider({
        'First.': Stream.fromIterable([
          const TranslationUpdate('第一段。'),
          const TranslationCompleted(),
        ]),
        'Second.': Stream.value(const TranslationFailure('服务不可用')),
      }).translate,
      const TranslationRequest(
        sourceText: 'First.\nSecond.\nThird.',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect((events.last as TranslationFailure).message, '服务不可用');
    expect(events.whereType<TranslationCompleted>(), isEmpty);
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      '第一段。\n',
    );
  });

  test('text already in the target language keeps exact content', () async {
    // 同语言文本不依赖 Provider；缩进、空行和末尾空白也不能被规范化掉。
    const source = '  第一段。\n\n第二段。\n ';
    final events = await translateParagraphs(
      _Provider({}).translate,
      const TranslationRequest(
        sourceText: source,
        detectedLanguage: 'zh-CN',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      source,
    );
    expect((events.last as TranslationCompleted).pairs, hasLength(2));
  });

  test(
    'cancellation stops the current stream and remaining paragraphs',
    () async {
      // 第一段尚未完成时取消；不得等待后续网络事件或执行下一段。
      final pending = StreamController<TranslationEvent>();
      final received = Completer<void>();
      final output = <TranslationEvent>[];
      final subscription =
          translateParagraphs(
            _Provider({'First.': pending.stream}).translate,
            const TranslationRequest(
              sourceText: 'First.\nSecond.',
              targetLanguage: 'zh-CN',
            ),
          ).listen((event) {
            output.add(event);
            received.complete();
          });
      pending.add(const TranslationUpdate('部分译文'));
      await received.future;
      await subscription.cancel().timeout(const Duration(seconds: 3));
      await pending.close();
      expect(output, hasLength(1));
      expect((output.single as TranslationUpdate).addition, '部分译文');
    },
  );
}
