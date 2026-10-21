import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/upload/s3_upload.dart';

/// 无参数；验证 S3 上传的签名、目标解析、对象键与链接编码，以及缺少凭据时不发请求（#111）。
void main() {
  test('SigV4 签名与 AWS 文档 PUT Object 示例逐字节一致', () {
    // 边界依据：AWS S3 API 文档「Example: PUT Object」的公开示例密钥、请求头与签名，
    // 路径含需编码的 $（%24），覆盖规范路径、排序请求头与签名密钥派生。
    final authorization = sigV4Authorization(
      method: 'PUT',
      path: '/test%24file.text',
      headers: {
        'host': 'examplebucket.s3.amazonaws.com',
        'date': 'Fri, 24 May 2013 00:00:00 GMT',
        'x-amz-date': '20130524T000000Z',
        'x-amz-storage-class': 'REDUCED_REDUNDANCY',
        'x-amz-content-sha256':
            '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
      },
      payloadHash:
          '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      region: 'us-east-1',
      service: 's3',
      time: DateTime.utc(2013, 5, 24),
    );
    expect(
      authorization,
      'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,'
      'SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,'
      'Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
    );
  });

  test('只有 https 地址、区域与存储桶齐全时才是已配置的上传目标', () {
    // 边界：空区域、空存储桶、http 与无主机地址都视为未配置；首尾空白与多余斜杠被去掉。
    S3Target? parse({
      String endpoint = 'https://s3.example.com/',
      String region = 'auto',
      String bucket = 'shots',
    }) => S3Target.parse(
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      prefix: ' /team/ ',
      publicBase: 'https://cdn.example.com/ ',
    );
    expect(parse(region: ' '), isNull);
    expect(parse(bucket: ''), isNull);
    expect(parse(endpoint: 'http://s3.example.com'), isNull);
    expect(parse(endpoint: 'https://'), isNull);
    final target = parse()!;
    expect(target.label, 's3.example.com/shots');
    expect(target.prefix, 'team');
    expect(target.publicBase, 'https://cdn.example.com');
  });

  test('对象键带时间与 16 位随机十六进制；请求地址与链接按 SigV4 规则编码', () {
    // 边界：前缀为空时不加斜杠；前缀中的空格与中文按 UTF-8 百分号编码，/ 保留；
    // 未配置公开前缀时链接回落为路径式请求地址。
    final now = DateTime(2026, 10, 21, 9, 5, 7);
    final bare = S3Target.parse(
      endpoint: 'https://s3.example.com',
      region: 'us-east-1',
      bucket: 'shots',
      prefix: '',
      publicBase: '',
    )!;
    final key = bare.objectKey(now, Random(1));
    expect(key, matches(RegExp(r'^20261021-090507-[0-9a-f]{16}\.png$')));
    expect(bare.link(key), 'https://s3.example.com/shots/$key');
    final named = S3Target.parse(
      endpoint: 'https://s3.example.com',
      region: 'us-east-1',
      bucket: 'shots',
      prefix: '团队 截图',
      publicBase: 'https://cdn.example.com',
    )!;
    final nested = named.objectKey(now, Random(1));
    final encoded =
        '%E5%9B%A2%E9%98%9F%20%E6%88%AA%E5%9B%BE/${nested.split('/').last}';
    expect(named.objectUri(nested).path, '/shots/$encoded');
    expect(named.link(nested), 'https://cdn.example.com/$encoded');
  });

  test('凭据缺失时直接失败，不发出网络请求', () async {
    // 边界：访问密钥任一为空即拒绝；目标指向不可解析的主机，若误发请求会得到连接错误而非凭据提示。
    final target = S3Target.parse(
      endpoint: 'https://upload.invalid',
      region: 'us-east-1',
      bucket: 'shots',
      prefix: '',
      publicBase: '',
    )!;
    await expectLater(
      uploadPng(
        target: target,
        credentials: {'accessKeyId': 'AKID', 'secretAccessKey': ''},
        bytes: Uint8List(1),
        now: DateTime(2026),
        random: Random(1),
      ),
      throwsA(
        isA<UploadException>().having(
          (error) => error.message,
          'message',
          contains('未配置上传访问密钥'),
        ),
      ),
    );
  });
}
