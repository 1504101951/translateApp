import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/providers/unofficial_google_provider.dart';
import 'package:translate_app/src/translation/translation_types.dart';

void main() {
  test('parses single sentence fixture', () {
    const body = r'''[[["你好","Hello",null,null,10]],null,"en"]''';
    expect(UnofficialGoogleProvider.parseTranslatedText(body), '你好');
  });

  test('concatenates multi sentence fixture', () {
    const body =
        r'''[[["第一句。","First.",null,null,3],["第二句。","Second.",null,null,3]],null,"en"]''';
    expect(UnofficialGoogleProvider.parseTranslatedText(body), '第一句。第二句。');
  });

  test('http error becomes failure without completed', () async {
    final provider = UnofficialGoogleProvider(
      httpPost: (url, body, headers) async => (status: 429, body: 'rate limit'),
    );
    final events = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Hello',
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect(events, hasLength(1));
    expect(events.first, isA<TranslationFailure>());
    expect((events.first as TranslationFailure).message.contains('429'), isTrue);
  });

  test('unconfigured provider id is unofficial-google', () {
    expect(UnofficialGoogleProvider().id, 'unofficial-google');
  });
}
