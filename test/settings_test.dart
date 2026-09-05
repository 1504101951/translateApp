import 'dart:async';
import 'dart:convert';

import 'package:translate_app/src/settings/service_config.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/language_direction.dart';

import 'selection_session_test.dart' show RecordingProvider;

/// 无参数；验证设置约束和异步语言识别跨越会话边界时的业务输出。
void main() {
  test('普通设置不读取密钥，凭据修改只合并对应服务，删除保留删除标记', () async {
    // 已有服务仅修改普通偏好时 reader 不可访问；只有用户提交密钥才触及钥匙串。
    const saved = ServiceConfig(
      id: 'saved',
      kind: 'baidu',
      name: '百度',
      baseUrl: 'https://fanyi-api.baidu.com',
    );
    final untouched = await prepareCredentialChanges(
      previous: [saved],
      current: [saved],
      drafts: {'saved': {}},
      readCredentials: (_) async => throw StateError('普通设置不应读取密钥'),
    );
    expect(untouched, isEmpty);
    // 同一 ID 不可更换协议并沿用旧密钥，拒绝前也不应触发钥匙串读取。
    await expectLater(
      prepareCredentialChanges(
        previous: [saved],
        current: [
          const ServiceConfig(
            id: 'saved',
            kind: 'deepseek',
            name: 'DeepSeek',
            baseUrl: 'https://api.deepseek.com',
            model: 'test',
          ),
        ],
        drafts: {},
        readCredentials: (_) async => throw StateError('跨协议不应读取旧密钥'),
      ),
      throwsFormatException,
    );
    final changed = await prepareCredentialChanges(
      previous: [saved],
      current: [saved],
      drafts: {
        'saved': {'apiKey': 'new'},
      },
      readCredentials: (_) async => {'appId': 'app', 'apiKey': 'old'},
    );
    expect(changed, {
      'saved': {'appId': 'app', 'apiKey': 'new'},
    });
    final removed = await prepareCredentialChanges(
      previous: [saved],
      current: [],
      drafts: {},
      readCredentials: (_) async => throw StateError('删除不应在 Dart 读取密钥'),
    );
    expect(removed, {'saved': null});
    // 新服务无任何密钥必须失败，不能绕过协议必填项检查。
    await expectLater(
      prepareCredentialChanges(
        previous: [],
        current: [saved],
        drafts: {},
        readCredentials: (_) async => throw StateError('新服务没有旧密钥'),
      ),
      throwsFormatException,
    );
  });

  test('secondary language can be cleared and remains absent after saving', () {
    // 用户已有次要语言，再主动清空；完整偏好往返后不能悄悄恢复默认值。
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      secondaryLanguage: 'en',
    );
    settings.secondaryLanguage = null;
    settings.validate();
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.secondaryLanguage, isNull);
    expect(restored.direction.resolve('zh-CN').targetLanguage, 'zh-CN');
  });
  test('服务配置只持久化非敏感字段，默认项必须存在，地址拒绝凭据与远程 HTTP', () {
    const service = ServiceConfig(
      id: 'baidu-personal',
      kind: 'baidu',
      name: '我的百度',
      baseUrl: 'https://fanyi-api.baidu.com',
    );
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      secondaryLanguage: 'en',
      services: [service],
      defaultServiceId: service.id,
    );
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.defaultServiceId, service.id);
    expect(restored.services.single.name, '我的百度');
    final serialized = jsonEncode(settings.toMap());
    expect(serialized, isNot(contains('apiKey')));
    expect(serialized, isNot(contains('appId')));
    expect(settings.validate, returnsNormally);
    settings.services.clear();
    expect(settings.validate, throwsFormatException);
    for (final address in [
      'http://example.com',
      'https://user:secret@example.com',
      'https://example.com?key=secret',
      'https://example.com#secret',
    ]) {
      expect(
        () => ServiceConfig(
          id: 'invalid',
          kind: 'google',
          name: 'Google',
          baseUrl: address,
        ).validate(),
        throwsFormatException,
      );
    }
    expect(
      () => service.validateCredentials({'apiKey': 'dummy'}),
      throwsFormatException,
    );
    expect(
      () => service.validateCredentials({'apiKey': 'dummy', 'appId': 'app'}),
      returnsNormally,
    );
  });

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
