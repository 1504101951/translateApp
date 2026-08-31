import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/language_direction.dart';

void main() {
  test('english primary defaults secondary to simplified chinese', () {
    final direction = LanguageDirection.systemDefault(languageCode: 'en-US');
    expect(direction.primaryCode, 'en');
    expect(direction.secondaryCode, 'zh-CN');
  });

  test('chinese primary defaults secondary to english', () {
    final direction = LanguageDirection.systemDefault(languageCode: 'zh-Hans');
    expect(direction.primaryCode, 'zh-CN');
    expect(direction.secondaryCode, 'en');
  });

  test('english text goes to primary chinese', () {
    const direction = LanguageDirection(primaryCode: 'zh-CN', secondaryCode: 'en');
    final result = direction.resolve(
      'This is a sufficiently long English sentence for detection.',
    );
    expect(result.detectedLanguage, 'en');
    expect(result.targetLanguage, 'zh-CN');
  });

  test('chinese text goes to secondary english', () {
    const direction = LanguageDirection(primaryCode: 'zh-CN', secondaryCode: 'en');
    final result = direction.resolve('这是一段足够长的中文句子用来识别来源语言。');
    expect(result.detectedLanguage, 'zh-CN');
    expect(result.targetLanguage, 'en');
  });
}
