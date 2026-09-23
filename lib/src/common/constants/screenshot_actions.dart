import 'package:flutter/material.dart';

import 'screenshot_enums.dart';

/// 截图内局部动作的稳定ID及名称；同一注册表用于设置、布局与快捷键分派。
abstract final class ScreenshotActions {
  static const shapePrefix = 'screenshot-shape-';
  static const brushPrefix = 'screenshot-brush-';
  static const palette = 'screenshot-color-picker';
  static const width = 'screenshot-stroke-width';
  static const shapeMode = 'screenshot-shape-mode';
  static const cursor = 'screenshot-tool-cursor';
  static const crop = 'screenshot-tool-crop';
  static const rect = 'screenshot-tool-rect';
  static const arrow = 'screenshot-tool-arrow';
  static const text = 'screenshot-tool-text';
  static const mask = 'screenshot-tool-mask';
  static const brush = 'screenshot-tool-brush';
  static const undo = 'screenshot-undo';
  static const redo = 'screenshot-redo';
  static const pin = 'screenshot-pin';
  static const save = 'screenshot-save';
  static const copy = 'screenshot-copy';
  static const ocrCopy = 'screenshot-ocr-copy';
  static const ocrTranslate = 'screenshot-ocr-translate';
  static const close = 'screenshot-close';
  static const sizeDown = 'screenshot-text-size-down';
  static const sizeUp = 'screenshot-text-size-up';
  static const reveal = 'screenshot-reveal';
  static const colorPrefix = 'screenshot-text-color-';

  /// 顶层动作与工具栏共用图标；上下文操作不参与自定义。
  static const icons = <String, IconData>{
    cursor: Icons.near_me_outlined,
    crop: Icons.crop,
    rect: Icons.crop_square,
    arrow: Icons.north_east,
    text: Icons.text_fields,
    brush: Icons.brush,
    undo: Icons.undo,
    redo: Icons.redo,
    pin: Icons.push_pin_outlined,
    save: Icons.save_outlined,
    copy: Icons.copy_outlined,
    ocrCopy: Icons.text_snippet_outlined,
    ocrTranslate: Icons.translate,
    close: Icons.close,
  };

  /// 无参数；返回包括条件出现按钮的完整有序动作名称表。
  static final Map<String, String> labels = {
    '${shapePrefix}rectangle': '矩形框',
    '${shapePrefix}circle': '圆形框',
    '${shapePrefix}filledRectangle': '矩形纯色填充',
    '${shapePrefix}filledCircle': '圆形纯色填充',
    '${brushPrefix}solid': '普通画笔',
    '${brushPrefix}mosaic': '马赛克画笔',
    palette: '颜色',
    width: '粗细',
    shapeMode: '图形模式',
    cursor: '光标',
    crop: '裁剪',
    rect: '图形',
    arrow: '箭头',
    text: '文字',
    mask: '图形',
    brush: '画笔',
    undo: '撤销',
    redo: '重做',
    pin: '贴图',
    save: '保存',
    copy: '复制图片',
    ocrCopy: '复制文字',
    ocrTranslate: '翻译文字',
    close: '关闭',
    for (var i = 0; i < ScreenshotDefaults.textColors.length; i++)
      '$colorPrefix${ScreenshotDefaults.textColors[i].toARGB32()}':
          '文字颜色：${['红', '白', '黑', '黄'][i]}',
    sizeDown: '缩小字号',
    sizeUp: '增大字号',
    reveal: '在 Finder 中显示',
  };
}
