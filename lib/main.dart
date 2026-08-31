import 'package:flutter/material.dart';

import 'src/overlay/translation_overlay.dart';
import 'src/platform/macos_bridge_event.dart';
import 'src/platform/macos_platform_bridge.dart';
import 'src/selection/selection_session.dart';
import 'src/translation/language_direction.dart';
import 'src/translation/providers/unofficial_google_provider.dart';
import 'src/translation/translation_types.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final locale = WidgetsBinding.instance.platformDispatcher.locale;
  final session = SelectionSession(
    provider: UnofficialGoogleProvider(),
    language: LanguageDirection.systemDefault(languageCode: locale.languageCode),
  );
  final bridge = MacosPlatformBridge();
  runApp(TranslateApp(bridge: bridge, session: session));
}

class TranslateApp extends StatefulWidget {
  const TranslateApp({
    super.key,
    required this.bridge,
    required this.session,
  });

  final MacosPlatformBridge bridge;
  final SelectionSession session;

  @override
  State<TranslateApp> createState() => _TranslateAppState();
}

class _TranslateAppState extends State<TranslateApp> {
  static const _triggerSize = Size(200, 52);
  static const _resultSize = Size(320, 220);

  @override
  void initState() {
    super.initState();
    widget.bridge.events.listen(_onBridgeEvent);
    widget.session.addListener(_syncOverlaySize);
  }

  @override
  void dispose() {
    widget.session.removeListener(_syncOverlaySize);
    super.dispose();
  }

  void _onBridgeEvent(MacosBridgeEvent event) {
    switch (event) {
      case SelectionCaptured(:final sessionId, :final text, :final x, :final y):
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

  Future<void> _activate() async {
    await widget.session.activate();
  }

  void _dismiss() {
    final id = widget.session.sessionId;
    widget.session.dismiss();
    if (id != null) {
      widget.bridge.hideOverlay(sessionId: id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TranslationOverlay(
        session: widget.session,
        onActivate: _activate,
        onDismiss: _dismiss,
      ),
    );
  }
}
