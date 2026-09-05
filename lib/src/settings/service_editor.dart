import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'service_config.dart';

/// 编辑器只持有草稿；保存设置才将凭据交给主引擎写入 Keychain。
class ServiceEditor extends StatefulWidget {
  const ServiceEditor({
    super.key,
    this.config,
    this.credentials = const {},
    this.hasCredentials = false,
  });

  final ServiceConfig? config;
  final Map<String, String> credentials;
  final bool hasCredentials;

  @override
  State<ServiceEditor> createState() => _ServiceEditorState();
}

class _ServiceEditorState extends State<ServiceEditor> {
  final _name = TextEditingController();
  final _base = TextEditingController();
  final _model = TextEditingController();
  final _prompt = TextEditingController();
  final _key = TextEditingController();
  final _appId = TextEditingController();
  final _tokens = TextEditingController();
  late String _id;
  late String _kind;
  bool _semantic = false;
  bool _testing = false;
  String? _message;

  /// 无参数；读取非敏感配置和本窗口草稿，不从 Keychain 取回密钥，无返回值。
  @override
  void initState() {
    super.initState();
    final config = widget.config;
    _id = config?.id ?? 'service-${DateTime.now().microsecondsSinceEpoch}';
    _kind = config?.kind ?? 'baidu';
    _name.text = config?.name ?? ServiceConfig.kinds[_kind]!;
    _base.text = config?.baseUrl ?? ServiceConfig.endpoints[_kind]!;
    _model.text = config?.model ?? '';
    _prompt.text = config?.prompt ?? ServiceConfig.defaultPrompt;
    _tokens.text = '${config?.maxOutputTokens ?? 4096}';
    _semantic = config?.semanticPairs ?? false;
    _key.text = widget.credentials['apiKey'] ?? '';
    _appId.text = widget.credentials['appId'] ?? '';
  }

  /// 无参数；关闭窗口时释放包含凭据草稿的控制器，无返回值。
  @override
  void dispose() {
    for (final controller in [
      _name,
      _base,
      _model,
      _prompt,
      _key,
      _appId,
      _tokens,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 无参数；验证表单，返回配置及非空凭据字段，空字段表示保留已保存值。
  ({ServiceConfig config, Map<String, String> credentials}) _draft() {
    final config = ServiceConfig(
      id: _id,
      kind: _kind,
      name: _name.text.trim(),
      baseUrl: _base.text.trim(),
      model: _model.text.trim(),
      prompt: _prompt.text,
      semanticPairs: _semantic,
      maxOutputTokens: int.tryParse(_tokens.text) ?? 0,
    );
    // 配置校验在窗口中给出具体提示，网络测试不替代格式校验。
    config.validate();
    final credentials = <String, String>{
      if (_key.text.trim().isNotEmpty) 'apiKey': _key.text.trim(),
      if (_kind == 'baidu' && _appId.text.trim().isNotEmpty)
        'appId': _appId.text.trim(),
    };
    if (!widget.hasCredentials) config.validateCredentials(credentials);
    return (config: config, credentials: credentials);
  }

  /// test 决定测试草稿还是返回表单结果；测试只发送示例文本，不保存设置。
  Future<void> _submit({required bool test}) async {
    try {
      // 收集经过验证的草稿，凭据始终与普通配置分开传递。
      final draft = _draft();
      if (!test) {
        Navigator.pop(context, draft);
        return;
      }
      setState(() {
        _testing = true;
        _message = null;
      });
      final translation = await const MethodChannel('translateapp/settings')
          .invokeMethod<String>('testService', {
            'config': draft.config.toMap(),
            'credentials': draft.credentials,
          });
      if (mounted) setState(() => _message = '连接成功：$translation');
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = switch (error) {
            PlatformException(:final message) => message,
            FormatException(:final message) => message,
            _ => '操作失败，请重试。',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// context 为对话框上下文；返回服务字段和可验证的连接测试入口。
  @override
  Widget build(BuildContext context) {
    final isModel =
        _kind == 'openai' || _kind == 'deepseek' || _kind == 'anthropic';
    return PopScope(
      canPop: !_testing,
      child: AlertDialog(
        title: Text(widget.config == null ? '添加翻译服务' : '编辑翻译服务'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: '服务类型'),
                  items: ServiceConfig.kinds.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: widget.config != null || _testing
                      ? null
                      : (value) => setState(() {
                          _kind = value!;
                          _name.text = ServiceConfig.kinds[_kind]!;
                          _base.text = ServiceConfig.endpoints[_kind]!;
                          _message = null;
                        }),
                ),
                TextField(
                  controller: _name,
                  enabled: !_testing,
                  decoration: const InputDecoration(labelText: '配置名称'),
                ),
                TextField(
                  controller: _base,
                  enabled: !_testing,
                  decoration: const InputDecoration(
                    labelText: 'API Base URL',
                    helperText: '填写服务根地址；模型接口通常以 /v1 结尾。',
                  ),
                ),
                if (isModel)
                  TextField(
                    controller: _model,
                    enabled: !_testing,
                    decoration: const InputDecoration(
                      labelText: '模型名称',
                      hintText: '填写服务商提供的模型 ID',
                    ),
                  ),
                if (_kind == 'baidu')
                  TextField(
                    controller: _appId,
                    enabled: !_testing,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: '百度 App ID',
                      helperText: widget.hasCredentials ? '已保存，留空保留。' : null,
                    ),
                  ),
                TextField(
                  controller: _key,
                  enabled: !_testing,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: _kind == 'baidu' ? '百度密钥' : 'API Key',
                    helperText: widget.hasCredentials
                        ? '已保存，留空保留；凭据保存在 macOS 钥匙串。'
                        : '凭据保存在 macOS 钥匙串。',
                  ),
                ),
                if (isModel) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _prompt,
                    enabled: !_testing,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '翻译提示词',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('按段落双语对照'),
                    subtitle: const Text('结合全文逐段翻译；段落缺失或乱序时提示重试。'),
                    value: _semantic,
                    onChanged: _testing
                        ? null
                        : (value) => setState(() => _semantic = value),
                  ),
                ],
                if (_kind == 'anthropic')
                  TextField(
                    controller: _tokens,
                    enabled: !_testing,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '最大输出 Token 数',
                    ),
                  ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: SelectableText(_message!),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _testing ? null : () => _submit(test: true),
            child: Text(_testing ? '正在测试…' : '测试连接'),
          ),
          TextButton(
            onPressed: _testing ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _testing ? null : () => _submit(test: false),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
