import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/translation/glossary.dart';

/// 无参数；验证术语的整词与子串匹配、目标语言筛选、保留原文输出及设置往返与校验（#104）。
void main() {
  /// term 为原文术语；返回目标语言为简体中文、译法为「译」的条目。
  GlossaryEntry entry(String term) =>
      GlossaryEntry(term: term, translation: '译', language: 'zh-CN');

  test('拉丁字母一侧按整词、不区分大小写匹配，汉字与符号一侧按子串匹配', () {
    // 边界：API 不能命中 capital 内部；C++ 末尾是符号，后面紧跟字母仍算命中，但前面紧跟字母不算；
    // 汉字术语没有词边界，出现在更长的汉字串中也要命中。
    expect(entry('API').occursIn('Call the api, please.'), isTrue);
    expect(entry('API').occursIn('The capital city'), isFalse);
    expect(entry('API').occursIn('API_KEY'), isTrue);
    expect(entry('C++').occursIn('I write C++daily'), isTrue);
    expect(entry('C++').occursIn('ABC++'), isFalse);
    expect(entry('机器学习').occursIn('深度机器学习模型'), isTrue);
    expect(entry('Node.js').occursIn('Nodexjs'), isFalse);
  });

  test('只返回目标语言一致且在任一原文中出现的术语，保留原文时译法等于术语', () {
    // 边界：zh-Hans 与 zh-CN 规范为同一语言；法语条目即使原文命中也不进入中文请求；
    // 命中出现在批次的第二段原文中。
    final glossary = [
      const GlossaryEntry(
        term: 'Kubernetes',
        translation: '',
        language: 'zh-CN',
      ),
      const GlossaryEntry(term: 'API', translation: '接口', language: 'zh-CN'),
      const GlossaryEntry(
        term: 'API',
        translation: 'interface',
        language: 'fr',
      ),
      const GlossaryEntry(
        term: 'Swift',
        translation: 'Swift 语言',
        language: 'zh-CN',
      ),
    ];
    expect(
      glossaryHits(glossary, ['Hello', 'Run the API on kubernetes'], 'zh-Hans'),
      [
        {'term': 'Kubernetes', 'translation': 'Kubernetes'},
        {'term': 'API', 'translation': '接口'},
      ],
    );
    expect(glossaryHits(glossary, ['No terms here'], 'zh-CN'), isEmpty);
    expect(glossaryHits(const [], ['API'], 'zh-CN'), isEmpty);
  });

  test('术语表随偏好往返；同一目标语言下大小写不同的同一术语或空术语被拒绝', () {
    // 边界：API 与 api 在同一目标语言下重复；同一术语换目标语言可以共存。
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      glossary: [
        const GlossaryEntry(term: 'API', translation: '接口', language: 'zh-CN'),
        const GlossaryEntry(term: 'api', translation: 'API', language: 'ja'),
      ],
    );
    settings.validate();
    final restored = AppSettings.fromMap(settings.toMap());
    expect(
      restored.glossary.map((e) => e.toMap()),
      settings.glossary.map((e) => e.toMap()),
    );
    restored.glossary.add(
      const GlossaryEntry(term: 'api', translation: '应用接口', language: 'zh-CN'),
    );
    expect(restored.validate, throwsFormatException);
    restored.glossary
      ..removeLast()
      ..add(const GlossaryEntry(term: ' ', translation: '', language: 'zh-CN'));
    expect(restored.validate, throwsFormatException);
  });
}
