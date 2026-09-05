import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/language_direction.dart';

import 'selection_session_test.dart' show RecordingProvider;

/// 无参数；验证设置约束和异步语言识别跨越会话边界时的业务输出。
void main() {
  test('主次语言方向支持多语言、繁体中文以及无法识别的文本', () {
    // nil 必须译向主要语言；BCP-47 同语言不同地区不能误切方向。
    const direction = LanguageDirection(primaryCode: 'fr', secondaryCode: 'en');
    expect(direction.resolve('fr-CA').targetLanguage, 'en');
    expect(direction.resolve('ja').targetLanguage, 'fr');
    expect(direction.resolve(null).targetLanguage, 'fr');
    expect(
      LanguageDirection.systemDefault(languageCode: 'zh-Hant-HK').primaryCode,
      'zh-TW',
    );
  });

  test('相同语言与无系统修饰键的快捷键不能保存', () {
    // en 与 en-US 等价；Shift+A 是普通输入，不允许注册为全局翻译热键。
    final settings = AppSettings(
      primaryLanguage: 'en',
      secondaryLanguage: 'en-US',
    );
    expect(settings.validate, throwsFormatException);
    settings.secondaryLanguage = 'zh-CN';
    settings.shortcutModifiers = 512;
    expect(settings.validate, throwsFormatException);
    settings.shortcutModifiers = 6144;
    expect(settings.validate, returnsNormally);
  });

  test('语言识别期间关闭选区不会发送请求，下一选区使用已保存方向', () async {
    final detection = Completer<String?>();
    final provider = RecordingProvider();
    final session = SelectionSession(
      provider: provider,
      detectLanguage: (_) => detection.future,
      language: const LanguageDirection(primaryCode: 'fr', secondaryCode: 'en'),
    );
    session.begin(sessionId: 'old', text: 'Bonjour à tous.');
    final pending = session.activate();
    session.dismiss();
    detection.complete('fr');
    await pending;
    expect(provider.requests, isEmpty);
    session.begin(sessionId: 'new', text: 'Bonjour à tous.');
    await session.activate();
    expect(provider.requests.single.targetLanguage, 'en');
    session.dispose();
  });

  test('关闭自动按钮及排除应用可以随同快捷键一起保存和恢复', () {
    // 使用一次完整序列化往返，覆盖实际传输的嵌套排除项与自定义组合。
    final settings = AppSettings(
      primaryLanguage: 'ja',
      secondaryLanguage: 'en',
      automatic: false,
      shortcutKeyCode: 15,
      shortcutLabel: 'R',
      shortcutModifiers: 6400,
      excludedApps: {'com.apple.TextEdit': '文本编辑'},
    );
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.automatic, isFalse);
    expect(restored.excludedApps, {'com.apple.TextEdit': '文本编辑'});
    expect(restored.shortcutKeyCode, 15);
    expect(restored.shortcutLabel, 'R');
    expect(restored.direction.resolve('ja').targetLanguage, 'en');
  });
}
