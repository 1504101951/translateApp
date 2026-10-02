import 'dart:async';

import 'package:flutter/material.dart';

import '../common/constants/selection_gesture_types.dart';
import '../common/constants/translation_phase.dart';
import '../common/widgets/native_glass.dart';
import '../history/translation_history.dart';
import '../overlay/translation_overlay.dart';
import '../platform/macos_bridge_event.dart';
import '../platform/macos_platform_bridge.dart';
import '../translation/provider_selection.dart';
import 'selection_session.dart';

/// 选区翻译界面与会话协调者；处理原生事件、取消和完整成功后的历史记录。
class TranslateApp extends StatefulWidget {
  /// bridge为选区系统能力，session为唯一翻译会话，history为主引擎历史存储；构造不启动请求。
  const TranslateApp({
    super.key,
    required this.bridge,
    required this.session,
    required this.history,
  });

  final MacosPlatformBridge bridge;
  final SelectionSession session;
  final TranslationHistoryStore history;

  /// 无参数；返回管理事件订阅与浮层同步的界面状态。
  @override
  State<TranslateApp> createState() => _TranslateAppState();
}

/// 绑定选区会话与浮层生命周期，不创建独立配置或历史存储。
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
        // 没有可用触发态时先退出，后续只处理需要展示的选区。
        if (widget.session.snapshot.phase != TranslationPhase.trigger) {
          widget.bridge.hideOverlay(sessionId: sessionId);
          return;
        }
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
        model: translationHistoryModel(activeProvider),
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
