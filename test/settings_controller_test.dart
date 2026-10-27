import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/platform/settings_platform.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/settings/service_config.dart';
import 'package:translate_app/src/settings/settings_controller.dart';

/// 无参数；验证唯一设置队列的状态提交、真实存储失败、修订冲突与系统翻译的测试连接，无返回值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File saved;
  late SettingsController controller;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('settings-controller-');
    saved = File('${directory.path}/preferences/settings.json');
    saved.parent.createSync();
    controller = SettingsController(
      initial: AppSettings(primaryLanguage: 'zh-CN'),
      platform: _FileSettingsPlatform(saved),
      onSaved: (_) {},
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('外部草稿、协议快照和通知接收方不能绕过提交修改有效配置', () async {
    // 排除项包含可变字典；同时覆盖对象字段和嵌套集合，防止仅复制顶层引用。
    final initial = AppSettings(
      primaryLanguage: 'zh-CN',
      excludedApps: {'com.example.editor': '编辑器'},
    );
    controller = SettingsController(
      initial: initial,
      platform: _FileSettingsPlatform(saved),
      onSaved: (published) {
        // 通知接收方可以编辑自己的副本，但不能改写已提交配置。
        published.primaryLanguage = 'ja';
        published.excludedApps.clear();
      },
    );
    initial.primaryLanguage = 'en';
    initial.excludedApps.clear();
    final draft = controller.current;
    draft.automatic = false;
    draft.excludedApps.clear();
    final snapshot = await controller.handle(
      const MethodCall(MethodNames.getSettings),
    ) as Map;
    (snapshot[PreferenceKeys.excludedApps] as Map).clear();

    // 尚未提交时，外部的三种修改既不改变业务配置，也不创建系统偏好文件。
    expect(controller.current.primaryLanguage, 'zh-CN');
    expect(controller.current.automatic, isTrue);
    expect(controller.current.excludedApps, {'com.example.editor': '编辑器'});
    expect(snapshot['revision'], 0);
    expect(saved.existsSync(), isFalse);

    final committed = await controller.handle(
      const MethodCall(MethodNames.toggleAutomatic),
    ) as Map;
    expect(committed['revision'], 1);
    expect(controller.current.automatic, isFalse);
    expect(controller.current.primaryLanguage, 'zh-CN');
    expect(controller.current.excludedApps, {'com.example.editor': '编辑器'});
    final persisted = jsonDecode(saved.readAsStringSync()) as Map;
    expect(persisted[PreferenceKeys.primaryLanguage], 'zh-CN');
    expect(persisted[PreferenceKeys.excludedApps], {
      'com.example.editor': '编辑器',
    });
  });

  test('录制选项：截图工具栏保存延时与点击高亮，其他设置保持不变，非法延时不提交（#129）', () async {
    // 边界：5 秒与显示点击写入后修订加一、主语言不变；4 秒不在 0/3/5/10 中，校验失败且保留上一修订的值。
    final committed = await controller.handle(
      MethodCall(MethodNames.saveRecordingOptions, {
        PreferenceKeys.recordingDelay: 5,
        PreferenceKeys.recordingShowsClicks: true,
      }),
    ) as Map;
    expect(committed['revision'], 1);
    expect(controller.current.recordingDelay, 5);
    expect(controller.current.recordingShowsClicks, isTrue);
    expect(controller.current.primaryLanguage, 'zh-CN');
    await expectLater(
      controller.handle(
        MethodCall(MethodNames.saveRecordingOptions, {
          PreferenceKeys.recordingDelay: 4,
          PreferenceKeys.recordingShowsClicks: false,
        }),
      ),
      throwsFormatException,
    );
    expect(controller.current.recordingDelay, 5);
    expect(controller.current.recordingShowsClicks, isTrue);
  });

  test('存储目录不可用时不发布配置，修复目录后下一次提交成功', () async {
    // 用真实文件阻断父目录；失败来自文件系统，不伪造平台异常或检查下游调用次数。
    saved.parent.deleteSync();
    final obstruction = File(saved.parent.path)..writeAsStringSync('occupied');
    await expectLater(
      controller.handle(const MethodCall(MethodNames.toggleAutomatic)),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.current.automatic, isTrue);
    final failed = await controller.handle(
      const MethodCall(MethodNames.getSettings),
    ) as Map;
    expect(failed['revision'], 0);
    expect(saved.existsSync(), isFalse);

    // 清除真实阻塞后复用同一队列；成功边界是系统文件、配置和修订同时更新。
    obstruction.deleteSync();
    saved.parent.createSync();
    final recovered = await controller.handle(
      const MethodCall(MethodNames.toggleAutomatic),
    ) as Map;
    expect(recovered['revision'], 1);
    expect(controller.current.automatic, isFalse);
    expect(
      jsonDecode(saved.readAsStringSync())[PreferenceKeys.automatic],
      isFalse,
    );
  });

  test('同一修订的并发草稿只接受首个提交，过期草稿不覆盖系统文件', () async {
    // 两个窗口都从修订0开始；第一份成功后，第二份必须按执行时的修订1拒绝。
    final first = controller.handle(
      MethodCall(MethodNames.saveSettings, {
        ...controller.current.toMap(),
        'revision': 0,
        PreferenceKeys.gifFramesPerSecond: 24,
      }),
    );
    final conflict = expectLater(
      controller.handle(
        MethodCall(MethodNames.saveSettings, {
          ...controller.current.toMap(),
          'revision': 0,
          PreferenceKeys.gifFramesPerSecond: 20,
        }),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.settingsConflict,
        ),
      ),
    );
    expect((await first as Map)['revision'], 1);
    await conflict;
    expect(controller.current.gifFramesPerSecond, 24);
    expect(
      jsonDecode(saved.readAsStringSync())[PreferenceKeys.gifFramesPerSecond],
      24,
    );
  });

  test('连续菜单切换按提交顺序读取最新状态，失败校验不占用修订', () async {
    // 连续两次切换应恢复初值且产生两个修订，不能都读取调用时的旧状态。
    final changes = await Future.wait([
      controller.handle(const MethodCall(MethodNames.toggleAutomatic)),
      controller.handle(const MethodCall(MethodNames.toggleAutomatic)),
    ]);
    expect((changes[0] as Map)[PreferenceKeys.automatic], isFalse);
    expect((changes[1] as Map)[PreferenceKeys.automatic], isTrue);
    expect((changes[1] as Map)['revision'], 2);

    // 31超过GIF帧率上限30；业务校验失败后仍可用修订2提交合法配置。
    await expectLater(
      controller.handle(
        MethodCall(MethodNames.saveSettings, {
          ...controller.current.toMap(),
          'revision': 2,
          PreferenceKeys.gifFramesPerSecond: 31,
        }),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.invalidSettings,
        ),
      ),
    );
    final next = await controller.handle(
      MethodCall(MethodNames.saveSettings, {
        ...controller.current.toMap(),
        'revision': 2,
        PreferenceKeys.gifFramesPerSecond: 30,
      }),
    ) as Map;
    expect(next['revision'], 3);
    expect(controller.current.gifFramesPerSecond, 30);
  });

  group('Apple 系统翻译测试连接', () {
    const methods = MethodChannel(ChannelNames.macos);
    const apple = ServiceConfig(
      id: 'apple-local',
      kind: 'apple',
      name: 'Apple 系统翻译',
      baseUrl: '',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// statuses 以「源>目标」为键给出假原生的语言包状态，未列出的语言对视为已安装。
    void nativeStatuses(Map<String, String> statuses) {
      messenger.setMockMethodCallHandler(methods, (call) async {
        final pairs = (call.arguments as Map)['pairs'] as List;
        return [
          for (final pair in pairs)
            statuses['${pair[0]}>${pair[1]}'] ?? 'installed',
        ];
      });
    }

    /// primary/secondary 为已提交的主次语言；返回测试连接结果，失败时抛出 PlatformException。
    Future<Object?> testApple(String primary, [String? secondary]) =>
        SettingsController(
          initial: AppSettings(
            primaryLanguage: primary,
            secondaryLanguage: secondary,
          ),
          platform: _FileSettingsPlatform(saved),
          onSaved: (_) {},
        ).handle(
          MethodCall(MethodNames.testService, {
            'config': apple.toMap(),
            'credentials': <String, String>{},
          }),
        );

    tearDown(() => messenger.setMockMethodCallHandler(methods, null));

    test('设置次要语言时检查双向，只列出未安装的语言对并给出下载位置', () async {
      // 边界：supported 表示系统支持但未下载，是「缺少语言包」的唯一状态。
      nativeStatuses({'en>zh-CN': 'supported'});
      await expectLater(
        testApple('zh-CN', 'en'),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', ErrorCodes.testFailed)
              .having(
                (error) => error.message,
                'message',
                '缺少语言包：English → 简体中文。请到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载。',
              ),
        ),
      );
    });

    test('不支持的语言对优先于未安装提示', () async {
      // 边界：两向都不支持时同时存在未安装项，也只报告不支持，避免引导用户下载无用的语言包。
      nativeStatuses({
        'zh-CN>zh-TW': 'unsupported',
        'zh-TW>zh-CN': 'unsupported',
      });
      await expectLater(
        testApple('zh-CN', 'zh-TW'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.message,
            'message',
            'Apple 系统翻译不支持：简体中文 → 繁體中文、繁體中文 → 简体中文。',
          ),
        ),
      );
    });

    test('未设置次要语言时检查英文译为主要语言，全部安装时返回已安装说明', () async {
      // 边界：主要语言非英文且无次要语言，唯一需要的语言对是测试文本 Hello world. 的方向。
      nativeStatuses({});
      expect(await testApple('ja'), '语言包已安装：English → 日本語');
    });

    test('主要语言为英文且未设置次要语言时没有可检查的语言对', () async {
      // 边界：测试文本与目标语言同为英文，不存在需要语言包的方向。
      nativeStatuses({'en>en': 'unsupported'});
      expect(await testApple('en'), '主要语言为英文且未设置次要语言，翻译时按原文语言检查语言包。');
    });
  });
}

/// 测试用文件存储边界；偏好通过真实文件系统提交，凭据仅存在该测试实例内。
class _FileSettingsPlatform implements SettingsPlatform {
  /// destination为测试私有偏好文件；构造不创建文件或父目录。
  _FileSettingsPlatform(this.destination);

  final File destination;
  final Map<String, Map<String, String>> _credentials = {};

  /// settings为完整偏好，credentials为账户变更；真实文件写入成功后才更新内存凭据。
  @override
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  }) async {
    await destination.writeAsString(jsonEncode(settings));
    for (final entry in credentials.entries) {
      final value = entry.value;
      if (value == null) {
        _credentials.remove(entry.key);
      } else {
        _credentials[entry.key] = Map.of(value);
      }
    }
  }

  /// id为测试账户；返回隔离的凭据副本，未创建账户返回空字典。
  @override
  Future<Map<String, String>> readCredentials(String id) async =>
      Map.of(_credentials[id] ?? {});

  /// ids为待查询账户；返回该测试存储中已提交的账户ID，不暴露内容。
  @override
  Future<List<String>> credentialIds(List<String> ids) async =>
      ids.where(_credentials.containsKey).toList();
}
