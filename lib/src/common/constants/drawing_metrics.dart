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
  static const mosaicPixels = 12.0;

  /// 荧光笔（#107）：默认黄色与 16pt 粗细，绘制时施加 40% 不透明度。
  static const highlighterColor = Color(0xFFFFCC00);
  static const highlighterWidth = 16.0;
  static const highlighterOpacity = 0.4;

  /// 步骤编号标记（#107）：圆直径（pt），数字字号占直径比例，数字最大宽度占直径比例；
  /// 圆的相对亮度超过阈值时数字用黑色，否则用白色。
  static const stepDiameter = 28.0;
  static const stepFontRatio = 0.55;
  static const stepTextMaxRatio = 0.8;
  static const stepLightThreshold = 0.5;
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

/// 取色与标尺的点尺寸（#111）；标签底色、高度、内边距、圆角与字号沿用 [CropMetrics]。
abstract final class MeasureMetrics {
  /// 标签与指针（取色）或终点（标尺）在两个方向上的距离。
  static const labelOffset = 12.0;

  /// 取色色块边长、白边宽度、圆角与到文字的间距。
  static const swatchSize = 10.0;
  static const swatchBorder = 1.0;
  static const swatchRadius = 2.0;
  static const swatchGap = 4.0;

  /// 标尺白线宽、黑色 60% 描边宽与两端垂直端点线的长度。
  static const lineWidth = 1.0;
  static const outlineWidth = 3.0;
  static const tickLength = 8.0;
}

/// 框选精确控制的预设与数值（#106），全部对应样式Spec #67；长度单位标注在各字段。
abstract final class CropMetrics {
  /// 比例行的预设：按钮文字与宽高比，null 为自由。
  static const ratios = <({String label, double? ratio})>[
    (label: '自由', ratio: null),
    (label: '1:1', ratio: 1),
    (label: '4:3', ratio: 4 / 3),
    (label: '3:4', ratio: 3 / 4),
    (label: '16:9', ratio: 16 / 9),
    (label: '9:16', ratio: 9 / 16),
  ];

  /// 比例按钮文字字号（点），四字符比例放进 32pt 按钮。
  static const ratioFontSize = 11.0;

  /// 方向键每次移动或调整的截图像素；按住 ⇧ 时使用大步长。
  static const nudgeStep = 1.0;
  static const nudgeLargeStep = 10.0;

  /// 选区与文字框的最小边长（截图像素），拖动、比例与方向键调整共用。
  static const minSide = 8.0;

  /// 尺寸标签（点）：字号、固定高度、左右内边距、与选区的间距、圆角及黑色 60% 背景。
  static const labelFontSize = 12.0;
  static const labelHeight = 18.0;
  static const labelPadding = 6.0;
  static const labelGap = 4.0;
  static const labelRadius = 4.0;
  static const labelBackground = Color(0x99000000);
}
