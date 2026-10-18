import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/mcp_platforms.dart';

/// 验证 MCP 接入平台服务（#96「设置」6–13）：命令式平台的检测、安装、重复安装、删除与路径变化判定，
/// 配置文件式平台的条目读写、备份与其他内容保留，以及安装时清除 helper 隔离属性。
/// CLI 为临时目录中按各家参数格式工作的真实脚本，配置文件位于临时主目录。
void main() {
  late Directory root;
  late Directory bin;
  late Directory home;
  late String helper;

  /// 模拟 claude、codex、grok 的 mcp 子命令：登记的 helper 路径存于脚本旁的 <cli>.registered。
  /// claude 的 add 在名称已存在时失败；get 不存在时退出码为 1；grok 用 list --json 输出数组。
  const fakeCli = r'''#!/bin/bash
cli=$(basename "$0"); store="$(dirname "$0")/$cli.registered"
args=(); skip=0
for a in "$@"; do
  if [ $skip = 1 ]; then skip=0; continue; fi
  case "$a" in -s) skip=1 ;; --json|--) ;; *) args+=("$a") ;; esac
done
case "${args[1]}" in
  get) [ -f "$store" ] || { echo "No MCP server named \"${args[2]}\"" >&2; exit 1; }
       echo "${args[2]}: command $(cat "$store")" ;;
  list) if [ -f "$store" ]; then echo "[{\"name\":\"translateapp\",\"command\":\"$(cat "$store")\"}]"; else echo "[]"; fi ;;
  add) if [ "$cli" = claude ] && [ -f "$store" ]; then echo "MCP server ${args[2]} already exists" >&2; exit 1; fi
       printf '%s' "${args[3]}" > "$store" ;;
  remove) [ -f "$store" ] || { echo "No MCP server named \"${args[2]}\"" >&2; exit 1; }
          rm "$store" ;;
esac
''';

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-platforms-');
    bin = Directory('${root.path}/bin')..createSync();
    home = Directory('${root.path}/home')..createSync();
    helper = '${root.path}/TranslateApp.app/Contents/MacOS/translateapp-mcp';
    File(helper).createSync(recursive: true);
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// 作用：在 bin 中安装一个模拟 CLI。参数 name：可执行文件名。
  void installCli(String name) {
    final file = File('${bin.path}/$name')..writeAsStringSync(fakeCli);
    Process.runSync('/bin/chmod', ['+x', file.path]);
  }

  McpPlatformService service() => McpPlatformService(
    helperPath: helper,
    home: home.path,
    // 系统目录提供 bash、cat 等，模拟 CLI 目录在前。
    searchPath: () async => '${bin.path}:/usr/bin:/bin',
  );

  McpPlatform platform(String id) => mcpPlatforms.firstWhere((p) => p.id == id);

  test('注册表包含 Claude Code、Claude 桌面、Codex、Grok，且只有 Claude 桌面为配置文件式', () {
    expect(mcpPlatforms.map((p) => p.id), [
      'claude-code',
      'claude-desktop',
      'codex',
      'grok',
    ]);
    expect(
      mcpPlatforms
          .where((p) => p.kind == McpPlatformKind.configFile)
          .map((p) => p.id),
      ['claude-desktop'],
    );
  });

  for (final (id, cli) in [
    ('claude-code', 'claude'),
    ('codex', 'codex'),
    ('grok', 'grok'),
  ]) {
    test('$id：未检测到、安装、重复安装、路径变化与删除', () async {
      final mcp = service();
      final target = platform(id);
      expect(await mcp.detect(target), McpInstallState.missing);

      installCli(cli);
      expect(await mcp.detect(target), McpInstallState.notInstalled);
      await mcp.install(target);
      expect(await mcp.detect(target), McpInstallState.installed);
      expect(File('${bin.path}/$cli.registered').readAsStringSync(), helper);

      // 边界依据：claude 的 add 遇到同名条目报错，重复安装必须先删除再添加。
      await mcp.install(target);
      expect(await mcp.detect(target), McpInstallState.installed);

      // App 挪动位置后登记的是旧路径，应判定为路径已变化。
      File('${bin.path}/$cli.registered').writeAsStringSync(
        '/Old/TranslateApp.app/Contents/MacOS/translateapp-mcp',
      );
      expect(await mcp.detect(target), McpInstallState.pathChanged);

      await mcp.remove(target);
      expect(await mcp.detect(target), McpInstallState.notInstalled);
      await expectLater(
        mcp.remove(target),
        throwsA(
          isA<McpPlatformException>().having(
            (e) => e.message,
            'message',
            contains('No MCP server'),
          ),
        ),
      );
    });
  }

  test('命令式平台找不到 CLI 时安装报未检测到', () async {
    await expectLater(
      service().install(platform('codex')),
      throwsA(
        isA<McpPlatformException>().having(
          (e) => e.message,
          'message',
          '未检测到 codex CLI',
        ),
      ),
    );
  });

  test('Claude 桌面：客户端目录缺失为未检测到；安装只写自身条目、保留其他内容并备份原文件', () async {
    final mcp = service();
    final target = platform('claude-desktop');
    expect(await mcp.detect(target), McpInstallState.missing);

    final directory = Directory(
      '${home.path}/Library/Application Support/Claude',
    )..createSync(recursive: true);
    expect(await mcp.detect(target), McpInstallState.notInstalled);

    final config = File('${directory.path}/claude_desktop_config.json');
    const original =
        '{"globalShortcut": "Alt+Space", "mcpServers": {"other": {"command": "/usr/bin/other"}}}';
    config.writeAsStringSync(original);
    await mcp.install(target);
    expect(await mcp.detect(target), McpInstallState.installed);
    final written =
        jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    expect(written['globalShortcut'], 'Alt+Space');
    expect(written['mcpServers'], {
      'other': {'command': '/usr/bin/other'},
      'translateapp': {'command': helper, 'args': <Object?>[]},
    });
    expect(File('${config.path}.bak').readAsStringSync(), original);

    // 条目存在但命令不是当前 helper 时为路径已变化。
    final moved = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    (moved['mcpServers'] as Map)['translateapp'] = {
      'command': '/Old/translateapp-mcp',
    };
    config.writeAsStringSync(jsonEncode(moved));
    expect(await mcp.detect(target), McpInstallState.pathChanged);

    await mcp.remove(target);
    expect(await mcp.detect(target), McpInstallState.notInstalled);
    expect((jsonDecode(config.readAsStringSync()) as Map)['mcpServers'], {
      'other': {'command': '/usr/bin/other'},
    });
  });

  test('Claude 桌面：没有配置文件时安装新建文件；配置不是 JSON 时检测报错并保留原文件', () async {
    final mcp = service();
    final target = platform('claude-desktop');
    final directory = Directory(
      '${home.path}/Library/Application Support/Claude',
    )..createSync(recursive: true);
    final config = File('${directory.path}/claude_desktop_config.json');

    await mcp.install(target);
    expect(jsonDecode(config.readAsStringSync()), {
      'mcpServers': {
        'translateapp': {'command': helper, 'args': <Object?>[]},
      },
    });
    expect(File('${config.path}.bak').existsSync(), isFalse);

    config.writeAsStringSync('{not json');
    await expectLater(
      mcp.detect(target),
      throwsA(
        isA<McpPlatformException>().having(
          (e) => e.message,
          'message',
          contains('不是有效的 JSON'),
        ),
      ),
    );
    expect(config.readAsStringSync(), '{not json');
  });

  test('安装前清除 helper 的 com.apple.quarantine；属性不存在时安装照常成功', () async {
    // 边界依据：下载版 App 解压后带隔离属性，helper 由客户端直接启动时会被 Gatekeeper 拦截。
    Process.runSync('/usr/bin/xattr', [
      '-w',
      'com.apple.quarantine',
      '0081;00000000;Safari;',
      helper,
    ]);
    installCli('grok');
    final mcp = service();
    await mcp.install(platform('grok'));
    final remaining = Process.runSync('/usr/bin/xattr', [
      '-p',
      'com.apple.quarantine',
      helper,
    ]);
    expect(remaining.exitCode, isNot(0));

    await mcp.install(platform('grok'));
    expect(await mcp.detect(platform('grok')), McpInstallState.installed);
  });
}
