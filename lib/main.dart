import 'src/common/constants/selection_gesture_types.dart';
import 'src/common/constants/method_names.dart';
import 'src/common/constants/preference_keys.dart';
import 'src/common/constants/error_codes.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import 'src/history/history_app.dart';
import 'src/common/widgets/native_glass.dart';
import 'src/history/translation_history.dart';
import 'src/overlay/translation_overlay.dart';
import 'src/platform/macos_bridge_event.dart';
import 'src/platform/macos_platform_bridge.dart';
import 'src/selection/selection_session.dart';
import 'src/screenshot/screenshot_app.dart';
import 'src/screenshot/screenshot_translation.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/permission_wizard_app.dart';
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
  final support = await bridge.applicationSupportPath();
  Directory(support).createSync(recursive: true);
  final history = TranslationHistoryStore(
    sqlite3.open('$support/translation_history.sqlite'),
    onChanged: () => unawaited(bridge.notifyHistoryChanged()),
  );

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
    MethodNames.credentialIds: await bridge.credentialIds(
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
    final credentials = await prepareCredentialChanges(
      previous: settings.services,
      current: candidate.services,
      drafts: drafts,
      readCredentials: bridge.readCredentials,
    );
    await bridge.applySettings(candidate.toMap(), credentials: credentials);
    if (!session.isExpanded) session.dismiss();
    session.language = candidate.direction;
    session.provider = providerFor(candidate);
    settings = candidate;
    settingsError = null;
    revision += 1;
    return snapshot();
  }

  // 第二个 Flutter 引擎只展示表单；配置和连接测试通过同一队列访问主引擎。
  bridge.handleSettings((call) {
    if (call.method == MethodNames.translatePlainText) {
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      final captureId = map['id'] as String;
      final activeProvider = providerFor(settings);
      final activeLanguage = settings.direction;
      // 截图请求使用配置快照，不占用设置队列；用户可在翻译期间关闭历史记录。
      // 截图翻译只在完整成功且 captureId 仍有效时落库。
      return translateScreenshotText(
        text: map['text'] as String,
        provider: activeProvider,
        model: _historyModel(activeProvider),
        language: activeLanguage,
        detectLanguage: bridge.detectLanguage,
        isCurrent: () => bridge.isCurrentScreenshot(captureId),
        history: history,
      );
    }
    final operation = settingsQueue.then<Object?>((_) async {
      switch (call.method) {
        case MethodNames.getSettings:
          return snapshot();
        case MethodNames.saveSettings:
          final map = Map<Object?, Object?>.from(call.arguments as Map);
          if (map['revision'] != revision) {
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
            return await save(AppSettings.fromMap(map), drafts);
          } on FormatException catch (error) {
            throw PlatformException(
              code: ErrorCodes.invalidSettings,
              message: error.message,
            );
          }
        case MethodNames.saveDrawingPreferences:
          return save(
            AppSettings.fromMap({
              ...settings.toMap(),
              PreferenceKeys.screenshotDrawing: call.arguments,
            }),
            {},
          );
        case MethodNames.toggleAutomatic:
          return save(
            AppSettings.fromMap({
              ...settings.toMap(),
              PreferenceKeys.automatic: !settings.automatic,
            }),
            {},
          );
        case MethodNames.historyPage:
          final map = Map<Object?, Object?>.from(call.arguments as Map? ?? {});
          final cursor = map['before'] as Map?;
          // 历史窗口一次读取固定 10 条；时间/ID 游标避免新记录挤动分页位置。
          return [
            for (final row in history.page(
              before: cursor == null
                  ? null
                  : (
                      completedAt: cursor['completedAt'] as int,
                      id: cursor['id'] as int,
                    ),
            ))
              {
                'id': row.id,
                'sourceText': row.sourceText,
                'translatedText': row.translatedText,
                'detectedLanguage': row.detectedLanguage,
                'targetLanguage': row.targetLanguage,
                'providerId': row.providerId,
                'model': row.model,
                'completedAt': row.completedAt,
                'sourceLabel': row.sourceLabel,
              },
          ];
        case MethodNames.historyRecording:
          return history.recordingEnabled;
        case MethodNames.setHistoryRecording:
          final map = Map<Object?, Object?>.from(call.arguments as Map);
          history.recordingEnabled = map['enabled'] == true;
          return null;
        case MethodNames.testService:
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
  runApp(TranslateApp(bridge: bridge, session: session, history: history));
  await bridge.appReady();
}

/// 无参数；设置引擎入口只创建表单，不创建监听器或翻译会话。
@pragma('vm:entry-point')
void settingsMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SettingsApp());
}

/// 无参数；截图引擎只创建图片预览，不初始化翻译或全局监听。
@pragma('vm:entry-point')
void screenshotMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScreenshotApp());
}

