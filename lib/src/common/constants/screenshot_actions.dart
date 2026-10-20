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
  static const record = 'screenshot-record';
  static const live = 'screenshot-live';
  static const scrolling = 'screenshot-scrolling';
  static const rect = 'screenshot-tool-rect';
  static const arrow = 'screenshot-tool-arrow';
  static const text = 'screenshot-tool-text';
  static const mask = 'screenshot-tool-mask';
  static const brush = 'screenshot-tool-brush';
  static const beautify = 'screenshot-beautify';
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

  /// 可拼接功能的注册表：用户可以在设置里排序、隐藏、绑定快捷键，并拼成父子两级。
  ///
  /// 新增可拼接功能时必须在这里登记，并声明 hostsChildren：
  /// 点击后停留在该功能上的“工具”为 true，可以作为父级；
  /// 点击即执行或展开自己目标选择的“动作”为 false，只能作为一级或子级。
  /// 工具属性（颜色、粗细、字号、形状、画笔模式）不在此表，始终跟随所属工具显示。
  static const composable = <String, ({IconData icon, bool hostsChildren})>{
    cursor: (icon: Icons.near_me_outlined, hostsChildren: true),
    crop: (icon: Icons.crop, hostsChildren: true),
    record: (icon: Icons.videocam_outlined, hostsChildren: false),
    scrolling: (icon: Icons.unfold_more, hostsChildren: false),
    rect: (icon: Icons.crop_square, hostsChildren: true),
    arrow: (icon: Icons.north_east, hostsChildren: true),
    text: (icon: Icons.text_fields, hostsChildren: true),
    brush: (icon: Icons.brush, hostsChildren: true),
    // 美化展开自己的设置行，不承载子级（#103）。
    beautify: (icon: Icons.auto_awesome_outlined, hostsChildren: false),
    pin: (icon: Icons.push_pin_outlined, hostsChildren: false),
    save: (icon: Icons.save_outlined, hostsChildren: false),
    copy: (icon: Icons.copy_outlined, hostsChildren: false),
    ocrCopy: (icon: Icons.text_snippet_outlined, hostsChildren: false),
    ocrTranslate: (icon: Icons.translate, hostsChildren: false),
    live: (icon: Icons.subtitles_outlined, hostsChildren: false),
    close: (icon: Icons.close, hostsChildren: false),
  };

  /// 默认的父子结构：键为父级，值为按顺序排列的子级；未列出的功能默认是一级。
  static const defaultChildren = <String, List<String>>{
    crop: [record, scrolling],
  };

  /// 可拼接功能的图标；键的顺序即默认顺序。
  static final Map<String, IconData> icons = {
    for (final entry in composable.entries) entry.key: entry.value.icon,
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
    crop: '截图',
    record: '录制',
    live: '实时翻译',
    scrolling: '滚动长截图',
    rect: '图形',
    arrow: '箭头',
    text: '文字',
    mask: '图形',
    brush: '画笔',
    beautify: '美化',
    pin: '贴图',
    save: '保存',
    copy: '复制图片',
    ocrCopy: '识别文字',
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
