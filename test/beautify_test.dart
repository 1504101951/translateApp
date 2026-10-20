import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/drawing_metrics.dart';
import 'package:translate_app/src/screenshot/beautify.dart';
import 'package:translate_app/src/screenshot/edit_document.dart';

/// width/height/color 为纯色原图参数；返回 PNG 字节。
Future<Uint8List> solidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

/// bytes 为 PNG；返回 (宽, 高, 逐像素 RGBA)，用于断言实际输出像素。
Future<(int, int, Uint8List)> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (image.width, image.height, data!.buffer.asUint8List());
  image.dispose();
  codec.dispose();
  return result;
}

/// 无参数；验证美化导出的尺寸、背景、圆角、阴影，以及不美化时与原图逐像素一致（#103）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const blue = Color(0xFF0000FF);

  /// image 为解码结果，x/y 为像素坐标；返回该像素 RGB。
  (int, int, int) pixel((int, int, Uint8List) image, int x, int y) {
    final offset = (y * image.$1 + x) * 4;
    return (image.$3[offset], image.$3[offset + 1], image.$3[offset + 2]);
  }

  test('不美化时导出与原图逐像素一致', () async {
    // 边界：background 为 null 是关闭美化的唯一状态，输出必须与原截图完全相同。
    final source = await solidPng(40, 30, blue);
    final doc = EditDocument()..loadCapture(source, 40, 30);
    final plain = await decode(await doc.renderPng(unit: 2));
    final original = await decode(source);
    expect((plain.$1, plain.$2), (40, 30));
    expect(plain.$3, original.$3);
  });

  test('美化按像素倍率扩出内边距，背景从首色开始，圆角外为背景，阴影只加深背景', () async {
    // 边界：倍率 2、内边距 10pt → 每侧 20px；圆角 6pt → 12px，内容左上角像素落在圆角外。
    final source = await solidPng(40, 30, blue);
    final doc = EditDocument()..loadCapture(source, 40, 30);
    const style = BeautifyStyle(
      background: 1,
      padding: 10,
      cornerRadius: 6,
      shadow: false,
    );
    final framed = await decode(await doc.renderPng(beautify: style, unit: 2));
    expect((framed.$1, framed.$2), (80, 70));
    final start = BeautifyMetrics.backgrounds[1].from;
    final corner = pixel(framed, 0, 0);
    expect((corner.$1 - (start.r * 255).round()).abs(), lessThan(4));
    expect((corner.$2 - (start.g * 255).round()).abs(), lessThan(4));
    // 内容中心保持原图蓝色。
    expect(pixel(framed, 40, 35), (0, 0, 255));
    // 内容左上角像素在 12px 圆角之外，被背景（绿色分量明显）覆盖。
    expect(pixel(framed, 20, 20).$2, greaterThan(100));
    // 内容下沿外 4px：开启阴影后比不开时更暗，内容中心不受影响。
    final shadowed = await decode(
      await doc.renderPng(beautify: style.copyWith(shadow: true), unit: 2),
    );
    final below = pixel(framed, 40, 54);
    final belowShadow = pixel(shadowed, 40, 54);
    expect(
      belowShadow.$1 + belowShadow.$2 + belowShadow.$3,
      lessThan(below.$1 + below.$2 + below.$3),
    );
    expect(pixel(shadowed, 40, 35), (0, 0, 255));
  });
}
