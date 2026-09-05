import 'dart:async';

import 'package:flutter/material.dart';

import 'src/overlay/translation_overlay.dart';
import 'src/platform/macos_bridge_event.dart';
import 'src/platform/macos_platform_bridge.dart';
import 'src/selection/selection_session.dart';
import 'src/translation/language_direction.dart';
import 'src/translation/providers/unofficial_google_provider.dart';
import 'src/translation/translation_types.dart';

/// 无参数；初始化平台桥与翻译会话并启动应用，无返回值。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final locale = WidgetsBinding.instance.platformDispatcher.locale;
  final session = SelectionSession(
    provider: UnofficialGoogleProvider(),
    language: LanguageDirection.systemDefault(
      languageCode: locale.languageCode,
    ),
  );
  final bridge = MacosPlatformBridge();
  runApp(TranslateApp(bridge: bridge, session: session));
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
  static const _resultSize = Size(320, 220);
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
      case SelectionCaptured(:final sessionId, :final text, :final x, :final y):
        // 开始新会话会取消旧翻译，触发态只接受可读的非空选区。
        widget.session.begin(sessionId: sessionId, text: text);
        if (widget.session.snapshot.phase == TranslationPhase.trigger) {
          widget.bridge.showOverlay(
            sessionId: sessionId,
            x: x,
            y: y,
            width: _triggerSize.width,
            height: _triggerSize.height,
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

  /// 无参数；启动当前选区翻译，返回完成或取消时结束的 Future。
  Future<void> _activate() async {
    // 长度校验、语言方向和请求取消统一由 SelectionSession 管理。
    await widget.session.activate();
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
