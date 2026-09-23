import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';

/// 解析用户输入的6位不透明sRGB值；text允许#前缀，非法输入返回null。
Color? parseDrawingColor(String text) {
  final hex = text.trim().replaceFirst(RegExp(r'^#'), '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}

/// 独立调色盘；initial为当前颜色，onApply返回用户确认的值，不接触画布或历史。
class ColorPicker extends StatefulWidget {
  const ColorPicker({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
  });
  final Color initial;
  final ValueChanged<Color> onApply;
  final VoidCallback onCancel;
  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  late HSVColor _hsv;
  late final TextEditingController _hex;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hex = TextEditingController(text: _hexString(widget.initial));
  }

  /// color为sRGB；返回6位大写HEX，不包含alpha。
  String _hexString(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  /// value为调色结果；同步颜色和HEX输入，返回空。
  void _setColor(HSVColor value) => setState(() {
    _hsv = value;
    _invalid = false;
    _hex.text = _hexString(value.toColor());
  });

  /// point为色域内坐标；夹紧边缘并映射饱和度/亮度，返回空。
  void _pickField(Offset point) => _setColor(
    _hsv
        .withSaturation((point.dx / DrawingMetrics.fieldWidth).clamp(0, 1))
        .withValue((1 - point.dy / DrawingMetrics.fieldHeight).clamp(0, 1)),
  );

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: DrawingMetrics.paletteWidth,
    child: Padding(
      padding: const EdgeInsets.all(DrawingMetrics.padding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('颜色', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: DrawingMetrics.gap),
          Semantics(
            label: '饱和度与亮度',
            child: GestureDetector(
              key: const Key('color-field'),
              onTapDown: (e) => _pickField(e.localPosition),
              onPanStart: (e) => _pickField(e.localPosition),
              onPanUpdate: (e) => _pickField(e.localPosition),
              child: SizedBox(
                height: DrawingMetrics.fieldHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white,
                              HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: (_hsv.saturation * DrawingMetrics.fieldWidth - 4)
                          .clamp(0, DrawingMetrics.fieldWidth - 8),
                      top: ((1 - _hsv.value) * DrawingMetrics.fieldHeight - 4)
                          .clamp(0, DrawingMetrics.fieldHeight - 8),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: DrawingMetrics.gap),
          SizedBox(
            height: DrawingMetrics.hueHeight,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                key: const Key('color-hue'),
                min: 0,
                max: 360,
                value: _hsv.hue,
                semanticFormatterCallback: (v) => '色相 ${v.round()}度',
                onChanged: (v) => _setColor(_hsv.withHue(v)),
              ),
            ),
          ),
          const SizedBox(height: DrawingMetrics.gap),
          Wrap(
            spacing: DrawingMetrics.gap,
            children: [
              for (final color in DrawingMetrics.colors)
                Semantics(
                  button: true,
                  label: '颜色 ${_hexString(color)}',
                  child: InkWell(
                    key: Key('palette-${_hexString(color)}'),
                    onTap: () => _setColor(HSVColor.fromColor(color)),
                    child: Container(
                      width: DrawingMetrics.swatch,
                      height: DrawingMetrics.swatch,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: color == _hsv.toColor()
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey,
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: DrawingMetrics.gap),
          SizedBox(
            height: 32,
            child: TextField(
              key: const Key('color-hex'),
              controller: _hex,
              decoration: const InputDecoration(
                prefixText: '#',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
              ),
              onChanged: (text) {
                final color = parseDrawingColor(text);
                setState(() {
                  _invalid = color == null;
                  if (color != null) _hsv = HSVColor.fromColor(color);
                });
              },
            ),
          ),
          if (_invalid)
            const Text('请输入6位十六进制颜色', style: TextStyle(color: Colors.red)),
          const SizedBox(height: DrawingMetrics.gap),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('取消')),
              const SizedBox(width: DrawingMetrics.gap),
              TextButton(
                key: const Key('apply-color'),
                onPressed: _invalid
                    ? null
                    : () => widget.onApply(_hsv.toColor()),
                child: const Text('应用'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 独立线宽选择器；initial是逻辑pt，onApply返回已确认值，取消不改变外部状态。
class StrokeWidthPicker extends StatefulWidget {
  const StrokeWidthPicker({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
  });
  final double initial;
  final ValueChanged<double> onApply;
  final VoidCallback onCancel;
  @override
  State<StrokeWidthPicker> createState() => _StrokeWidthPickerState();
}

class _StrokeWidthPickerState extends State<StrokeWidthPicker> {
  late double _value = widget.initial.roundToDouble().clamp(
    DrawingMetrics.minWidth,
    DrawingMetrics.maxWidth,
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(DrawingMetrics.padding),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  key: const Key('stroke-width-slider'),
                  min: DrawingMetrics.minWidth,
                  max: DrawingMetrics.maxWidth,
                  divisions: 19,
                  value: _value,
                  semanticFormatterCallback: (v) => '${v.round()}pt',
                  onChanged: (v) => setState(() => _value = v),
                ),
              ),
            ),
            SizedBox(width: 40, child: Text('${_value.round()}pt')),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('取消')),
            const SizedBox(width: DrawingMetrics.gap),
            TextButton(
              key: const Key('apply-stroke-width'),
              onPressed: () => widget.onApply(_value),
              child: const Text('应用'),
            ),
          ],
        ),
      ],
    ),
  );
}
