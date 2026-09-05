import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/translation/language_direction.dart';

void main() {
  test('without secondary language every source targets the primary', () {
    // 已识别主语言、其他语言、未知语言三个分支都必须有有效目标语言。
    const direction = LanguageDirection(primaryCode: 'zh-CN');
    for (final source in ['zh-Hans', 'en', null]) {
      expect(direction.resolve(source).targetLanguage, 'zh-CN');
    }
  });
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
    const direction = LanguageDirection(
      primaryCode: 'zh-CN',
      secondaryCode: 'en',
    );
    final result = direction.resolve('en');
    expect(result.detectedLanguage, 'en');
    expect(result.targetLanguage, 'zh-CN');
  });

  test('chinese text goes to secondary english', () {
    const direction = LanguageDirection(
      primaryCode: 'zh-CN',
      secondaryCode: 'en',
    );
    final result = direction.resolve('zh-Hans');
    expect(result.detectedLanguage, 'zh-CN');
    expect(result.targetLanguage, 'en');
  });
}