/// 无参数；启动权限向导界面，由原生处理系统授权。
@pragma('vm:entry-point')
void permissionWizardMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PermissionWizardApp());
}

/// 无参数；启动独立历史引擎，历史读写仍委托主引擎。
@pragma('vm:entry-point')
void historyMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HistoryApp());
}

class TranslateApp extends StatefulWidget {
  const TranslateApp({
    super.key,
    required this.bridge,
    required this.session,
    required this.history,
  });

  final MacosPlatformBridge bridge;
  final SelectionSession session;
  final TranslationHistoryStore history;

  @override
  State<TranslateApp> createState() => _TranslateAppState();
}

class _TranslateAppState extends State<TranslateApp> {
  static const _triggerSize = TranslationOverlay.triggerWindowSize;
  static const _resultSize = Size(720, 420);
  late final StreamSubscription<MacosBridgeEvent> _bridgeSubscription;

  /// 来源在接受选区时冻结，不读取翻译完成后的前台应用。
  String? _sourceAppName;

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
        :final sourceAppName,
        :final x,
        :final y,
      ):
        // 被动捕获只更新小按钮，不能替换用户正在阅读的结果。
        if (widget.session.isExpanded &&
            gesture != SelectionGestureTypes.hotkey) {
          return;
        }
        _sourceAppName = sourceAppName;
        // 键盘选择先显示候选按钮；明确热键的空读取也必须进入可见失败状态。
        widget.session.begin(
          sessionId: sessionId,
          text: text,
          awaitSelection:
              gesture == SelectionGestureTypes.selectAll ||
              gesture == SelectionGestureTypes.keyboard ||
              gesture == SelectionGestureTypes.hotkey,
        );
        if (widget.session.snapshot.phase == TranslationPhase.trigger) {
          final size = gesture == SelectionGestureTypes.hotkey
              ? _resultSize
              : _triggerSize;
          if (gesture == SelectionGestureTypes.hotkey) {
            unawaited(_activate(readSelection: false));
          }
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
      case SelectionInvalidated(:final sessionId):
        if (widget.session.isExpanded ||
            widget.session.sessionId != sessionId) {
          return;
        }
        _dismiss();
      case EscapePressed(:final sessionId):
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
    final retry = widget.session.canRetry;
    if (id == null ||
        (!retry && widget.session.snapshot.phase != TranslationPhase.trigger)) {
      return;
    }
    // 先保留窗口，再开始异步补读；期间切 App 不会关闭加载或失败卡片。
    await widget.bridge.retainOverlay(sessionId: id);
    // 连续点击等待同一个原生响应时，只允许一次激活及一次成功记录。
    if (widget.session.sessionId != id ||
        (retry
            ? !widget.session.canRetry
            : widget.session.snapshot.phase != TranslationPhase.trigger)) {
      return;
    }
    final activeProvider = retry
        ? widget.session.activeProvider
        : widget.session.provider;
    final activeLanguage = retry
        ? widget.session.activeLanguage
        : widget.session.language;
    final sourceLabel = _sourceAppName;
    // 读取与翻译共用会话取消边界，迟到的原文不能覆盖用户的新选区。
    if (retry) {
      // 原文、方向和服务都属于失败会话；重试不重新读取前台选区。
      await widget.session.retry();
    } else {
      await widget.session.activate(
        readSelection: readSelection
            ? () => widget.bridge.readSelectionForTranslation(sessionId: id)
            : null,
      );
    }
    // 旧请求结束时新会话可能已经完成，必须核对 ID，不能重复记录新会话。
    if (widget.session.sessionId == id &&
        widget.session.snapshot.phase == TranslationPhase.completed) {
      widget.history.insert(
        sourceText: widget.session.snapshot.sourceText,
        translatedText: widget.session.snapshot.translatedText,
        detectedLanguage: widget.session.snapshot.detectedLanguage ?? '',
        // 按本次检测结果解析激活时的方向，不能把次要语言错误记录成主要语言。
        targetLanguage: activeLanguage
            .resolve(widget.session.snapshot.detectedLanguage)
            .targetLanguage,
        providerId: activeProvider.id,
        model: _historyModel(activeProvider),
        sourceLabel: sourceLabel,
        completedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
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
    return NativeGlassApp(
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

/// provider 为本次请求实际使用的服务；返回可选模型名，普通翻译服务不记录空模型。
String? _historyModel(TranslationProvider provider) {
  if (provider is! ApiTranslationProvider || provider.config.model.isEmpty) {
    return null;
  }
  return provider.config.model;
}
