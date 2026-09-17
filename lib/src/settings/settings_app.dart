import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'service_config.dart';
import 'service_editor.dart';

/// 设置窗口顶部分段；仅控制展示，不进入持久化偏好。
enum SettingsSection { general, translation, screenshot }

/// 独立可激活窗口的设置 UI；所有偏好读写由主 Dart 引擎处理。
class SettingsApp extends StatelessWidget {
  const SettingsApp({super.key});

  /// context 为设置引擎的构建上下文；返回完整设置应用。
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'TranslateApp 设置',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF246BFD)),
      scaffoldBackgroundColor: const Color(0xFFF5F5F7),
      useMaterial3: true,
    ),
    home: const _SettingsPage(),
  );
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage();
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('translateapp/settings');
  AppSettings? _settings;
  Map<Object?, Object?> _status = {};
  String? _message;
  bool _saving = false;
  bool _recording = false;
  bool _failed = false;
  bool _dirty = false;
  bool _conflicted = false;
  int _revision = 0;
  Set<String> _credentialIds = {};
  final Map<String, Map<String, String>?> _credentials = {};
  SettingsSection _section = SettingsSection.general;

  /// 无参数；加载主引擎偏好，并监听菜单引起的偏好变化，无返回值。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'refreshSettings') await _load();
    });
    _load();
  }

  /// 无参数；解除引擎内的回调和生命周期监听，无返回值。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// state 为窗口活动状态；从系统设置返回时刷新权限，不覆盖未保存表单。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  /// 无参数；读取系统真实权限和登录项状态，完成后刷新界面。
  Future<void> _refreshStatus() async {
    final status = await _channel.invokeMapMethod<Object?, Object?>(
      'systemStatus',
    );
    if (mounted) setState(() => _status = status!);
  }

  /// 无参数；读取主引擎偏好与系统状态，错误显示在窗口中。
  Future<void> _load() async {
    try {
      final map = (await _channel.invokeMapMethod<Object?, Object?>(
        'getSettings',
      ))!;
      await _refreshStatus();
      if (!mounted) return;
      if (_dirty) {
        if (map['revision'] != _revision) {
          setState(() {
            _conflicted = true;
            _failed = true;
            _message = '设置已在菜单中更新。重新加载将放弃当前未保存的编辑。';
          });
        }
        return;
      }
      setState(() {
        _revision = map['revision'] as int;
        _conflicted = false;
        _settings = AppSettings.fromMap(map);
        _credentialIds = Set<String>.from(map['credentialIds'] as List? ?? []);
        _credentials.clear();
        _message = map['error'] as String?;
        _failed = _message != null;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  /// 无参数；提交完整表单，系统配置成功后才展示已保存结果。
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _settings!.validate();
      final saved = (await _channel.invokeMapMethod<Object?, Object?>(
        'saveSettings',
        {
          ..._settings!.toMap(),
          'revision': _revision,
          'credentials': _credentials,
        },
      ))!;
      await _refreshStatus();
      if (!mounted) return;
      setState(() {
        _settings = AppSettings.fromMap(saved);
        _credentialIds = Set<String>.from(
          saved['credentialIds'] as List? ?? [],
        );
        _credentials.clear();
        _revision = saved['revision'] as int;
        _dirty = false;
        _conflicted = false;
        _message = '已保存，下次翻译立即生效。';
        _failed = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (error is PlatformException && error.code == 'settings_conflict') {
          _conflicted = true;
        }
        _message = switch (error) {
          PlatformException(:final message) => message,
          FormatException(:final message) => message,
          _ => '操作失败，请重试。',
        };
        _failed = true;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// screenshot 区分截图/翻译快捷键；录制一次按键，取消保留当前组合，无返回值。
  Future<void> _recordShortcut({bool screenshot = false}) async {
    setState(() => _recording = true);
    try {
      final key = await _channel.invokeMapMethod<Object?, Object?>(
        'recordShortcut',
      );
      if (!mounted || key == null) return;
      _edit(() {
        if (screenshot) {
          _settings!.screenshotShortcutKeyCode = key['keyCode'] as int;
          _settings!.screenshotShortcutModifiers = key['modifiers'] as int;
          _settings!.screenshotShortcutLabel = key['label'] as String;
        } else {
          _settings!.shortcutKeyCode = key['keyCode'] as int;
          _settings!.shortcutModifiers = key['modifiers'] as int;
          _settings!.shortcutLabel = key['label'] as String;
        }
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _recording = false);
    }
  }

  /// 无参数；使用 macOS 应用选择器添加一个排除项，取消不改变表单。
  Future<void> _addExclusion() async {
    final app = await _channel.invokeMapMethod<String, String>(
      'chooseExcludedApp',
    );
    if (app == null || !mounted) return;
    _edit(() => _settings!.excludedApps[app['id']!] = app['name']!);
  }

  /// change 写入一次用户编辑；保留草稿，避免菜单刷新直接覆盖未保存内容。

  /// 无参数；选择固定截图目录，取消保留当前草稿目录。
  Future<void> _chooseScreenshotDirectory() async {
    final path = await _channel.invokeMethod<String>('chooseScreenshotDirectory');
    if (!mounted || path == null) return;
    _edit(() => _settings!.screenshotSaveDirectory = path);
  }

  /// 无参数；由本进程向 TCC 申请屏幕录制，失败则打开系统屏幕录制页。
  Future<void> _requestScreenAccess() async {
    try {
      final status = await _channel.invokeMapMethod<Object?, Object?>(
        'requestScreenAccess',
      );
      if (!mounted || status == null) return;
      setState(() {
        _status = {..._status, ...status};
        _message = status['screenAccess'] == true
            ? '已获得屏幕录制权限。'
            : '请在系统设置中允许 TranslateApp 的屏幕录制。';
        _failed = status['screenAccess'] != true;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  void _edit(VoidCallback change) {
    // 保存回包会替换整个表单；等待期间不接收会被回包覆盖的新编辑。
    if (_saving) return;
    setState(() {
      change();
      _dirty = true;
    });
  }

  /// config 为已有配置或空；确认后更新本窗口草稿，不立即写入凭据。
  Future<void> _editService([ServiceConfig? config]) async {
    final draft =
        await showDialog<
          ({ServiceConfig config, Map<String, String> credentials})
        >(
          context: context,
          barrierDismissible: false,
          builder: (_) => ServiceEditor(
            config: config,
            credentials: _credentials[config?.id] ?? const {},
            hasCredentials: _credentialIds.contains(config?.id),
          ),
        );
    if (draft == null || !mounted) return;
    _edit(() {
      final index = _settings!.services.indexWhere(
        (e) => e.id == draft.config.id,
      );
      if (index < 0) {
        _settings!.services.add(draft.config);
      } else {
        _settings!.services[index] = draft.config;
      }
      if (draft.credentials.isNotEmpty) {
        _credentials[draft.config.id] = draft.credentials;
      }
    });
  }

  /// label/value 为字段名和语言码；optional 允许空值，onChanged 写回表单；返回下拉控件。
  Widget _language(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool optional = false,
  }) {
    final languages = {
      if (optional) '': '不设置',
      ...AppSettings.languages,
      if (value.isNotEmpty && !AppSettings.languages.containsKey(value))
        value: value,
    };
    return Expanded(
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label:$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: languages.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) => _edit(() => onChanged(v!)),
      ),
    );
  }

  /// title 为按钮标题，code/label 为当前组合，screenshot 区分录制目标；返回热键录制区块。
  List<Widget> _shortcutBlock({
    required String title,
    required int code,
    required String label,
    required bool screenshot,
  }) =>
      [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: ValueKey(title),
          onPressed: _saving || _recording
              ? null
              : () => _recordShortcut(screenshot: screenshot),
          icon: const Icon(Icons.keyboard_outlined),
          label: Text(
            _recording
                ? '请按下组合键，Esc 取消…'
                : [
                    if (code & 4096 != 0) '⌃',
                    if (code & 2048 != 0) '⌥',
                    if (code & 512 != 0) '⇧',
                    if (code & 256 != 0) '⌘',
                    label,
                  ].join(' '),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '点击录制；保存时检查系统保留组合和可识别的全局占用。',
          style: TextStyle(fontSize: 12, color: Color(0xFF72747B)),
        ),
      ];

  /// context 为窗口上下文；返回可滚动表单与保存反馈。
  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return Scaffold(
        body: Center(
          child: _message == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_message!),
                    TextButton(onPressed: _load, child: const Text('重新加载')),
                  ],
                ),
        ),
      );
    }
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'TranslateApp',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text('选中文字，随手翻译。', style: TextStyle(color: Color(0xFF72747B))),
          const SizedBox(height: 24),
      SegmentedButton<SettingsSection>(
        segments: const [
          ButtonSegment(
            value: SettingsSection.general,
            label: Text('通用'),
            icon: Icon(Icons.tune),
          ),
          ButtonSegment(
            value: SettingsSection.translation,
            label: Text('翻译'),
            icon: Icon(Icons.translate),
          ),
          ButtonSegment(
            value: SettingsSection.screenshot,
            label: Text('截图'),
            icon: Icon(Icons.crop_free),
          ),
        ],
        selected: {_section},
        onSelectionChanged: (next) {
          setState(() => _section = next.single);
        },
      ),
      const SizedBox(height: 24),
      if (_section == SettingsSection.general) ...[
        Row(
          children: [
            const Expanded(
              child: Text(
                '排除应用',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: _addExclusion,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加应用'),
            ),
          ],
        ),
        if (settings.excludedApps.isEmpty)
          const Text(
            '所有支持读取选区的应用均可翻译。',
            style: TextStyle(color: Color(0xFF72747B)),
          ),
        for (final app in settings.excludedApps.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(app.value),
            subtitle: Text(app.key),
            trailing: IconButton(
              tooltip: '移除排除项',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () =>
                  _edit(() => settings.excludedApps.remove(app.key)),
            ),
          ),
        const Divider(height: 28),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('登录时启动'),
          value: settings.launchAtLogin,
          onChanged: (v) => _edit(() => settings.launchAtLogin = v),
        ),
        if (_status['loginNeedsApproval'] == true)
          TextButton(
            onPressed: () => _channel.invokeMethod<void>('openLoginItems'),
            child: const Text('在系统设置中允许登录项'),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('辅助功能权限'),
          subtitle: Text(
            _status['accessibility'] == true ? '已授权' : '未授权，无法读取选中文字',
          ),
          trailing: TextButton(
            onPressed: () => _channel.invokeMethod<void>('openAccessibility'),
            child: const Text('打开设置'),
          ),
        ),
      ] else if (_section == SettingsSection.translation) ...[

        const Text('翻译语言', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Row(
          children: [
            _language(
              '主要语言',
              settings.primaryLanguage,
              (v) => settings.primaryLanguage = v,
            ),
            const SizedBox(width: 12),
            _language(
              '次要语言（可选）',
              settings.secondaryLanguage ?? '',
              (v) => settings.secondaryLanguage = v.isEmpty ? null : v,
              optional: true,
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '设置次要语言时，主要语言文本译为次要语言；不设置时统一译为主要语言，已是主要语言的文本直接展示。',
            style: TextStyle(fontSize: 12, color: Color(0xFF72747B)),
          ),
        ),
        const Divider(height: 28),
        Row(
          children: [
            const Expanded(
              child: Text(
                '翻译服务',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: () => _editService(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加服务'),
            ),
          ],
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('default:${settings.defaultServiceId}'),
          initialValue: settings.defaultServiceId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '默认翻译服务',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(
              value: ServiceConfig.builtinId,
              child: Text('Unofficial Google'),
            ),
            ...settings.services.map(
              (e) => DropdownMenuItem(value: e.id, child: Text(e.name)),
            ),
          ],
          onChanged: (v) => _edit(() => settings.defaultServiceId = v!),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Unofficial Google 是默认内置 API；翻译发送到选中的服务。',
            style: TextStyle(fontSize: 12, color: Color(0xFF72747B)),
          ),
        ),
        for (final service in settings.services)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(service.name),
            subtitle: Text(
              '${ServiceConfig.kinds[service.kind]}${service.isModel ? ' · ${service.model}' : ''}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '编辑 ${service.name}',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editService(service),
                ),
                IconButton(
                  tooltip: '删除 ${service.name}',
                  onPressed: () => _edit(() {
                    settings.services.remove(service);
                    _credentials[service.id] = null;
                    if (settings.defaultServiceId == service.id) {
                      settings.defaultServiceId = ServiceConfig.builtinId;
                    }
                  }),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('仅使用快捷键'),
          subtitle: const Text('关闭自动按钮后，只能通过快捷键唤醒翻译'),
          value: !settings.automatic,
          onChanged: (v) => _edit(() => settings.automatic = !v),
        ),
        const Divider(height: 28),
        ..._shortcutBlock(
          title: '全局翻译快捷键',
          code: settings.shortcutModifiers,
          label: settings.shortcutLabel,
          screenshot: false,
        ),
      ] else ...[

        const Text('截图目录', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ListTile(
          key: const ValueKey('截图目录'),
          contentPadding: EdgeInsets.zero,
          title: Text(
            settings.screenshotSaveDirectory.isEmpty
                ? '保存时选择位置'
                : settings.screenshotSaveDirectory,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const Text('固定目录后，保存截图默认写入此处；空目录表示每次询问。'),
          trailing: Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: _saving || _recording
                    ? null
                    : _chooseScreenshotDirectory,
                child: const Text('选择…'),
              ),
              if (settings.screenshotSaveDirectory.isNotEmpty)
                TextButton(
                  onPressed: _saving || _recording
                      ? null
                      : () => _edit(() => settings.screenshotSaveDirectory = ''),
                  child: const Text('每次询问'),
                ),
            ],
          ),
        ),
        const Divider(height: 28),
        ..._shortcutBlock(
          title: '区域截图快捷键',
          code: settings.screenshotShortcutModifiers,
          label: settings.screenshotShortcutLabel,
          screenshot: true,
        ),

        const Divider(height: 28),
        ListTile(
          key: const ValueKey('屏幕录制权限'),
          contentPadding: EdgeInsets.zero,
          title: const Text('屏幕录制权限'),
          subtitle: Text(
            _status['screenAccess'] == true
                ? '已授权，可截取屏幕'
                : '未授权；申请后 TranslateApp 会出现在系统屏幕录制列表',
          ),
          trailing: TextButton(
            onPressed: _saving || _recording ? null : _requestScreenAccess,
            child: Text(_status['screenAccess'] == true ? '重新检查' : '申请权限'),
          ),
        ),
      ],

          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving || _recording || _conflicted ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存设置'),
          ),
          if (_conflicted)
            TextButton(
              onPressed: () {
                _dirty = false;
                _load();
              },
              child: const Text('重新加载设置'),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _message!,
                style: TextStyle(
                  color: _failed
                      ? Theme.of(context).colorScheme.error
                      : const Color(0xFF34834B),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
