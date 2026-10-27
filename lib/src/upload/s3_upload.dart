import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../common/constants/network_limits.dart';

/// 未配置上传目标时的提示；截图编辑与主引擎上传请求共用（#131）。
const uploadUnconfiguredMessage = '未配置上传目标，请在「设置 → 截图 → 上传分享」中填写。';

/// S3 兼容存储的上传目标；来自设置「截图 → 上传分享」，访问密钥另存钥匙串（#111）。
/// 请求使用路径式地址 `endpoint/bucket/key`，兼容 AWS S3、Cloudflare R2、MinIO 等。
class S3Target {
  /// endpoint 为 https 服务地址（不含存储桶），region 为签名区域，bucket 为存储桶，
  /// prefix 为对象键前缀（可空），publicBase 为分享链接前缀（空时使用请求地址）。
  const S3Target({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.prefix,
    required this.publicBase,
  });

  final Uri endpoint;
  final String region;
  final String bucket;
  final String prefix;
  final String publicBase;

  /// endpoint/region/bucket/prefix/publicBase 为设置原文；返回去掉首尾空白与多余斜杠的目标。
  /// 地址、区域或存储桶为空，或地址不是带主机的 https 时返回 null，表示未配置上传目标。
  static S3Target? parse({
    required String endpoint,
    required String region,
    required String bucket,
    required String prefix,
    required String publicBase,
  }) {
    final uri = Uri.tryParse(endpoint.trim().replaceAll(RegExp(r'/+$'), ''));
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (region.trim().isEmpty || bucket.trim().isEmpty) return null;
    return S3Target(
      endpoint: uri,
      region: region.trim(),
      bucket: bucket.trim(),
      prefix: prefix.trim().replaceAll(RegExp(r'^/+|/+$'), ''),
      publicBase: publicBase.trim().replaceAll(RegExp(r'/+$'), ''),
    );
  }

  /// 无参数；返回上传前提示的目标描述，格式为「主机/存储桶」。
  String get label => '${endpoint.host}/$bucket';

