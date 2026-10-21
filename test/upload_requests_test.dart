import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/upload/s3_upload.dart';
import 'package:translate_app/src/upload/upload_requests.dart';

/// 无参数；验证主引擎上传请求的目标描述与未配置时的拒绝（#111）。
void main() {
  final target = S3Target.parse(
    endpoint: 'https://s3.example.com',
    region: 'auto',
    bucket: 'shots',
    prefix: '',
    publicBase: '',
  );

  /// call 为上传请求，configured 为是否有上传目标；凭据读取会直接失败，用于证明未配置时不读取钥匙串。
  Future<Object?> handle(MethodCall call, {required bool configured}) =>
      handleUploadRequest(
        call,
        target: configured ? target : null,
        credentials: () => throw StateError('未配置时不应读取凭据'),
        now: DateTime(2026),
        random: Random(1),
      );

  test('uploadTarget 返回「主机/存储桶」，未配置返回 null', () async {
    // 边界：同一请求在有目标与无目标两种设置下的输出。
    const call = MethodCall(MethodNames.uploadTarget, {'id': 'shot'});
    expect(await handle(call, configured: true), 's3.example.com/shots');
    expect(await handle(call, configured: false), isNull);
  });

  test('未配置目标时 uploadScreenshot 以 upload_failed 拒绝，不读取凭据', () async {
    // 边界：确认弹窗期间设置被清空；凭据读取若被调用会抛 StateError 而不是 PlatformException。
    final call = MethodCall(MethodNames.uploadScreenshot, {
      'id': 'shot',
      'bytes': Uint8List(1),
    });
    await expectLater(
      handle(call, configured: false),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', ErrorCodes.uploadFailed)
            .having((error) => error.message, 'message', contains('未配置上传目标')),
      ),
    );
  });
}
