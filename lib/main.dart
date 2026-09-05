import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/overlay/translation_overlay.dart';
import 'src/platform/macos_bridge_event.dart';
import 'src/platform/macos_platform_bridge.dart';
import 'src/selection/selection_session.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/settings_app.dart';
import 'src/settings/service_config.dart';
import 'src/translation/providers/api_translation_provider.dart';
import 'src/translation/providers/unofficial_google_provider.dart';
import 'src/translation/translation_types.dart';

/// 无参数；初始化主 Dart 偏好、系统桥和翻译会话，无返回值。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = MacosPlatformBridge();
  var settings = AppSettings.fromMap(await bridge.loadSettings());

  /// config 为偏好快照；返回当前默认服务，凭据仅在请求前从 Keychain 读取。
  TranslationProvider providerFor(AppSettings config) {
    if (config.defaultServiceId == ServiceConfig.builtinId) {
      return UnofficialGoogleProvider();
    }
    return ApiTranslationProvider(
      config: config.services.singleWhere(
        (e) => e.id == config.defaultServiceId,
      ),
      credentials: () => bridge.readCredentials(config.defaultServiceId),
    );
  }

  final session = SelectionSession(
    provider: providerFor(settings),
    detectLanguage: bridge.detectLanguage,
    language: settings.direction,
  );
  String? settingsError;
  var revision = 0;
  Future<void> settingsQueue = Future.value();

  /// 无参数；返回普通配置和凭据存在状态，绝不向设置引擎回传密钥。
  Future<Map<String, Object>> snapshot() async => {
    ...settings.toMap(),
    'revision': revision,
    'credentialIds': await bridge.credentialIds(
      settings.services.map((e) => e.id).toList(),
    ),
    'error': ?settingsError,
  };

  /// candidate 为完整偏好，drafts 为凭据变更；系统成功后才替换主状态并返回快照。
  Future<Map<String, Object>> save(
    AppSettings candidate,
    Map<String, Map<String, String>?> drafts,
  ) async {
    candidate.validate();
    final credentials = <String, Map<String, String>?>{};
    for (final config in candidate.services) {
      // 空字段表示保留；合并仅发生在主引擎内，设置窗口不能读取已保存密钥。
      final value = {
        ...await bridge.readCredentials(config.id),
        ...?drafts[config.id],
      };
      config.validateCredentials(value);
      if (drafts[config.id] != null) credentials[config.id] = value;
    }
    for (final removed in settings.services.where(
      (old) => !candidate.services.any((e) => e.id == old.id),
    )) {
      credentials[removed.id] = null;
    }
    await bridge.applySettings(candidate.toMap(), credentials: credentials);
    session.dismiss();
    session.language = candidate.direction;
    session.provider = providerFor(candidate);
    settings = candidate;
    settingsError = null;
    revision += 1;
    return snapshot();
  }

  // 第二个 Flutter 引擎只展示表单；配置和连接测试通过同一队列访问主引擎。
  bridge.handleSettings((call) {
    final operation = settingsQueue.then<Object?>((_) async {
      switch (call.method) {
        case 'getSettings':
          return snapshot();
        case 'saveSettings':
          final map = Map<Object?, Object?>.from(call.arguments as Map);
          if (map['revision'] != revision) {
            throw PlatformException(
              code: 'settings_conflict',
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
            return await save(AppSettings.fromMap(map), drafts);
          } on FormatException catch (error) {
            throw PlatformException(
              code: 'invalid_settings',
              message: error.message,
            );
          }
        case 'toggleAutomatic':
          return save(
            AppSettings.fromMap({
              ...settings.toMap(),
              'automatic': !settings.automatic,
            }),
            {},
          );
        case 'testService':
          final map = Map<Object?, Object?>.from(call.arguments as Map);
          final config = ServiceConfig.fromMap(
            Map<Object?, Object?>.from(map['config'] as Map),
          );
          final credentials = {
            ...await bridge.readCredentials(config.id),
            ...Map<String, String>.from(map['credentials'] as Map),
          };
          final testProvider = ApiTranslationProvider(
            config: config,
            credentials: () async => credentials,
          );
          final result = StringBuffer();
          var completed = false;
          // 示例文本不含真实选区；测试成功也不写入设置或 Keychain。
          await for (final event in testProvider.translate(
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
                throw PlatformException(code: 'test_failed', message: message);
            }
          }
          if (!completed) {
            throw PlatformException(code: 'test_failed', message: '服务未返回完整译文。');
          }
          return result.toString();
        default:
          throw MissingPluginException('未知设置操作：${call.method}');
      }
    });
    // 一次保存或网络失败不阻塞后续修正。
    settingsQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  });

  try {
    await bridge.applySettings(settings.toMap());
  } on PlatformException catch (error) {
    // 快捷键被其他应用占用时仍提供设置入口，让用户能修正已保存配置。
    settingsError = error.message;
  }
  runApp(TranslateApp(bridge: bridge, session: session));
  await bridge.appReady();
}

