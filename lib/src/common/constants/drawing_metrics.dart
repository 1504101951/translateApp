import 'dart:ui';

/// 共享控件尺寸与数值范围，全部对应样式Spec #67。
abstract final class DrawingMetrics {
  static const paletteWidth = 280.0;
  static const padding = 12.0;
  static const gap = 8.0;
  static const fieldWidth = 256.0;
  static const fieldHeight = 144.0;
  static const hueHeight = 16.0;
  static const swatch = 24.0;
  static const minWidth = 1.0;
  static const maxWidth = 20.0;
  static const defaultWidth = 3.0;
  static const mosaicPixels = 12.0;
  static const colors = <Color>[
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF007AFF),
    Color(0xFFAF52DE),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
  ];
}
