import 'package:flutter/painting.dart';

import '../common/constants/screenshot_enums.dart';
import '../common/constants/drawing_metrics.dart';
import 'drawing_style.dart';

/// 每个工具的下一笔参数；共享控件只编辑值，不共享可变状态。
class DrawingPreferences {
  DrawingPreferences({
    Map<ScreenshotTool, DrawingStyle>? styles,
    Map<String, DrawingStyle>? variants,
    this.fillColor = const Color(0xFF000000),
    this.shape = ShapeVariant.rectangle,
    this.brushMode = ShapeMode.solid,
    this.fontSize = ScreenshotDefaults.fontSize,
  }) : variants = Map.unmodifiable(variants ?? {}),
       styles = Map.unmodifiable(
         styles ??
             {
               ScreenshotTool.rect: const DrawingStyle(),
               ScreenshotTool.arrow: const DrawingStyle(),
               ScreenshotTool.brush: const DrawingStyle(),
               ScreenshotTool.text: const DrawingStyle(),
             },
       );
  final Map<ScreenshotTool, DrawingStyle> styles;
  final Map<String, DrawingStyle> variants;
  final Color fillColor;
  final ShapeVariant shape;
  final ShapeMode brushMode;
  final double fontSize;

  /// tool为顶层工具，shape/brushMode可指定具体子模式；返回该子工具独立样式。
  DrawingStyle styleFor(
    ScreenshotTool tool, {
    ShapeVariant? shape,
    ShapeMode? brushMode,
  }) {
    final variant = _variantKey(
      tool,
      shape ?? this.shape,
      brushMode ?? this.brushMode,
    );
    if (variant != null && variants.containsKey(variant)) {
      return variants[variant]!;
    }
    // 基础快照为未调整的子模式提供初值；修改只写自己的覆盖项。
    if (tool == ScreenshotTool.rect && (shape ?? this.shape).filled) {
      return DrawingStyle(color: fillColor);
    }
    return styles[tool] ?? const DrawingStyle();
  }

  /// 将图形/画笔的子类型转为持久化键；其他工具返回null并使用独立工具槽。
  static String? _variantKey(
    ScreenshotTool tool,
    ShapeVariant shape,
    ShapeMode mode,
  ) {
    if (tool == ScreenshotTool.rect) return shape.name;
    if (tool == ScreenshotTool.brush) return mode.name;
    return null;
  }

  /// raw为UserDefaults中的绘图子字典；缺省使用初始值，非法值明确拒绝。
  factory DrawingPreferences.fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return DrawingPreferences();
    final defaults = DrawingPreferences();
    final saved = Map<String, Object?>.from(raw['tools'] as Map? ?? {});
    if (saved.keys.any(
      (key) => !defaults.styles.keys.any((tool) => tool.name == key),
    )) {
      throw const FormatException('未知绘图工具。');
    }
    final variants = <String, DrawingStyle>{};
    final rawVariants = Map<String, Object?>.from(
      raw['variants'] as Map? ?? {},
    );
    final allowed = {
      ...ShapeVariant.values.map((v) => v.name),
      ...ShapeMode.values.map((v) => v.name),
    };
    for (final entry in rawVariants.entries) {
      if (!allowed.contains(entry.key)) throw const FormatException('未知绘图子工具。');
      final value = entry.value as Map;
      final argb = value['color'] as int;
      final width = (value['width'] as num).toDouble();
      if (argb < 0xFF000000 ||
          argb > 0xFFFFFFFF ||
          !width.isFinite ||
          width < DrawingMetrics.minWidth ||
          width > DrawingMetrics.maxWidth) {
        throw const FormatException('绘图颜色或线宽无效。');
      }
      variants[entry.key] = DrawingStyle(
        color: Color(argb),
        strokeWidth: width,
      );
    }
    final styles = {...defaults.styles};
    for (final tool in styles.keys.toList()) {
      final value = saved[tool.name] as Map?;
      if (value == null) continue;
      final argb = value['color'] as int;
      final width = (value['width'] as num).toDouble();
      if (argb < 0xFF000000 ||
          argb > 0xFFFFFFFF ||
          !width.isFinite ||
          width < DrawingMetrics.minWidth ||
          width > DrawingMetrics.maxWidth) {
        throw const FormatException('绘图颜色或线宽无效。');
      }
      styles[tool] = DrawingStyle(color: Color(argb), strokeWidth: width);
    }
    final fill = raw['fillColor'] as int? ?? defaults.fillColor.toARGB32();
    final font = (raw['fontSize'] as num?)?.toDouble() ?? defaults.fontSize;
    if (fill < 0xFF000000 ||
        fill > 0xFFFFFFFF ||
        !ScreenshotDefaults.fontSizes.contains(font)) {
      throw const FormatException('填充色或文字字号无效。');
    }
    return DrawingPreferences(
      styles: styles,
      variants: variants,
      fillColor: Color(fill),
      fontSize: font,
      shape: ShapeVariant.values.byName(
        raw['shape'] as String? ?? defaults.shape.name,
      ),
      brushMode: ShapeMode.values.byName(
        raw['brushMode'] as String? ?? defaults.brushMode.name,
      ),
    );
  }

  /// 返回可跨引擎传递的独立字典；线宽/字号保持逻辑pt。
  Map<String, Object> toMap() => {
    'tools': styles.map(
      (tool, style) => MapEntry(tool.name, {
        'color': style.color.toARGB32(),
        'width': style.strokeWidth,
      }),
    ),
    'variants': variants.map(
      (key, style) => MapEntry(key, {
        'color': style.color.toARGB32(),
        'width': style.strokeWidth,
      }),
    ),
    'fillColor': fillColor.toARGB32(),
    'shape': shape.name,
    'brushMode': brushMode.name,
    'fontSize': fontSize,
  };

  /// 仅替换指定工具或模式，返回新快照，已有标注不受影响。
  DrawingPreferences copyWith({
    ScreenshotTool? tool,
    DrawingStyle? style,
    Color? fillColor,
    ShapeVariant? shape,
    ShapeMode? brushMode,
    double? fontSize,
  }) => DrawingPreferences(
    // 图形和画笔仅写子模式；基础槽不变，其他子模式不会继承本次修改。
    styles: {
      ...styles,
      if (tool != null &&
          style != null &&
          tool != ScreenshotTool.rect &&
          tool != ScreenshotTool.brush)
        tool: style,
    },
    variants: {
      ...variants,
      if (tool != null &&
          style != null &&
          _variantKey(tool, shape ?? this.shape, brushMode ?? this.brushMode) !=
              null)
        _variantKey(tool, shape ?? this.shape, brushMode ?? this.brushMode)!:
            style,
    },
    fillColor: fillColor ?? this.fillColor,
    shape: shape ?? this.shape,
    brushMode: brushMode ?? this.brushMode,
    fontSize: fontSize ?? this.fontSize,
  );
}
