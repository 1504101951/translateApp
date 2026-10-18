import 'dart:convert';
import 'dart:io';

import '../common/constants/mcp_constants.dart';

/// 平台接入类型（#96「设置」4、14）：命令式调用各家 CLI 的 MCP 子命令；配置文件式只读写自身条目。
enum McpPlatformKind { command, configFile }

/// 平台安装状态（#96「设置」6）；label 为状态行文案。
enum McpInstallState {
  missing,
  checking,
  notInstalled,
  installed,
  pathChanged;

  /// 作用：返回状态文案。参数 platform：所属平台，「未检测到」文案取其客户端名。返回：状态行文字。
  String label(McpPlatform platform) => switch (this) {
    missing => '未检测到 ${platform.clientName}',
    checking => '检测中',
    notInstalled => '未安装',
    installed => '已安装',
    pathChanged => '路径已变化',
  };
}

/// 接入平台注册项（#96「设置」14）：新增平台只增加注册项，界面与服务按类型处理。
sealed class McpPlatform {
  const McpPlatform({required this.id, required this.name});

  /// 稳定标识，界面以此区分行状态。
  final String id;

  /// 列表中显示的平台名。
  final String name;

  /// 「未检测到 …」中使用的客户端名。
  String get clientName;

  McpPlatformKind get kind;
}

/// 命令式平台：参数中的 [helperToken] 在执行时替换为当前 helper 路径。
/// 安装时先执行 removeArgs（忽略失败）再执行 addArgs，使「名称已存在即报错」的 CLI 也能重复安装。
class CommandMcpPlatform extends McpPlatform {
  const CommandMcpPlatform({
    required super.id,
    required super.name,
    required this.executable,
    required this.detectArgs,
    required this.addArgs,
    required this.removeArgs,
  });

  /// 执行时替换为 helper 绝对路径的占位参数。
  static const helperToken = '{helper}';

  /// CLI 可执行文件名，在用户登录 shell 的 PATH 中查找。
  final String executable;
  final List<String> detectArgs;
  final List<String> addArgs;
  final List<String> removeArgs;

  @override
  String get clientName => '$executable CLI';

  @override
  McpPlatformKind get kind => McpPlatformKind.command;
}

/// 配置文件式平台：只读写 JSON 配置中 `mcpServers.translateapp`，其他内容原样保留。
class ConfigFileMcpPlatform extends McpPlatform {
  const ConfigFileMcpPlatform({
    required super.id,
    required super.name,
    required this.clientName,
    required this.clientDirectory,
    required this.configFile,
    required this.restartHint,
  });

  @override
  final String clientName;

  /// 客户端数据目录，相对用户主目录；不存在表示客户端未安装或从未启动。
  final String clientDirectory;

  /// 配置文件，相对 [clientDirectory]。
  final String configFile;

  /// 安装或删除成功后的生效提示。
  final String restartHint;

  @override
  McpPlatformKind get kind => McpPlatformKind.configFile;
}

/// 接入平台注册表，顺序即列表顺序（#96「设置」4）。
const mcpPlatforms = <McpPlatform>[
  CommandMcpPlatform(
    id: 'claude-code',
    name: 'Claude Code',
    executable: 'claude',
    detectArgs: ['mcp', 'get', McpConstants.serverName],
    addArgs: [
      'mcp',
      'add',
      '-s',
      'user',
      McpConstants.serverName,
      '--',
      CommandMcpPlatform.helperToken,
    ],
    removeArgs: ['mcp', 'remove', '-s', 'user', McpConstants.serverName],
  ),
  ConfigFileMcpPlatform(
    id: 'claude-desktop',
    name: 'Claude 桌面',
    clientName: 'Claude 桌面',
    clientDirectory: 'Library/Application Support/Claude',
    configFile: 'claude_desktop_config.json',
    restartHint: '重启 Claude 后生效',
  ),
  CommandMcpPlatform(
    id: 'codex',
    name: 'Codex（CLI 与桌面 App 共用）',
    executable: 'codex',
    detectArgs: ['mcp', 'get', McpConstants.serverName, '--json'],
    addArgs: [
      'mcp',
      'add',
      McpConstants.serverName,
      '--',
      CommandMcpPlatform.helperToken,
    ],
    removeArgs: ['mcp', 'remove', McpConstants.serverName],
  ),
  CommandMcpPlatform(
    id: 'grok',
    name: 'Grok',
    executable: 'grok',
    detectArgs: ['mcp', 'list', '--json'],
    addArgs: [
      'mcp',
      'add',
      '-s',
      'user',
      McpConstants.serverName,
      CommandMcpPlatform.helperToken,
    ],
    removeArgs: ['mcp', 'remove', '-s', 'user', McpConstants.serverName],
  ),
];

