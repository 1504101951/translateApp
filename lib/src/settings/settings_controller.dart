import 'package:flutter/services.dart';

import '../common/constants/error_codes.dart';
import '../common/constants/method_names.dart';
import '../common/constants/preference_keys.dart';
import '../platform/settings_platform.dart';
import '../translation/providers/api_translation_provider.dart';
import '../translation/translation_types.dart';
import 'app_settings.dart';
import 'service_config.dart';

/// 主引擎的唯一设置所有者；串行提交偏好和凭据，系统成功后才公开新快照。
class SettingsController {
  /// initial为已加载偏好，platform提供系统事务，onSaved接收提交后的独立副本；构造复制偏好但不写入系统。
  SettingsController({
    required AppSettings initial,
    required this.platform,
    required this.onSaved,
  }) : _current = AppSettings.fromMap(initial.toMap());

  final SettingsPlatform platform;
  final void Function(AppSettings) onSaved;
  AppSettings _current;
  int _revision = 0;
  Future<void> _queue = Future.value();
  String? error;

  /// 无参数；返回最近一次提交的独立偏好副本，外部编辑必须经过提交队列才生效。
  AppSettings get current => AppSettings.fromMap(_current.toMap());

  /// 无参数；返回普通配置、修订号与凭据存在状态，不向附属引擎公开密钥。
  Future<Map<String, Object>> _snapshot() async => {
    ..._current.toMap(),
    // toMap中的排除项仍是可变字典；协议快照不得暴露内部配置引用。
    PreferenceKeys.excludedApps: Map<String, String>.of(_current.excludedApps),
    'revision': _revision,
    MethodNames.credentialIds: await platform.credentialIds(
      _current.services.map((service) => service.id).toList(),
    ),
    'error': ?error,
  };

  /// candidate为完整偏好，drafts按服务ID表示凭据修改；成功提交后返回新快照，失败保留当前配置。
  Future<Map<String, Object>> _save(
    AppSettings candidate,
    Map<String, Map<String, String>?> drafts,
  ) async {
    // validate检查完整配置，prepareCredentialChanges只准备当前事务所需的凭据变更。
    candidate.validate();
    final credentials = await prepareCredentialChanges(
      previous: _current.services,
      current: candidate.services,
      drafts: drafts,
      readCredentials: platform.readCredentials,
    );
    // applySettings原子提交系统偏好和凭据；成功前不改变主引擎状态。
    await platform.applySettings(candidate.toMap(), credentials: credentials);
    // onSaved只取得副本，通知接收方不能绕过提交队列改写本次配置。
    onSaved(AppSettings.fromMap(candidate.toMap()));
    _current = candidate;
    error = null;
    _revision += 1;
    // _snapshot仅暴露已提交配置和凭据存在状态。
    return _snapshot();
  }

  /// call为普通设置、绘图偏好、菜单开关或服务测试请求；返回所属操作结果，错误不阻断后续提交。
  Future<Object?> handle(MethodCall call) {
    final operation = _queue.then<Object?>((_) async {
      switch (call.method) {
        case MethodNames.getSettings:
          // _snapshot读取同一队列内已提交的修订号和配置。
          return _snapshot();
        case MethodNames.saveSettings:
          final map = Map<Object?, Object?>.from(call.arguments as Map);
          if (map['revision'] != _revision) {
            throw PlatformException(
              code: ErrorCodes.settingsConflict,
              message: '设置已在其他入口更新，请重新加载后再保存。',
            );
          }
          final drafts = (map['credentials'] as Map? ?? {}).map(
            (id, value) => MapEntry(
              id as String,
              value == null ? null : Map<String, String>.from(value as Map),
            ),
          );
          try {
            // _save统一校验和系统提交，表单只提供完整草稿。
            return await _save(AppSettings.fromMap(map), drafts);
          } on FormatException catch (error) {
            throw PlatformException(
              code: ErrorCodes.invalidSettings,
              message: error.message,
            );
          }
        case MethodNames.saveDrawingPreferences:
          // _save在队列执行时合并最新快照，绘图提交不会覆盖其他设置。
          return _save(
            AppSettings.fromMap({
              ..._current.toMap(),
              PreferenceKeys.screenshotDrawing: call.arguments,
            }),
            {},
          );
        case MethodNames.toggleAutomatic:
          // _save使用当前开关状态，连续菜单请求按顺序产生独立修订。
          return _save(
            AppSettings.fromMap({
              ..._current.toMap(),
              PreferenceKeys.automatic: !_current.automatic,
            }),
            {},
          );
        case MethodNames.testService:
          // _testService负责完整连接测试；队列仅等待结果，不持有流式响应处理。
          return _testService(call.arguments);
        default:
          throw MissingPluginException('未知设置操作：${call.method}');
      }
    });
    // 当前请求的错误仍返回调用方，队列尾部吸收错误以允许下一次修正。
    _queue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  /// arguments含服务配置和临时凭据；返回完整测试译文，不写入配置、凭据或历史。
  Future<String> _testService(Object? arguments) async {
    final map = Map<Object?, Object?>.from(arguments as Map);
    final config = ServiceConfig.fromMap(
      Map<Object?, Object?>.from(map['config'] as Map),
    );
    final credentials = {
      ...await platform.readCredentials(config.id),
      ...Map<String, String>.from(map['credentials'] as Map),
    };
    final provider = ApiTranslationProvider(
      config: config,
      credentials: () async => credentials,
    );
    final result = StringBuffer();
    var completed = false;
    // translate只测试示例文本；不写入设置、Keychain或翻译历史。
    await for (final event in provider.translate(
      const TranslationRequest(
        sourceText: 'Hello world.',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
    )) {
      switch (event) {
        case TranslationUpdate(:final addition):
          result.write(addition);
        case TranslationCompleted():
          completed = true;
        case TranslationFailure(:final message):
          throw PlatformException(
            code: ErrorCodes.testFailed,
            message: message,
          );
      }
    }
    if (!completed) {
      throw PlatformException(
        code: ErrorCodes.testFailed,
        message: '服务未返回完整译文。',
      );
    }
    return result.toString();
  }
}
