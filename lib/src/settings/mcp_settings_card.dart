import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/mcp_constants.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';

/// 截图设置页的「MCP 接口」卡片（#96「设置」、#67「截图页 MCP 接口卡片（#96）」）。
/// 开关只回报新值，由设置页经主引擎提交队列持久化；helper 路径向原生读取 App 包内实际位置，
/// 开关关闭时路径与复制按钮照常可用。
class McpSettingsCard extends StatefulWidget {
  /// enabled 为已加载草稿中的开关值；onChanged 接收用户切换后的新值；
  /// channel 为设置窗口通道，用于读取 helper 路径。
  const McpSettingsCard({
    super.key,
    required this.enabled,
    required this.onChanged,
    required this.channel,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final MethodChannel channel;

  /// 作用：生成可直接粘贴到 MCP 客户端的配置。
  /// 参数 helperPath：helper 完整路径。
  /// 返回：缩进两格的 JSON 字符串 {"mcpServers": {"translateapp": {"command": 路径, "args": []}}}。
  static String clientConfig(String helperPath) =>
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': {
          McpConstants.serverName: {'command': helperPath, 'args': <String>[]},
        },
      });

  @override
  State<McpSettingsCard> createState() => _McpSettingsCardState();
}

class _McpSettingsCardState extends State<McpSettingsCard> {
  static const _copyLabel = '复制客户端配置';
  static const _copiedLabel = '已复制';

  String? _helperPath;
  bool _copied = false;
  Timer? _feedback;

  /// 无参数；读取 helper 路径，读取完成前复制按钮不可用。
  @override
  void initState() {
    super.initState();
    widget.channel.invokeMethod<String>(MethodNames.mcpHelperPath).then((path) {
      if (mounted) setState(() => _helperPath = path);
    });
  }

  /// 无参数；取消未结束的复制反馈计时。
  @override
  void dispose() {
    _feedback?.cancel();
    super.dispose();
  }

  /// 无参数；把客户端配置写入剪贴板，按钮文字显示「已复制」1000ms（#96 待确认值）。
  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: McpSettingsCard.clientConfig(_helperPath!)),
    );
    if (!mounted) return;
    _feedback?.cancel();
    setState(() => _copied = true);
    _feedback = Timer(GlassMetrics.feedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final copy = _helperPath == null ? null : _copy;
    return NativeGlassGroup(
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
          // 28pt 按钮外再给 32pt 命中高度；按钮自身点击优先，边缘空白由外层接收。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: copy,
            child: SizedBox(
              height: GlassMetrics.hitSize,
              child: Center(
                widthFactor: 1,
                child: NativeGlassSurface(
                  material: true,
                  child: TextButton(
                    key: const ValueKey('mcp-copy-config'),
                    onPressed: copy,
                    // 隐藏的最长文案占位，反馈文字切换时按钮宽度不变。
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const ExcludeSemantics(
                          child: Opacity(opacity: 0, child: Text(_copyLabel)),
                        ),
                        Text(_copied ? _copiedLabel : _copyLabel),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
