/// 网络请求的共用时限。
abstract final class NetworkLimits {
  /// 建立 HTTP 连接的时限；翻译服务与截图上传共用（#124）。
  static const connectionTimeout = Duration(seconds: 10);
}
