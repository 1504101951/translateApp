import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/mcp_constants.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import 'mcp_platforms.dart';

/// 设置窗口的 MCP 页（#96「设置」、#67「设置 MCP 页（#96）」）。
/// 第一组为 MCP 开关、helper 路径与客户端配置复制；第二组按 [mcpPlatforms] 注册表列出接入平台，
/// 提供检测、安装与删除。开关只回报新值，由设置页经主引擎提交队列持久化；
/// helper 路径向原生读取 App 包内实际位置。
class McpSettingsPage extends StatefulWidget {
  /// enabled 为已加载草稿中的开关值；onChanged 接收用户切换后的新值；channel 为设置窗口通道；
  /// createService 按 helper 路径创建平台服务，缺省使用真实 CLI 与用户主目录。
  const McpSettingsPage({
    super.key,
    required this.enabled,
    required this.onChanged,
    required this.channel,
    this.createService = defaultService,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final MethodChannel channel;
  final McpPlatformService Function(String helperPath) createService;

  /// 作用：生成可直接粘贴到 MCP 客户端的配置。
  /// 参数 helperPath：helper 完整路径。
  /// 返回：缩进两格的 JSON 字符串 {"mcpServers": {"translateapp": {"command": 路径, "args": []}}}。
  static String clientConfig(String helperPath) =>
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          McpConstants.serverName: {'command': helperPath, 'args': <String>[]},
        },
      });

  /// 作用：创建执行真实 CLI、读写用户主目录配置的平台服务。参数 helperPath：helper 路径。返回：服务实例。
  static McpPlatformService defaultService(String helperPath) =>
      McpPlatformService(helperPath: helperPath);

  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  static const _copyLabel = '复制客户端配置';
  static const _copiedLabel = '已复制';

  String? _helperPath;
  McpPlatformService? _service;
  bool _copied = false;
  Timer? _feedback;

  /// 各平台状态；未出现的平台视为检测中。
  final Map<String, McpInstallState> _states = {};

  /// 各平台最近一次失败的原文，保留到该平台下次操作。
  final Map<String, String> _errors = {};

  /// 安装或删除成功后需提示重启客户端的配置文件式平台。
  final Set<String> _restartHints = {};

  /// 正在安装或删除的平台，期间两个按钮不可用。
  final Set<String> _working = {};

  /// 无参数；读取 helper 路径后创建平台服务并检测全部平台。
  @override
  void initState() {
    super.initState();
    widget.channel.invokeMethod<String>(MethodNames.mcpHelperPath).then((path) {
      if (!mounted) return;
      setState(() {
        _helperPath = path;
        _service = widget.createService(path!);
      });
      for (final platform in mcpPlatforms) {
        _detect(platform);
      }
    });
  }

  /// 无参数；取消未结束的复制反馈计时。
  @override
  void dispose() {
    _feedback?.cancel();
    super.dispose();
  }

  /// 作用：检测一个平台并刷新该行。参数 platform：注册项。
  /// 配置文件无法解析时状态记为未安装，并显示错误原文。
  Future<void> _detect(McpPlatform platform) async {
    setState(() => _states[platform.id] = McpInstallState.checking);
    McpInstallState state;
    try {
      state = await _service!.detect(platform);
    } on McpPlatformException catch (error) {
      state = McpInstallState.notInstalled;
      _errors[platform.id] = error.message;
    }
    if (mounted) setState(() => _states[platform.id] = state);
  }

  /// 作用：执行安装或删除后重新检测。参数 platform：注册项；action：安装或删除操作。
  /// 失败原文显示在该行下方；配置文件式平台成功后提示重启客户端。
  Future<void> _perform(
    McpPlatform platform,
    Future<void> Function(McpPlatform) action,
  ) async {
    setState(() {
      _working.add(platform.id);
      _errors.remove(platform.id);
      _restartHints.remove(platform.id);
    });
    try {
      await action(platform);
      if (platform is ConfigFileMcpPlatform) _restartHints.add(platform.id);
    } on McpPlatformException catch (error) {
      _errors[platform.id] = error.message;
    }
    if (!mounted) return;
    setState(() => _working.remove(platform.id));
    await _detect(platform);
  }

  /// 作用：二次确认后删除。参数 platform：注册项。
  Future<void> _confirmRemove(McpPlatform platform) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => NativeGlassDialog(
        title: Text('从 ${platform.name} 删除 TranslateApp？'),
        content: const Text('只移除该平台中的 translateapp 条目，可随时重新安装。'),
        actions: [
          NativeGlassSurface(
            material: true,
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
          ),
          NativeGlassSurface(
            material: true,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _perform(platform, _service!.remove);
    }
  }

  /// 无参数；把客户端配置写入剪贴板，按钮文字显示「已复制」1000ms（#96「界面数值」）。
  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: McpSettingsPage.clientConfig(_helperPath!)),
    );
    if (!mounted) return;
    _feedback?.cancel();
    setState(() => _copied = true);
    _feedback = Timer(GlassMetrics.feedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// 作用：生成 28pt 普通文字按钮，并在外层提供 32pt 命中高度。
  /// 参数 key：按钮键；label：按钮内容；onPressed：点击动作，null 为不可用。返回：按钮控件。
  Widget _textButton(Key key, Widget label, VoidCallback? onPressed) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          height: GlassMetrics.hitSize,
          child: Center(
            widthFactor: 1,
            child: NativeGlassSurface(
              material: true,
              child: TextButton(key: key, onPressed: onPressed, child: label),
            ),
          ),
        ),
      );

  /// 作用：生成一个平台行。参数 platform：注册项。返回：最小高 60 的行及其下方的失败原文。
  Widget _platformRow(McpPlatform platform) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall;
    final state = _states[platform.id] ?? McpInstallState.checking;
    final idle = !_working.contains(platform.id);
    final registered =
        state == McpInstallState.installed ||
        state == McpInstallState.pathChanged;
    final canInstall =
        idle && (registered || state == McpInstallState.notInstalled);
    final error = _errors[platform.id];
    return Column(
      key: ValueKey('mcp-platform-${platform.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(platform.name),
                    Text(state.label(platform), style: caption),
                    if (_restartHints.contains(platform.id) &&
                        platform is ConfigFileMcpPlatform)
                      Text(platform.restartHint, style: caption),
                  ],
                ),
              ),
              _textButton(
                ValueKey('mcp-install-${platform.id}'),
                Text(registered ? '重新安装' : '安装'),
                canInstall ? () => _perform(platform, _service!.install) : null,
              ),
              const SizedBox(width: 8),
              _textButton(
                ValueKey('mcp-remove-${platform.id}'),
                const Text('删除'),
                idle && registered ? () => _confirmRemove(platform) : null,
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              error,
              key: ValueKey('mcp-error-${platform.id}'),
              style: caption?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final copy = _helperPath == null ? null : _copy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NativeGlassGroup(
          children: [
            const Text('MCP 接口', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            NativeGlassSwitchTile(
              title: '允许 agent 截图',
              value: widget.enabled,
              onChanged: widget.onChanged,
            ),
            const SizedBox(height: 8),
            const Text('helper 路径'),
            const SizedBox(height: GlassMetrics.labelGap),
            // 完整路径可选中复制，超长换行，不截断、不缩小字号。
            SelectableText(
              _helperPath ?? '',
              key: const ValueKey('mcp-helper-path'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: _textButton(
                const ValueKey('mcp-copy-config'),
                // 隐藏的最长文案占位，反馈文字切换时按钮宽度不变。
                Stack(
                  alignment: Alignment.center,
                  children: [
                    const ExcludeSemantics(
                      child: Opacity(opacity: 0, child: Text(_copyLabel)),
                    ),
                    Text(_copied ? _copiedLabel : _copyLabel),
                  ],
                ),
                copy,
              ),
            ),
          ],
        ),
        NativeGlassGroup(
          children: [
            const Text('接入平台', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (_service != null)
              for (final (index, platform) in mcpPlatforms.indexed) ...[
                if (index > 0) const Divider(height: 1),
                _platformRow(platform),
              ],
          ],
        ),
      ],
    );
  }
}