/// 无参数；设置引擎入口只创建表单，不创建监听器或翻译会话。
@pragma('vm:entry-point')
void settingsMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SettingsApp());
}

class TranslateApp extends StatefulWidget {
  const TranslateApp({super.key, required this.bridge, required this.session});

  final MacosPlatformBridge bridge;
  final SelectionSession session;

  @override
  State<TranslateApp> createState() => _TranslateAppState();
}

class _TranslateAppState extends State<TranslateApp> {
  static const _triggerSize = TranslationOverlay.triggerSize;
  static const _resultSize = Size(720, 420);
  late final StreamSubscription<MacosBridgeEvent> _bridgeSubscription;

  /// 无参数；订阅原生事件与会话状态，无返回值。
  @override
  void initState() {
    super.initState();
    // 订阅跟随界面生命周期，避免重建后由旧界面继续处理选区。
    _bridgeSubscription = widget.bridge.events.listen(_onBridgeEvent);
    widget.session.addListener(_syncOverlaySize);
  }

  /// 无参数；解除界面监听，避免旧界面处理新事件，无返回值。
  @override
  void dispose() {
    _bridgeSubscription.cancel();
    widget.session.removeListener(_syncOverlaySize);
    super.dispose();
  }

  /// event 为携带 sessionId 的选区或失效事件；同步界面与原生窗口，无返回值。
  void _onBridgeEvent(MacosBridgeEvent event) {
    switch (event) {
      case SelectionCaptured(
        :final sessionId,
        :final text,
        :final gesture,
        :final x,
        :final y,
      ):
        // 开始新会话会取消旧翻译，触发态只接受可读的非空选区。
        widget.session.begin(sessionId: sessionId, text: text);
        if (widget.session.snapshot.phase == TranslationPhase.trigger) {
          final size = gesture == 'hotkey' ? _resultSize : _triggerSize;
          if (gesture == 'hotkey') unawaited(_activate(readSelection: false));
          widget.bridge.showOverlay(
            sessionId: sessionId,
            x: x,
            y: y,
            width: size.width,
            height: size.height,
          );
        } else {
          widget.bridge.hideOverlay(sessionId: sessionId);
        }
      case EscapePressed(:final sessionId) ||
          SelectionInvalidated(:final sessionId):
        if (widget.session.sessionId != sessionId) return;
        _dismiss();
      case UnknownBridgeEvent():
        break;
    }
  }

  /// 无参数；按当前会话阶段更新原生窗口尺寸，无返回值。
  void _syncOverlaySize() {
    final id = widget.session.sessionId;
    if (id == null) return;
    final phase = widget.session.snapshot.phase;
    if (phase == TranslationPhase.idle) {
      widget.bridge.hideOverlay(sessionId: id);
      return;
    }
    if (phase == TranslationPhase.trigger) {
      widget.bridge.setOverlaySize(
        sessionId: id,
        width: _triggerSize.width,
        height: _triggerSize.height,
      );
      return;
    }
    widget.bridge.setOverlaySize(
      sessionId: id,
      width: _resultSize.width,
      height: _resultSize.height,
    );
  }

  /// readSelection 表示点击后补读格式；快捷键已完成读取；返回翻译结束或取消的 Future。
  Future<void> _activate({bool readSelection = true}) async {
    final id = widget.session.sessionId;
    if (id == null) return;
    // 读取与翻译共用会话取消边界，迟到的原文不能覆盖用户的新选区。
    await widget.session.activate(
      readSelection: readSelection
          ? () => widget.bridge.readSelectionForTranslation(sessionId: id)
          : null,
    );
  }

  /// 无参数；关闭当前会话及其原生窗口，无返回值。
  void _dismiss() {
    final id = widget.session.sessionId;
    // 取消业务请求后，用关闭前的会话 ID 隐藏窗口。
    widget.session.dismiss();
    if (id != null) {
      widget.bridge.hideOverlay(sessionId: id);
    }
  }

  /// context 为 Flutter 构建上下文；返回当前会话对应的浮层界面。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TranslationOverlay(
        session: widget.session,
        onActivate: _activate,
        onDismiss: _dismiss,
        onDrag: () {
          final id = widget.session.sessionId;
          // 原生拖动保持来源应用焦点，并保留当前会话的位置。
          if (id != null) widget.bridge.dragOverlay(sessionId: id);
        },
      ),
    );
  }
}
