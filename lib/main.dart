import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import 'src/capture/capture_app.dart';
import 'src/common/constants/live_region.dart';
import 'src/common/constants/method_names.dart';
import 'src/history/history_app.dart';
import 'src/history/history_requests.dart';
import 'src/history/screenshot_history.dart';
import 'src/history/translation_history.dart';
import 'src/history/vocabulary.dart';
import 'src/platform/macos_platform_bridge.dart';
import 'src/screenshot/screenshot_app.dart';
import 'src/screenshot/screenshot_translation.dart';
import 'src/selection/selection_session.dart';
import 'src/selection/selection_translation_app.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/permission_wizard_app.dart';
import 'src/settings/settings_app.dart';
import 'src/settings/settings_controller.dart';
import 'src/translation/live_region_session.dart';
import 'src/translation/provider_selection.dart';
import 'src/common/constants/preference_keys.dart';
import 'src/upload/upload_requests.dart';

/// 无参数；装配主引擎唯一的配置、翻译会话、历史存储与跨窗口请求入口，无返回值。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = MacosPlatformBridge();
  final initial = AppSettings.fromMap(await bridge.loadSettings());
  final support = await bridge.applicationSupportPath();
  Directory(support).createSync(recursive: true);
  // 翻译历史与生词本共用同一个 SQLite 文件。
  final database = sqlite3.open('$support/translation_history.sqlite');
  final history = TranslationHistoryStore(
    database,
    onChanged: () => unawaited(bridge.notifyHistoryChanged()),
  );
  // 截图历史图片与截图保存目录分开，清理只作用于此目录（#29）。
  final screenshots = ScreenshotHistoryStore(
    database,
    Directory('$support/ScreenshotHistory'),
    onChanged: () => unawaited(bridge.notifyHistoryChanged()),
  );
  // 生词本增删后与历史一样通知历史窗口刷新（#102）。
  final vocabulary = VocabularyStore(
    database,
    onChanged: () => unawaited(bridge.notifyHistoryChanged()),
  );
  // providerForSettings复用翻译模块的服务选择；SelectionSession拥有请求、重试和取消。
  final session = SelectionSession(
    provider: providerForSettings(initial, bridge),
    detectLanguage: bridge.detectLanguage,
    language: initial.direction,
    lookupDefinition: bridge.lookupDefinition,
  );
  // 实时翻译会话只留在主引擎。原生盖层按快照绘制，不持有服务或密钥。
  final live = LiveRegionSession(
    providerFor: (settings) => providerForSettings(settings, bridge),
    detectLanguage: bridge.detectLanguage,
    clock: SystemLiveRegionClock(),
    onView: (view) {
      unawaited(bridge.publishLiveRegion(view.toMap()));
    },
  );
  final settings = SettingsController(
    initial: initial,
    platform: bridge,
    onSaved: (candidate) {
      // dismiss只撤下未展开触发态；已开始翻译继续使用自身冻结的服务和语言快照。
      if (!session.isExpanded) session.dismiss();
      session.language = candidate.direction;
      // providerForSettings在下一次请求前按已提交配置读取对应服务凭据。
      session.provider = providerForSettings(candidate, bridge);
      // 实时翻译之后发送的批次使用新配置，不重译画面上未变化的段落块。
      live.noteSettings(candidate);
    },
  );
  // 润色、纠错与解释在切换时按已提交配置取得默认模型服务（#100）。
  session.assistProviderFor = (mode) =>
      assistProviderForSettings(settings.current, bridge, mode);

  // handleApplicationRequests只路由跨引擎请求；同引擎直接调用所属模块，不绕回原生通道。
  bridge.handleApplicationRequests((call) async {
    switch (call.method) {
      case MethodNames.getSettings:
      case MethodNames.saveSettings:
      case MethodNames.saveDrawingPreferences:
      case MethodNames.toggleAutomatic:
      case MethodNames.testService:
        // handle拥有唯一设置队列，校验和系统事务成功后才发布新修订。
        return settings.handle(call);
      case MethodNames.historyPage:
      case MethodNames.historyRecording:
      case MethodNames.setHistoryRecording:
        // handleHistoryRequest访问同一个历史库，不等待设置提交或服务测试。
        return handleHistoryRequest(history, call);
      case MethodNames.uploadTarget:
      case MethodNames.uploadScreenshot:
        // handleUploadRequest 按已提交设置的目标与钥匙串密钥上传截图（#111）。
        return handleUploadRequest(
          call,
          target: settings.current.uploadTarget,
          credentials: () =>
              bridge.readCredentials(PreferenceKeys.uploadCredentials),
          now: DateTime.now(),
          random: Random.secure(),
        );
      case MethodNames.vocabularyList:
      case MethodNames.deleteVocabulary:
      case MethodNames.vocabularyCsv:
        // handleVocabularyRequest 访问同一个数据库中的生词本。
        return handleVocabularyRequest(vocabulary, call);
      case MethodNames.recordScreenshotHistory:
      case MethodNames.screenshotHistoryList:
      case MethodNames.deleteScreenshotHistory:
      case MethodNames.clearScreenshotHistory:
      case MethodNames.screenshotHistoryRecording:
      case MethodNames.setScreenshotHistoryRecording:
      case MethodNames.addScreenshotHistory:
        // handleScreenshotHistoryRequest 按开关写入导出截图、无条件加入拼接与拆分结果，并按条数与时长清理。
        return handleScreenshotHistoryRequest(
          screenshots,
          call,
          DateTime.now().millisecondsSinceEpoch,
        );
      case MethodNames.liveRegionCommand:
        final command = Map<Object?, Object?>.from(call.arguments as Map);
        final generation = command['generation'] as int;
        // 未知命令由 byName 直接抛错（#127）；快照只经 publishLiveRegion 发给原生，命令回包不携带快照（#124）。
        final action = LiveRegionAction.values.byName(
          command['action'] as String,
        );
        switch (action) {
          case LiveRegionAction.start:
            live.start(settings.current, generation);
          case LiveRegionAction.pause:
            live.pause(generation);
          case LiveRegionAction.resume:
            live.resume(generation);
          case LiveRegionAction.end:
            live.end(generation);
          case LiveRegionAction.discard:
            live.discard(generation);
          case LiveRegionAction.captureFailed:
            live.captureUnavailable(generation, command['failure'] as String);
        }
        return null;
      case MethodNames.liveRegionOcr:
        final sample = Map<Object?, Object?>.from(call.arguments as Map);
        final blocks = <LiveTextBlock>[
          for (final item in sample['blocks'] as List? ?? const [])
            if (item is Map)
              LiveTextBlock(
                text: '${item['text'] ?? ''}',
                x: (item['x'] as num?)?.toDouble(),
                y: (item['y'] as num?)?.toDouble(),
                width: (item['width'] as num?)?.toDouble(),
                height: (item['height'] as num?)?.toDouble(),
              ),
        ];
        await live.onOcr(
          LiveOcrSample(
            generation: sample['generation'] as int,
            text: sample['text'] as String?,
            failure: sample['failure'] as String?,
            blocks: blocks,
          ),
        );
        return null;
      case MethodNames.translatePlainText:
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        final captureId = map['id'] as String;
        // providerForSettings冻结本次截图翻译配置，设置后续修改不影响当前请求。
        final configuration = settings.current;
        final provider = providerForSettings(configuration, bridge);
        // translateScreenshotText校验截图身份，只在完整成功且仍有效时写入历史。
        return translateScreenshotText(
          text: map['text'] as String,
          provider: provider,
          model: translationHistoryModel(provider),
          language: configuration.direction,
          detectLanguage: bridge.detectLanguage,
          isCurrent: () => bridge.isCurrentScreenshot(captureId),
          history: history,
        );
      default:
        throw MissingPluginException('未知应用操作：${call.method}');
    }
  });

  try {
    // applySettings应用已保存的系统配置；启动失败仍保留设置入口供用户修正。
    await bridge.applySettings(initial.toMap());
  } on PlatformException catch (error) {
    settings.error = error.message;
  }
  runApp(
    TranslateApp(
      bridge: bridge,
      session: session,
      history: history,
      vocabulary: vocabulary,
    ),
  );
  // appReady通知原生主界面已能接收请求与首次启动窗口调度。
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

/// 无参数；采集引擎只管理录制、GIF 与长截图界面，原生持有媒体资源。
@pragma('vm:entry-point')
void captureMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CaptureApp());
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
