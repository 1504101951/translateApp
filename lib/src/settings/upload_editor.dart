import 'package:flutter/material.dart';

import '../common/widgets/native_glass.dart';
import '../upload/s3_upload.dart';

/// 上传分享编辑结果：五项目标设置与访问密钥草稿（空表示保留已保存值）（#111）。
typedef UploadDraft = ({
  String endpoint,
  String region,
  String bucket,
  String prefix,
  String publicBase,
  Map<String, String> credentials,
});

/// S3 兼容上传目标的编辑弹窗；只持有草稿，确定后父页提交偏好与钥匙串凭据（#111）。
class UploadEditor extends StatefulWidget {
  /// endpoint/region/bucket/prefix/publicBase 为已保存的目标设置，hasCredentials 为钥匙串中是否已有访问密钥。
  const UploadEditor({
    super.key,
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.prefix,
    required this.publicBase,
    required this.hasCredentials,
  });

  final String endpoint;
  final String region;
  final String bucket;
  final String prefix;
  final String publicBase;
  final bool hasCredentials;

  /// 无参数；返回持有表单控制器的状态。
  @override
  State<UploadEditor> createState() => _UploadEditorState();
}

/// 管理上传目标表单；不从钥匙串取回密钥，确定时校验后返回 [UploadDraft]。
class _UploadEditorState extends State<UploadEditor> {
  late final _endpoint = TextEditingController(text: widget.endpoint);
  late final _region = TextEditingController(text: widget.region);
  late final _bucket = TextEditingController(text: widget.bucket);
  late final _prefix = TextEditingController(text: widget.prefix);
  late final _publicBase = TextEditingController(text: widget.publicBase);
  final _accessKeyId = TextEditingController();
  final _secretAccessKey = TextEditingController();
  String? _message;

  /// 无参数；释放包含凭据草稿的控制器，无返回值。
  @override
  void dispose() {
    for (final controller in [
      _endpoint,
      _region,
      _bucket,
      _prefix,
      _publicBase,
      _accessKeyId,
      _secretAccessKey,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 无参数；校验后关闭弹窗并返回草稿。地址、区域、存储桶全空表示清除目标；
  /// 部分填写或地址不是 https 时提示；目标完整但钥匙串无密钥且未填写时提示；两项密钥须同时填写。
  void _submit() {
    final endpoint = _endpoint.text.trim();
    final region = _region.text.trim();
    final bucket = _bucket.text.trim();
    final cleared = endpoint.isEmpty && region.isEmpty && bucket.isEmpty;
    // S3Target.parse 与上传使用同一规则判断目标是否完整。
    final target = S3Target.parse(
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      prefix: _prefix.text,
      publicBase: _publicBase.text,
    );
    final accessKeyId = _accessKeyId.text.trim();
    final secretAccessKey = _secretAccessKey.text.trim();
    final message = !cleared && target == null
        ? '服务地址须为 https，区域与存储桶不能为空。'
        : accessKeyId.isEmpty != secretAccessKey.isEmpty
        ? 'Access Key ID 与 Secret Access Key 须同时填写。'
        : target != null && !widget.hasCredentials && accessKeyId.isEmpty
        ? '请填写 Access Key ID 与 Secret Access Key。'
        : null;
    if (message != null) {
      setState(() => _message = message);
      return;
    }
    Navigator.pop<UploadDraft>(context, (
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      prefix: _prefix.text.trim(),
      publicBase: _publicBase.text.trim(),
      credentials: accessKeyId.isEmpty
          ? const {}
          : {'accessKeyId': accessKeyId, 'secretAccessKey': secretAccessKey},
    ));
  }

  /// label 为字段名，controller 为输入控制器，hint 为占位提示，helper 为说明，secret 为是否遮挡输入；返回一行表单字段。
  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    String? helper,
    bool secret = false,
  }) => NativeGlassField(
    label: label,
    helper: helper,
    child: TextField(
      key: ValueKey(label),
      controller: controller,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(hintText: hint),
    ),
  );

  /// context 为弹窗上下文；返回目标字段、密钥字段、错误提示与取消/保存操作。
  @override
  Widget build(BuildContext context) {
    final saved = widget.hasCredentials
        ? '已保存，留空保留；保存在 macOS 钥匙串。'
        : '保存在 macOS 钥匙串。';
    return NativeGlassDialog(
      title: const Text('上传分享'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(
                '服务地址',
                _endpoint,
                hint: 'https://s3.us-east-1.amazonaws.com',
                helper: 'S3 兼容服务的根地址，不含存储桶。',
              ),
              _field('区域', _region, hint: 'us-east-1；Cloudflare R2 填 auto'),
              _field('存储桶', _bucket),
              _field('路径前缀', _prefix, hint: '可空'),
              _field('分享链接前缀', _publicBase, hint: '可空，空时使用请求地址'),
              _field(
                'Access Key ID',
                _accessKeyId,
                helper: saved,
                secret: true,
              ),
              _field(
                'Secret Access Key',
                _secretAccessKey,
                helper: saved,
                secret: true,
              ),
              if (_message != null)
                Text(
                  _message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        NativeGlassSurface(
          material: true,
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        NativeGlassSurface(
          material: true,
          child: FilledButton(onPressed: _submit, child: const Text('保存')),
        ),
      ],
    );
  }
}
