import 'dart:math';

import 'package:flutter/services.dart';

import '../common/constants/error_codes.dart';
import '../common/constants/method_names.dart';
import 's3_upload.dart';

/// call 为截图引擎经原生转发的上传请求，target 为当前已提交设置中的上传目标（未配置为 null），
/// credentials 读取钥匙串中的上传访问密钥，now/random 为对象键的时间与随机源；
/// 返回 uploadTarget 的「主机/存储桶」（未配置为 null）或 uploadScreenshot 的分享链接（#111）。
/// 未配置目标或上传失败时抛出 code 为 upload_failed 的 [PlatformException]。
Future<Object?> handleUploadRequest(
  MethodCall call, {
  required S3Target? target,
  required Future<Map<String, String>> Function() credentials,
  required DateTime now,
  required Random random,
}) async {
  if (call.method == MethodNames.uploadTarget) return target?.label;
  // 确认弹窗期间设置可能被清空；未配置时不读取凭据、不发送图像。
  if (target == null) {
    throw PlatformException(
      code: ErrorCodes.uploadFailed,
      message: uploadUnconfiguredMessage,
    );
  }
  final arguments = Map<Object?, Object?>.from(call.arguments as Map);
  try {
    // uploadPng 签名并 PUT 到目标存储，返回分享链接。
    return await uploadPng(
      target: target,
      credentials: await credentials(),
      bytes: arguments['bytes'] as Uint8List,
      now: now,
      random: random,
    );
  } on UploadException catch (error) {
    throw PlatformException(
      code: ErrorCodes.uploadFailed,
      message: error.message,
    );
  }
}