/// 平台安装或删除失败；message 为 CLI 输出或文件读写的错误原文。
class McpPlatformException implements Exception {
  const McpPlatformException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 按注册表检测、安装、删除 TranslateApp 的 MCP 条目（#96「设置」6–13）。
/// 命令在用户主目录执行，CLI 在登录 shell 的 PATH 中查找；只增删 `translateapp` 条目。
class McpPlatformService {
  /// helperPath 为当前 App 包内 helper 的绝对路径；home 为用户主目录；
  /// searchPath 返回查找 CLI 用的 PATH（冒号分隔），缺省读取用户登录 shell 的 PATH。
  McpPlatformService({
    required this.helperPath,
    String? home,
    Future<String> Function()? searchPath,
  }) : home = home ?? Platform.environment['HOME']!,
       _searchPath = searchPath ?? loginShellPath;

  final String helperPath;
  final String home;
  final Future<String> Function() _searchPath;
  Future<String>? _path;

  /// 作用：读取用户登录 shell 的 PATH。从访达启动的 App 不继承终端 PATH，
  /// 交互式登录 shell 才会加载 .zprofile 与 .zshrc 中的 PATH 设置。
  /// 返回：冒号分隔的 PATH；shell 启动输出的其他文字以标记隔开后丢弃。
  static Future<String> loginShellPath() async {
    const marker = '__TRANSLATEAPP_PATH__';
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    final result = await Process.run(shell, [
      '-ilc',
      'printf "$marker%s" "\$PATH"',
    ]);
    final output = result.stdout as String;
    return output.substring(output.lastIndexOf(marker) + marker.length).trim();
  }

  /// 作用：检测平台状态。参数 platform：注册项。
  /// 返回：missing、notInstalled、installed 或 pathChanged；配置文件不可解析时抛 McpPlatformException。
  Future<McpInstallState> detect(McpPlatform platform) async {
    switch (platform) {
      case CommandMcpPlatform():
        final executable = await _locate(platform.executable);
        if (executable == null) return McpInstallState.missing;
        final result = await _run(executable, platform.detectArgs);
        final output = '${result.stdout}';
        if (result.exitCode != 0) return McpInstallState.notInstalled;
        if (output.contains(helperPath)) return McpInstallState.installed;
        return output.contains(McpConstants.serverName)
            ? McpInstallState.pathChanged
            : McpInstallState.notInstalled;
      case ConfigFileMcpPlatform():
        if (!Directory(_clientDirectory(platform)).existsSync()) {
          return McpInstallState.missing;
        }
        final entry = _servers(
          await _readConfig(platform),
        )[McpConstants.serverName];
        if (entry == null) return McpInstallState.notInstalled;
        return entry is Map && entry['command'] == helperPath
            ? McpInstallState.installed
            : McpInstallState.pathChanged;
    }
  }

  /// 作用：安装或重新安装到平台；先清除 helper 的隔离属性（#96「设置」10）。
  /// 参数 platform：注册项。失败时抛 McpPlatformException。
  Future<void> install(McpPlatform platform) async {
    await _clearQuarantine();
    switch (platform) {
      case CommandMcpPlatform():
        final executable = await _requireExecutable(platform);
        // 先删除同名条目；条目不存在时 CLI 返回失败，忽略即可。
        await _run(executable, platform.removeArgs);
        await _checked(executable, [
          for (final arg in platform.addArgs)
            arg == CommandMcpPlatform.helperToken ? helperPath : arg,
        ]);
      case ConfigFileMcpPlatform():
        final config = await _readConfig(platform);
        final servers = _servers(config);
        servers[McpConstants.serverName] = {
          'command': helperPath,
          'args': <String>[],
        };
        config['mcpServers'] = servers;
        await _writeConfig(platform, config);
    }
  }

