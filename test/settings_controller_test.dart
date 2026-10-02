import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/platform/settings_platform.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/settings/settings_controller.dart';

/// 无参数；验证唯一设置队列的状态提交、真实存储失败和修订冲突，无返回值。
void main() {
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
