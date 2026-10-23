import 'dart:async';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/paragraph_translation.dart';
import 'package:translate_app/src/translation/segmented_translation.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 按真实段落提供事件流；未定义的段落直接失败，避免额外请求被测试吞掉。
class _Provider implements TranslationProvider {
  _Provider(this.responses);

  final Map<String, Stream<TranslationEvent>> responses;

  @override
  String get id => 'paragraph-test';
  @override
  bool get usesSlidingContext => false;

  /// request 为段落及语言方向；返回对应事件流，意外的段落请求抛出错误。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      responses[request.sourceText] ??
      (throw StateError('Unexpected paragraph: ${request.sourceText}'));
}

/// 批量接口的测试替身：记录每次批量请求，按 reply 给出事件；reply 缺省时每段译文为「译」加原文（#113）。
class _BatchProvider implements BatchTranslationProvider {
  _BatchProvider([this.reply]);

  final List<BatchTranslationEvent> Function(BatchTranslationRequest request)?
  reply;
  final requests = <BatchTranslationRequest>[];

  @override
  String get id => 'batch-test';
  @override
  bool get usesSlidingContext => false;
  @override
  bool get allowsParallelBatches => false;

  /// request 为单篇请求；translateParagraphBatches 只调用批量接口，这里不应被调用。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      throw StateError('single request is not expected');

  /// request 为一批段落，client 为单篇翻译共用的连接；记录请求并返回脚本事件。
  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    requests.add(request);
    return Stream.fromIterable(
      reply?.call(request) ??
          [
            for (final (index, text) in request.texts.indexed)
              BatchItemUpdate(index, '译$text'),
            const BatchCompleted(),
          ],
    );
  }
}

