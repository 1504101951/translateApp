import 'package:flutter/material.dart';

import 'src/overlay/overlay_probe.dart';
import 'src/platform/macos_bridge_event.dart';
import 'src/platform/macos_platform_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = MacosPlatformBridge();
  final gate = OverlaySessionGate();
  runApp(TranslateApp(bridge: bridge, gate: gate));
}

class TranslateApp extends StatefulWidget {
  const TranslateApp({
    super.key,
    required this.bridge,
    required this.gate,
  });

  final MacosPlatformBridge bridge;
  final OverlaySessionGate gate;

  @override
  State<TranslateApp> createState() => _TranslateAppState();
}

class _TranslateAppState extends State<TranslateApp> {
  @override
  void initState() {
    super.initState();
    widget.bridge.events.listen(_onBridgeEvent);
  }

  void _onBridgeEvent(MacosBridgeEvent event) {
    switch (event) {
      case SelectionCaptured(:final sessionId, :final x, :final y):
        widget.gate.begin(sessionId);
        widget.bridge.showOverlay(sessionId: sessionId, x: x, y: y);
      case EscapePressed(:final sessionId) ||
            SelectionInvalidated(:final sessionId):
        if (!widget.gate.accept(sessionId)) {
          return;
        }
        widget.bridge.hideOverlay(sessionId: sessionId);
        widget.gate.clear();
      case UnknownBridgeEvent():
        break;
    }
  }

  void _hide() {
    final id = widget.gate.currentSessionId;
    if (id == null) {
      return;
    }
    widget.bridge.hideOverlay(sessionId: id);
    widget.gate.clear();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OverlayProbe(onHide: _hide),
    );
  }
}