  /// now 为上传时刻，random 为随机源；返回「前缀/yyyyMMdd-HHmmss-16位十六进制.png」对象键。
  /// 随机段让公开链接不可按时间猜出。
  String objectKey(DateTime now, Random random) {
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final suffix = [
      for (var i = 0; i < 8; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final name = '$stamp-$suffix.png';
    return prefix.isEmpty ? name : '$prefix/$name';
  }

  /// key 为对象键；返回按 SigV4 规则逐段编码的路径式请求地址。
  Uri objectUri(String key) =>
      Uri.parse('$endpoint${_canonicalPath('/$bucket/$key')}');

  /// key 为对象键；返回分享链接：配置了公开前缀时为「前缀/编码键」，否则为请求地址。
  String link(String key) => publicBase.isEmpty
      ? objectUri(key).toString()
      : '$publicBase${_canonicalPath('/$key')}';
}

/// 上传失败；message 为展示给用户的原因。
class UploadException implements Exception {
  /// message 为失败原因。
  const UploadException(this.message);

  final String message;

  /// 无参数；返回失败原因。
  @override
  String toString() => message;
}

/// path 为以 / 开头的未编码路径；返回按 RFC 3986 非保留字符外全部百分号编码（UTF-8、大写十六进制）、保留 / 的路径。
/// `Uri.encodeComponent` 不编码 `!*'()`，与 SigV4 规范路径不一致，因此逐字节编码。
String _canonicalPath(String path) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(path)) {
    final unreserved =
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E ||
        byte == 0x2F;
    buffer.write(
      unreserved
          ? String.fromCharCode(byte)
          : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
  }
  return buffer.toString();
}

/// method 为 HTTP 方法，path 为已编码的规范路径，headers 为参与签名的请求头（名称小写，须含 host 与 x-amz-date），
/// payloadHash 为请求体 SHA-256 十六进制，accessKeyId/secretAccessKey 为访问密钥，region/service 为签名范围，
/// time 为 x-amz-date 对应的 UTC 时刻；返回 AWS Signature Version 4 的 Authorization 头值（无查询参数）。
String sigV4Authorization({
  required String method,
  required String path,
  required Map<String, String> headers,
  required String payloadHash,
  required String accessKeyId,
  required String secretAccessKey,
  required String region,
  required String service,
  required DateTime time,
}) {
  final date = _amzDate(time).substring(0, 8);
  final names = headers.keys.toList()..sort();
  final signedHeaders = names.join(';');
  // 规范请求：方法、路径、空查询、按名称排序的请求头、签名头列表与请求体哈希。
  final canonical = [
    method,
    path,
    '',
    for (final name in names) '$name:${headers[name]!.trim()}',
    '',
    signedHeaders,
    payloadHash,
  ].join('\n');
  final scope = '$date/$region/$service/aws4_request';
  final stringToSign = [
    'AWS4-HMAC-SHA256',
    _amzDate(time),
    scope,
    sha256.convert(utf8.encode(canonical)).toString(),
  ].join('\n');
  // 签名密钥依次以日期、区域、服务与 aws4_request 派生。
  List<int> key = utf8.encode('AWS4$secretAccessKey');
  for (final part in [date, region, service, 'aws4_request']) {
    key = Hmac(sha256, key).convert(utf8.encode(part)).bytes;
  }
  final signature = Hmac(sha256, key).convert(utf8.encode(stringToSign));
  return 'AWS4-HMAC-SHA256 Credential=$accessKeyId/$scope,'
      'SignedHeaders=$signedHeaders,Signature=$signature';
}

/// time 为任意时区时刻；返回 UTC 的 yyyyMMddTHHmmssZ。
String _amzDate(DateTime time) {
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}${two(utc.month)}${two(utc.day)}T'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

/// target 为上传目标，credentials 为钥匙串中的 {accessKeyId, secretAccessKey}，bytes 为 PNG，
/// now 为上传时刻，random 为对象键随机源；以 SigV4 签名的 PUT 上传并返回分享链接。
/// 凭据缺失、网络失败或服务端非 2xx 时抛出 [UploadException]。
Future<String> uploadPng({
  required S3Target target,
  required Map<String, String> credentials,
  required Uint8List bytes,
  required DateTime now,
  required Random random,
}) async {
  final accessKeyId = credentials['accessKeyId'] ?? '';
  final secretAccessKey = credentials['secretAccessKey'] ?? '';
  if (accessKeyId.isEmpty || secretAccessKey.isEmpty) {
    throw const UploadException('未配置上传访问密钥，请在「设置 → 截图 → 上传分享」中填写。');
  }
  final key = target.objectKey(now, random);
  final uri = target.objectUri(key);
  final payloadHash = sha256.convert(bytes).toString();
  // HttpClient 只在非默认端口时把端口写进 Host；签名使用相同的值。
  final host = uri.hasPort && uri.port != 443
      ? '${uri.host}:${uri.port}'
      : uri.host;
  final headers = {
    'content-type': 'image/png',
    'host': host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': _amzDate(now),
  };
  final authorization = sigV4Authorization(
    method: 'PUT',
    path: uri.path,
    headers: headers,
    payloadHash: payloadHash,
    accessKeyId: accessKeyId,
    secretAccessKey: secretAccessKey,
    region: target.region,
    service: 's3',
    time: now,
  );
  final client = HttpClient()
    ..connectionTimeout = NetworkLimits.connectionTimeout;
  try {
    final request = await client.putUrl(uri);
    // 不随重定向把签名与图片发送到另一个地址。
    request.followRedirects = false;
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key != 'host') request.headers.set(key, value);
    }
    request.headers.set('authorization', authorization);
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 60));
    final body = await utf8.decodeStream(response);
    if (response.statusCode ~/ 100 == 2) return target.link(key);
    // S3 错误体为 XML，取 Message 作为原因；没有时只给状态码。
    final message = RegExp(r'<Message>(.*?)</Message>')
        .firstMatch(body)
        ?.group(1);
    throw UploadException(
      '上传失败（HTTP ${response.statusCode}）${message == null ? '' : '：$message'}',
    );
  } on SocketException catch (error) {
    throw UploadException('无法连接上传服务：${error.message}');
  } on HandshakeException catch (error) {
    throw UploadException('上传服务的 TLS 握手失败：${error.message}');
  } on HttpException catch (error) {
    throw UploadException('上传请求失败：${error.message}');
  } on TimeoutException {
    throw const UploadException('上传超时，请检查网络后重试。');
  } finally {
    client.close(force: true);
  }
}
