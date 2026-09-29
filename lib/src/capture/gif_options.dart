/// 已完成录制的导出参数；时间单位为秒，宽度单位为源视频像素。
class GifOptions {
  /// start/end 为半开片段，fps 为每秒帧数，width 为保持比例的目标宽度。
  const GifOptions({
    required this.start,
    required this.end,
    required this.fps,
    required this.width,
  });

  final double start;
  final double end;
  final int fps;
  final int width;

  /// 无参数；返回按采样间隔向上取整的实际输出帧数。
  int get frameCount {
    // 十进制边界的二进制误差不得多生成一帧；不足一帧的合法片段仍输出一帧。
    final count = ((end - start) * fps - 1e-9).ceil();
    return count < 1 ? 1 : count;
  }

  /// duration/sourceWidth 为原生解码后的源信息；返回首个无效原因，合法时返回 null。
  String? validate({required double duration, required int sourceWidth}) {
    if (!start.isFinite ||
        !end.isFinite ||
        !duration.isFinite ||
        start < 0 ||
        start >= end ||
        end > duration) {
      return '片段须满足 0 ≤ 开始 < 结束 ≤ 视频时长。';
    }
    if (fps < 1 || fps > 30) return '帧率须为 1–30。';
    if (width < 1 || width > sourceWidth) return '宽度须在 1 到源视频宽度之间。';
    final frames = (end - start) * fps;
    if (!frames.isFinite || frames > 1800 + 1e-9) {
      return 'GIF 最多 1800 帧，请缩短片段或降低帧率。';
    }
    return null;
  }

  /// 无参数；返回平台通道使用的显式单位参数，不包含输出路径。
  Map<String, Object> toMap() => {
    'start': start,
    'end': end,
    'fps': fps,
    'width': width,
  };
}
