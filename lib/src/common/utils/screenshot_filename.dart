/// capturedAt 为本地截图时间；返回带毫秒时间的 PNG 名称，重名序号由原生文件写入负责。
String screenshotFilename(DateTime capturedAt) {
  String pad(int value, [int width = 2]) =>
      value.toString().padLeft(width, '0');
  return '截图_${capturedAt.year}-${pad(capturedAt.month)}-${pad(capturedAt.day)}_'
      '${pad(capturedAt.hour)}-${pad(capturedAt.minute)}-${pad(capturedAt.second)}-'
      '${pad(capturedAt.millisecond, 3)}.png';
}
