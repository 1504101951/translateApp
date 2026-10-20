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

/// 截图美化的预设与数值（#103），全部对应样式Spec #67；长度单位为屏幕点。
abstract final class BeautifyMetrics {
  /// 渐变背景预设，按美化行顺序排列；每项为左上到右下的两色渐变及名称。
  static const backgrounds = <({String name, Color from, Color to})>[
    (name: '晨曦', from: Color(0xFFFF9A8B), to: Color(0xFFFF6A88)),
    (name: '海洋', from: Color(0xFF4FACFE), to: Color(0xFF00F2FE)),
    (name: '薄荷', from: Color(0xFF43E97B), to: Color(0xFF38F9D7)),
    (name: '紫罗兰', from: Color(0xFFA18CD1), to: Color(0xFFFBC2EB)),
    (name: '日落', from: Color(0xFFF6D365), to: Color(0xFFFDA085)),
    (name: '石墨', from: Color(0xFF434343), to: Color(0xFF000000)),
  ];

  /// 内边距选项及按钮文字。
  static const paddings = <({double value, String label})>[
    (value: 32, label: '小'),
    (value: 64, label: '中'),
    (value: 96, label: '大'),
  ];
  static const defaultPadding = 64.0;

  /// 圆角选项：直角与圆角。
  static const squareRadius = 0.0;
  static const roundRadius = 12.0;

  /// 阴影：黑色 35%、模糊 24pt、下移 8pt。
  static const shadowColor = Color(0x59000000);
  static const shadowBlur = 24.0;
  static const shadowOffset = 8.0;
}