/// 无参数；验证段落合并、失败、同语言与取消的真实流结果。
void main() {
  test('按段落分批：段落数与字符数上限先到为准，超长段自成一批，分隔符与配对保持原文顺序（#113）', () async {
    // 边界：25 段、上限 20 段时为 20 + 5 两批；字符上限 25、每段 10 字时每批 2 段，30 字的段落单独一批；
    // 空白行与行尾留在分隔符里，译文按原文顺序拼接，配对覆盖完整原文；上一片尾部随每批请求携带。
    final lines = [
      for (var i = 0; i < 25; i++) 'line-${i.toString().padLeft(4, '0')}',
    ];
    final source =
        '${lines.take(2).join('\n\n')}\n${lines.skip(2).join('\n')}\n';
    final byCount = _BatchProvider();
    final events = await translateParagraphBatches(
      byCount,
      TranslationRequest(
        sourceText: source,
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        previousSourceTail: '前一片原文',
        previousTranslationTail: '前一片译文',
      ),
      maxItems: 20,
      maxChars: 5000,
    ).toList();
    expect(byCount.requests.map((request) => request.texts.length), [20, 5]);
    expect(
      byCount.requests.map((request) => request.previousSourceTail).toSet(),
      {'前一片原文'},
    );
    final expected =
        '${lines.take(2).map((line) => '译$line').join('\n\n')}\n'
        '${lines.skip(2).map((line) => '译$line').join('\n')}\n';
    expect(
      events
          .whereType<TranslationUpdate>()
          .map((event) => event.addition)
          .join(),
      expected,
    );
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(pairs.map((pair) => pair.source).join(), source);
    expect(pairs.map((pair) => pair.translation).join(), expected);

    final byChars = _BatchProvider();
    await translateParagraphBatches(
      byChars,
      TranslationRequest(
        sourceText:
            'aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n${'d' * 30}\neeeeeeeeee',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
      maxItems: null,
      maxChars: 25,
    ).toList();
    expect(byChars.requests.map((request) => request.texts.length), [
      2,
      1,
      1,
      1,
    ]);
  });

  test('批量有段落没有译文或整批失败时整片失败，后续批次不再请求；同语言不发请求（#113）', () async {
    // 边界：两段中只返回第 1 段译文即视为段落数对不上；第一批失败后第二批不发送；原文已是目标语言时不调用批量接口。
    const request = TranslationRequest(
      sourceText: 'A\nB\nC',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );
    final missing = _BatchProvider(
      (_) => [const BatchItemUpdate(0, '甲'), const BatchCompleted()],
    );
    final mismatched = await translateParagraphBatches(
      missing,
      request,
      maxItems: 2,
      maxChars: 100,
    ).toList();
    expect(
      (mismatched.single as TranslationFailure).message,
      '服务返回的段落数与原文不一致，请重试。',
    );
    expect(missing.requests, hasLength(1));
    final failing = _BatchProvider(
      (_) => [const BatchFailure('认证失败', TranslationFailureKind.service)],
    );
    final failed = await translateParagraphBatches(
      failing,
      request,
      maxItems: 2,
      maxChars: 100,
    ).toList();
    expect((failed.single as TranslationFailure).message, '认证失败');
    expect(failing.requests, hasLength(1));
    final same = _BatchProvider();
    final passthrough = await translateParagraphBatches(
      same,
      const TranslationRequest(
        sourceText: '你好\n世界',
        detectedLanguage: 'zh-CN',
        targetLanguage: 'zh-CN',
      ),
      maxItems: 2,
      maxChars: 100,
    ).toList();
    expect(same.requests, isEmpty);
    expect(
      passthrough
          .whereType<TranslationUpdate>()
          .map((event) => event.addition)
          .join(),
      '你好\n世界',
    );
  });

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
      ).toList();
      expect(
        (events.last as TranslationCompleted).pairs.map((e) => e.source).join(),
        source,
      );
      expect((events.last as TranslationCompleted).pairs, hasLength(2));
    },
  );
  test('整片请求保留 CRLF、空段与末尾换行，服务未给配对时整片作为一组对照', () async {
    // 作用：不同语言时原文整片交给服务一次请求，换行与空段原样进入请求。
    // 边界：原文含 CRLF、空段和末尾换行；只有完整原文能命中替身，按段请求会直接失败；
    // 服务完成时没有配对，结果为覆盖完整原文的一组对照。
    const source = 'First one. First two.\r\n\r\nSecond.\n';
    final events = await translateParagraphs(
      _Provider({
        source: Stream.fromIterable([
          const TranslationUpdate('第一句。第二句。\r\n\r\n'),
          const TranslationUpdate('第二段。\n'),
          const TranslationCompleted(),
        ]),
      }).translate,
      const TranslationRequest(
        sourceText: source,
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      '第一句。第二句。\r\n\r\n第二段。\n',
    );
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(pairs.map((e) => (e.source, e.translation)), [
      (source, '第一句。第二句。\r\n\r\n第二段。\n'),
    ]);
  });

  test('整片请求先给出部分译文后失败时以失败结束，不标记完成', () async {
    // 作用：服务中途失败不能把已收到的部分译文升级为完成。
    // 边界：失败前已有一条增量；结果只有增量与失败，没有完成事件。
    final events = await translateParagraphs(
      _Provider({
        'First.\nSecond.': Stream.fromIterable([
          const TranslationUpdate('第一段。'),
          const TranslationFailure('服务不可用'),
        ]),
      }).translate,
      const TranslationRequest(
        sourceText: 'First.\nSecond.',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect((events.last as TranslationFailure).message, '服务不可用');
    expect(events.whereType<TranslationCompleted>(), isEmpty);
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      '第一段。',
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
    'cancellation stops the in-flight request without waiting for it',
    () async {
      // 整片请求尚未完成时取消；不得等待后续网络事件。
      final pending = StreamController<TranslationEvent>();
      final received = Completer<void>();
      final output = <TranslationEvent>[];
      final subscription =
          translateParagraphs(
            _Provider({'First.\nSecond.': pending.stream}).translate,
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

  test('长文按 4000/6000 分包，超长段先句再硬切', () {
    final short = 'a' * 5000;
    expect(splitTranslationSegments(short), [short]);
    final packed = '${'p' * 3500}\n${'q' * 2000}';
    // 3500+2000=5500 <=6000 且超过 4000，两段并成一片。
    expect(splitTranslationSegments(packed), [packed]);
    final two = '${'a' * 4000}\n${'b' * 4000}';
    expect(splitTranslationSegments(two).length, 2);
    final hugeSentence = 'word ' * 2000; // 远超 6000
    final chunks = splitTranslationSegments(hugeSentence);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.characters.length <= 6000), isTrue);
    expect(chunks.join(), hugeSentence);
  });

  test('分段串行、模型带 1000 字尾部，Google 不带；失败可从失败片续翻', () async {
    final first = 'A' * 4000;
    final second = 'B' * 4000;
    final source = '$first\n$second';
    final seen = <TranslationRequest>[];
    Stream<TranslationEvent> translate(TranslationRequest request) {
      seen.add(request);
      if (request.sourceText.contains('B') && seen.length == 2) {
        return Stream.value(const TranslationFailure('第二片失败'));
      }
      return Stream.fromIterable([
        TranslationUpdate('T-${request.sourceText.trimLeft()[0]}'),
        const TranslationCompleted(),
      ]);
    }

    final request = TranslationRequest(
      sourceText: source,
      targetLanguage: 'zh-CN',
    );
    final progress = TranslationProgress(request);
    final failed = await translateSegmented(
      translate,
      request,
      progress: progress,
      usesSlidingContext: true,
    ).toList();
    expect(failed.last, isA<TranslationFailure>());
    expect(failed.whereType<TranslationUpdate>().map((e) => e.addition), [
      'T-A',
    ]);
    expect(seen, hasLength(2));
    expect(seen.first.previousSourceTail, isNull);
    expect(seen[1].previousSourceTail, first.substring(first.length - 1000));
    expect(seen[1].previousTranslationTail, 'T-A');

    seen.clear();
    Stream<TranslationEvent> google(TranslationRequest request) {
      seen.add(request);
      return Stream.fromIterable([
        TranslationUpdate('G-${request.sourceText[0]}'),
        const TranslationCompleted(),
      ]);
    }

    await translateSegmented(
      google,
      TranslationRequest(sourceText: source, targetLanguage: 'zh-CN'),
    ).toList();
    expect(seen.every((r) => r.previousSourceTail == null), isTrue);

    seen.clear();
    final resumed = await translateSegmented(
      translate,
      request,
      usesSlidingContext: true,
      progress: progress,
    ).toList();
    expect(resumed.last, isA<TranslationCompleted>());
    expect(seen.single.sourceText.contains('B'), isTrue);
    expect(
      seen.single.previousSourceTail,
      first.substring(first.length - 1000),
    );
    expect(seen.single.previousTranslationTail, 'T-A');
    expect(progress.completedText, 'T-AT-B');
    expect(
      (resumed.last as TranslationCompleted).pairs.map((p) => p.source).join(),
      source,
    );
  });
}