  /// 作用：从平台删除 TranslateApp 条目。参数 platform：注册项。失败时抛 McpPlatformException。
  Future<void> remove(McpPlatform platform) async {
    switch (platform) {
      case CommandMcpPlatform():
        await _checked(await _requireExecutable(platform), platform.removeArgs);
      case ConfigFileMcpPlatform():
        final config = await _readConfig(platform);
        _servers(config).remove(McpConstants.serverName);
        await _writeConfig(platform, config);
    }
  }

  /// 作用：在登录 shell 的 PATH 中查找可执行文件。参数 name：文件名。返回：绝对路径，找不到为 null。
  Future<String?> _locate(String name) async {
    final path = await (_path ??= _searchPath());
    for (final directory in path.split(':')) {
      if (directory.isEmpty) continue;
      final candidate = File('$directory/$name');
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }

  /// 作用：查找命令式平台的 CLI。参数 platform：注册项。返回：绝对路径；找不到时抛 McpPlatformException。
  Future<String> _requireExecutable(CommandMcpPlatform platform) async {
    final executable = await _locate(platform.executable);
    if (executable == null) {
      throw McpPlatformException('未检测到 ${platform.clientName}');
    }
    return executable;
  }

  /// 作用：在用户主目录执行命令。参数 executable：绝对路径；args：参数。
  /// 返回：进程结果；PATH 使用登录 shell 的值，使以 env 查找解释器的 CLI 能启动。
  Future<ProcessResult> _run(String executable, List<String> args) async =>
      Process.run(
        executable,
        args,
        workingDirectory: home,
        environment: {'PATH': await (_path ??= _searchPath())},
      );

  /// 作用：执行命令并要求成功。参数 executable、args：同 _run。失败时以输出原文抛 McpPlatformException。
  Future<void> _checked(String executable, List<String> args) async {
    final result = await _run(executable, args);
    if (result.exitCode == 0) return;
    final message = '${result.stderr}'.trim().isNotEmpty
        ? '${result.stderr}'.trim()
        : '${result.stdout}'.trim();
    throw McpPlatformException(message);
  }

  /// 作用：清除 helper 的 com.apple.quarantine 扩展属性；属性不存在不算失败。
  Future<void> _clearQuarantine() async {
    final result = await Process.run('/usr/bin/xattr', [
      '-d',
      'com.apple.quarantine',
      helperPath,
    ]);
    final error = '${result.stderr}'.trim();
    if (result.exitCode == 0 || error.contains('No such xattr')) return;
    throw McpPlatformException(error);
  }

  /// 作用：返回配置文件式平台的客户端目录。参数 platform：注册项。返回：绝对路径。
  String _clientDirectory(ConfigFileMcpPlatform platform) =>
      '$home/${platform.clientDirectory}';

  /// 作用：读取 JSON 配置。参数 platform：注册项。
  /// 返回：可修改的顶层对象，文件不存在时为空对象；内容不是 JSON 对象时抛 McpPlatformException。
  Future<Map<String, Object?>> _readConfig(
    ConfigFileMcpPlatform platform,
  ) async {
    final file = File('${_clientDirectory(platform)}/${platform.configFile}');
    if (!file.existsSync()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException catch (error) {
      throw McpPlatformException('${file.path} 不是有效的 JSON：${error.message}');
    }
    throw McpPlatformException('${file.path} 顶层不是 JSON 对象');
  }

  /// 作用：取出配置中的 mcpServers。参数 config：顶层对象。返回：可修改的服务表，缺失时为新的空表。
  Map<String, Object?> _servers(Map<String, Object?> config) {
    final servers = config['mcpServers'];
    if (servers is Map<String, Object?>) return servers;
    return {};
  }

  /// 作用：备份原文件后写入配置。参数 platform：注册项；config：完整顶层对象。
  /// 先写同目录临时文件再改名，避免写到一半的文件被客户端读取。
  Future<void> _writeConfig(
    ConfigFileMcpPlatform platform,
    Map<String, Object?> config,
  ) async {
    final file = File('${_clientDirectory(platform)}/${platform.configFile}');
    try {
      if (file.existsSync()) await file.copy('${file.path}.bak');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(config)}\n',
      );
      await temporary.rename(file.path);
    } on FileSystemException catch (error) {
      throw McpPlatformException('${error.message}：${error.path}');
    }
  }
}
