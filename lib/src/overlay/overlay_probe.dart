import 'package:flutter/material.dart';

/// #13 探测用 Overlay 内容：验证 NSPanel 内 Flutter 可点击。拖动由 Swift 原生处理。
class OverlayProbe extends StatefulWidget {
  const OverlayProbe({super.key, required this.onHide});

  final VoidCallback onHide;

  @override
  State<OverlayProbe> createState() => OverlayProbeState();
}

class OverlayProbeState extends State<OverlayProbe> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2FFFFFF),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Overlay 探测',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text('点击次数 $taps', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => setState(() => taps += 1),
                  child: const Text('点击'),
                ),
                TextButton(
                  onPressed: widget.onHide,
                  child: const Text('隐藏'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
