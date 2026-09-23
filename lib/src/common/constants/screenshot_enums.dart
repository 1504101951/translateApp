import 'package:flutter/painting.dart';

/// 编辑工具；与工具栏一一对应，不含设置里的目录选择。
enum ScreenshotTool { cursor, crop, rect, arrow, text, brush }

/// 标注种类；裁剪不进入此枚举，撤销只覆盖这些标注。
enum AnnotationKind { rectangle, arrow, text, mask, stroke }

/// 画笔绘制模式，普通颜色轨迹或原图像素马赛克。
enum ShapeMode { solid, mosaic }

/// 截图标注的默认样式；工具栏未改前使用这些值。
class ScreenshotDefaults {
  /// 无参数构造；禁止实例化。
  ScreenshotDefaults._();

  /// 矩形/箭头/文字默认红色，接近常见标注色。
  static const Color strokeColor = Color(0xFFFF3B30);

  /// 文字默认字号，适合视网膜截图像素。
  static const double fontSize = 18;

  /// 点击落字时的默认文本框；拖拽创建时用实际矩形。
  static const Size textBox = Size(240, 80);

  /// 可选文字颜色，顺序即工具栏色点顺序。
  static const List<Color> textColors = [
    Color(0xFFFF3B30),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFFFFCC00),
  ];

  /// 字号档位；减/加在此列表内移动。
  static const List<double> fontSizes = [14, 18, 24, 32, 48];
}

/// 图形工具的四种模式；名称用于偏好持久化。
enum ShapeVariant {
  rectangle,
  circle,
  filledRectangle,
  filledCircle;

  bool get filled => this == filledRectangle || this == filledCircle;
  bool get circular => this == circle || this == filledCircle;
}
