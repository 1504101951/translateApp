import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/settings/service_config.dart';
import 'package:translate_app/src/translation/providers/apple_translation_provider.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 无参数；用假原生通道验证 Apple 系统翻译的段落配对、错误文案与类别、取消后的输出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(ChannelNames.macos);
  const config = ServiceConfig(
    id: 'apple-local',
    kind: 'apple',
    name: 'Apple 系统翻译',
    baseUrl: '',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppleTranslationProvider provider;

  /// handler 为假原生翻译：收到 systemTranslate 的段落列表并返回译文或抛出错误，取消请求直接完成。
  void nativeTranslate(Future<Object?> Function(List<String> texts) handler) {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == MethodNames.cancelSystemTranslation) return null;
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      return handler(List<String>.from(arguments['texts'] as List));
    });
  }

  setUp(() => provider = AppleTranslationProvider(config: config));
  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('多段原文按下标配对，译文保留原文的空行与首尾空白', () async {
    // 边界：首段带前导空白、段间有空行、末段带尾随空白和换行，拼接后的原文必须与输入逐字一致。
    const source = '  Hello world.\n\nSecond line.  \n';
    nativeTranslate((texts) async => [for (final text in texts) '译:$text']);
    final events = await provider
        .translate(
          const TranslationRequest(
            sourceText: source,
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    final text = [
      for (final event in events)
        if (event is TranslationUpdate) event.addition,
    ].join();
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(text, '  译:Hello world.\n\n译:Second line.  \n');
    expect(pairs.map((pair) => pair.source).join(), source);
    expect(pairs.map((pair) => pair.translation).join(), text);
    expect(pairs.map((pair) => pair.translation.trim()), [
      '译:Hello world.',
      '译:Second line.',
    ]);
  });

  test('原文语言无法识别时直接失败，单篇与批量文案一致且批量按单段放弃', () async {
    // 边界：detectedLanguage 为 null 是无界面会话无法处理的唯一源语言取值。
    nativeTranslate((_) async => throw StateError('原文语言未知时不应进入原生翻译'));
    final single = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Bonjour',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect((single.single as TranslationFailure).message, '无法识别原文语言。');
    final client = HttpClient();
    addTearDown(client.close);
    final batch = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Bonjour'],
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    final failure = batch.single as BatchFailure;
    expect(failure.message, '无法识别原文语言。');
    expect(failure.kind, TranslationFailureKind.paragraph);
  });

  test('语言包未安装时提示缺少的语言对与下载位置，实时翻译按服务级停止', () async {
    // 边界：notInstalled 对同一语言对的后续请求同样成立，因此必须是服务级而非可重试。
    nativeTranslate(
      (_) async =>
          throw PlatformException(code: ErrorCodes.translationNotInstalled),
    );
    const message = '缺少「English → 简体中文」语言包，请到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载。';
    final single = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Hello',
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect((single.single as TranslationFailure).message, message);
    final client = HttpClient();
    addTearDown(client.close);
    final batch = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Hello'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    final failure = batch.single as BatchFailure;
    expect(failure.message, message);
    expect(failure.kind, TranslationFailureKind.service);
  });

  test('不支持的语言对为服务级失败，其余原生错误为可重试的临时失败', () async {
    // 边界：简体与繁体中文互译是系统明确不支持的语言对；未知错误码代表框架内部失败。
    final client = HttpClient();
    addTearDown(client.close);
    nativeTranslate(
      (_) async =>
          throw PlatformException(code: ErrorCodes.translationUnsupported),
    );
    final unsupported = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['简体'],
            detectedLanguage: 'zh-CN',
            targetLanguage: 'zh-TW',
          ),
          client: client,
        )
        .toList();
    final rejected = unsupported.single as BatchFailure;
    expect(rejected.message, 'Apple 系统翻译不支持「简体中文 → 繁體中文」。');
    expect(rejected.kind, TranslationFailureKind.service);

    nativeTranslate(
      (_) async => throw PlatformException(code: ErrorCodes.translateFailed),
    );
    final failed = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Hello'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    final transient = failed.single as BatchFailure;
    expect(transient.message, 'Apple 系统翻译失败，请重试。');
    expect(transient.kind, TranslationFailureKind.transient);
  });

  test('实时翻译批量按下标发布各段译文后整批完成', () async {
    // 边界：三段覆盖首、中、尾下标，每段译文只能落在自己的下标上。
    nativeTranslate((texts) async => [for (final text in texts) '$text!']);
    final client = HttpClient();
    addTearDown(client.close);
    final events = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['a', 'b', 'c'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    expect(events.last, isA<BatchCompleted>());
    expect(
      [
        for (final event in events.whereType<BatchItemUpdate>())
          (event.index, event.addition),
      ],
      [(0, 'a!'), (1, 'b!'), (2, 'c!')],
    );
  });

  test('取消订阅后迟到的原生译文不再输出', () async {
    // 边界：原生在取消之后才返回成功结果，这是本机计算无法立即中止时的最晚时刻。
    final reply = Completer<List<String>>();
    final requested = Completer<void>();
    nativeTranslate((_) {
      requested.complete();
      return reply.future;
    });
    final client = HttpClient();
    addTearDown(client.close);
    final received = <BatchTranslationEvent>[];
    final subscription = provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Hello'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .listen(received.add);
    await requested.future;
    await subscription.cancel();
    reply.complete(['你好']);
    await pumpEventQueue();
    expect(received, isEmpty);
  });
}
