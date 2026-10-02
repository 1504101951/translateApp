import '../common/constants/glass_metrics.dart';
import '../common/constants/appearance_modes.dart';
import '../common/constants/method_names.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/error_codes.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/native_glass.dart';

import 'app_settings.dart';
import 'service_config.dart';
import 'screenshot_toolbar_editor.dart';
import 'service_editor.dart';

/// 设置窗口顶部分段；仅控制展示，不进入持久化偏好。
enum SettingsSection { general, translation, screenshot }

/// 独立可激活窗口的设置 UI；所有偏好读写由主 Dart 引擎处理。
class SettingsApp extends StatelessWidget {
  const SettingsApp({super.key});

  /// context 为设置引擎的构建上下文；返回完整设置应用。
  @override
  Widget build(BuildContext context) => NativeGlassApp(
    title: 'TranslateApp 设置',
    home: const NativeGlassWindowPage(child: _SettingsPage()),
  );
}

/// 设置页有状态入口；将主题应用与草稿、保存事务生命周期分开。
class _SettingsPage extends StatefulWidget {
  const _SettingsPage();
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

/// 管理本地草稿、版本冲突和串行自动保存；旧回包不能覆盖新编辑。
class _SettingsPageState extends State<_SettingsPage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel(ChannelNames.settings);
  AppSettings? _settings;
  final _gifMaximumWidth = TextEditingController();
  Map<Object?, Object?> _status = {};
  String? _message;
  bool _saving = false;
  bool _recording = false;
  bool _failed = false;
  bool _dirty = false;
  bool _conflicted = false;
  int _revision = 0;
  int _editGeneration = 0;
  bool _adjustingOpacity = false;
  Set<String> _credentialIds = {};
  final Map<String, Map<String, String>?> _credentials = {};
  SettingsSection _section = SettingsSection.general;

  /// 无参数；加载主引擎偏好，并监听菜单引起的偏好变化，无返回值。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.refreshSettings) await _load();
    });
    _load();
  }

  /// 无参数；解除引擎内的回调和生命周期监听，无返回值。
  @override
  void dispose() {
    _gifMaximumWidth.dispose();
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
      MethodNames.systemStatus,
    );
    if (mounted) setState(() => _status = status!);
  }

  /// 无参数；读取主引擎偏好与系统状态，错误显示在窗口中。
  Future<void> _load() async {
    try {
      final map = (await _channel.invokeMapMethod<Object?, Object?>(
        MethodNames.getSettings,
      ))!;
      await _refreshStatus();
      if (!mounted) return;
      // 系统状态查询期间可能完成自动保存，旧加载快照不能回退表单及其版本。
      if ((map['revision'] as int) < _revision) return;
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
        _gifMaximumWidth.text = _settings!.gifMaximumWidth?.toString() ?? '';
        _credentialIds = Set<String>.from(
          map[MethodNames.credentialIds] as List? ?? [],
        );
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

  /// 无参数；串行提交当前有效草稿，成功推进版本，失败保留编辑并停止重试。
  Future<void> _save() async {
    if (_saving || !_dirty || _conflicted || _adjustingOpacity) return;
    setState(() {
      _saving = true;
      _failed = false;
      // 后台保存不改变布局；仅失败或冲突需要用户可见反馈。
      _message = null;
    });
    try {
      while (_dirty && !_conflicted && !_adjustingOpacity) {
        _settings!.validate();
        final generation = _editGeneration;
        // 深拷贝本次事务；请求等待期间的新编辑不能修改已提交快照。
        final preferences = AppSettings.fromMap(_settings!.toMap()).toMap();
        final credentials = _credentials.map(
          (id, value) => MapEntry(
            id,
            value == null ? null : Map<String, String>.from(value),
          ),
        );
        final saved = (await _channel.invokeMapMethod<Object?, Object?>(
          MethodNames.saveSettings,
          {...preferences, 'revision': _revision, 'credentials': credentials},
        ))!;
        if (!mounted) return;
        setState(() {
          _revision = saved['revision'] as int;
          _credentialIds = Set<String>.from(
            saved[MethodNames.credentialIds] as List? ?? [],
          );
          // 只移除已确认的凭据变更；后续新密钥或删除操作仍留在下一笔事务。
          for (final entry in credentials.entries) {
            if (_credentials.containsKey(entry.key) &&
                mapEquals(_credentials[entry.key], entry.value)) {
              _credentials.remove(entry.key);
            }
          }
          if (generation == _editGeneration) {
            _settings = AppSettings.fromMap(saved);
            _dirty = false;
          }
          if (!_conflicted) {
            _message = null;
          }
        });
        // 状态查询期间也可能继续编辑；下一轮仍检查最新草稿，不遗漏尾部更改。
        await _refreshStatus();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (error is PlatformException &&
            error.code == ErrorCodes.settingsConflict) {
          _conflicted = true;
        }
        _message = switch (error) {
          PlatformException(:final message) => message,
          FormatException(:final message) => message,
          _ => '自动保存失败，请重试。',
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
        MethodNames.recordShortcut,
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
      MethodNames.chooseExcludedApp,
    );
    if (app == null || !mounted) return;
    _edit(() => _settings!.excludedApps[app['id']!] = app['name']!);
  }

  /// 无参数；选择固定截图目录，取消保留当前草稿目录。
  Future<void> _chooseScreenshotDirectory() async {
    final path = await _channel.invokeMethod<String>(
      MethodNames.chooseScreenshotDirectory,
    );
    if (!mounted || path == null) return;
    _edit(() => _settings!.screenshotSaveDirectory = path);
  }

  /// 无参数；由本进程向 TCC 申请屏幕录制，失败则打开系统屏幕录制页。
  Future<void> _requestScreenAccess() async {
    try {
      final status = await _channel.invokeMapMethod<Object?, Object?>(
        MethodNames.requestScreenAccess,
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

  /// change 修改当前草稿；submit 为 false 时由连续控件结束回调提交，返回 void。
  void _edit(VoidCallback change, {bool submit = true}) {
    setState(() {
      change();
      _editGeneration += 1;
      _dirty = true;
    });
    // 同一时刻只有一个事务；正在保存时由回包后的循环提交最新草稿。
    if (submit) _save();
  }

  /// config 为已有配置或空；确认后自动提交完整服务事务，取消不写入配置或凭据。
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
    return NativeGlassDropdown<String>(
      label: label,
      value: value,
      items: languages,
      onChanged: (v) => _edit(() => onChanged(v)),
    );
  }

  /// title 为按钮标题，code/label 为当前组合，screenshot 区分录制目标；返回热键录制区块。
  List<Widget> _shortcutBlock({
    required String title,
    required int code,
    required String label,
    required bool screenshot,
  }) => [
    // 同一行保留标题和录制命中区，不通过常驻说明增加页面高度。
    ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          NativeGlassSurface(
            material: true,
            child: OutlinedButton.icon(
              key: ValueKey(title),
              onPressed: _recording
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
          ),
        ],
      ),
    ),
  ];

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
                    NativeGlassSurface(
                      material: true,
                      child: TextButton(
                        onPressed: _load,
                        child: const Text('重新加载'),
                      ),
                    ),
                  ],
                ),
        ),
      );
    }
    return Scaffold(
      // 顶部导航在滚动视口之外，任何滚动位置都能切换设置分组。
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: const ValueKey('settings-fixed-navigation'),
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 12),
            child: Wrap(
              spacing: 24,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '设置',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                NativeGlassSegments<SettingsSection>(
                  value: _section,
                  navigation: true,
                  options: const {
                    SettingsSection.general: '通用',
                    SettingsSection.translation: '翻译',
                    SettingsSection.screenshot: '截图',
                  },
                  icons: const {
                    SettingsSection.general: Icons.tune,
                    SettingsSection.translation: Icons.translate,
                    SettingsSection.screenshot: Icons.crop_free,
                  },
                  onChanged: (value) => setState(() => _section = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 22),
              children: [
                if (_section == SettingsSection.general) ...[
                  NativeGlassGroup(
                    children: [
                      NativeGlassSettingRow(
                        title: '外观',
                        child: NativeGlassSegments<String>(
                          value: settings.glassAppearance,
                          options: AppearanceModes.labels,
                          onChanged: (value) =>
                              _edit(() => settings.glassAppearance = value),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '玻璃透明度 ${(100 * (1 - settings.glassOpacity)).round()}%',
                      ),
                      // 滑块仅绘制轨道和滑点，不创建整条玻璃外壳。
                      SizedBox(
                        height: GlassMetrics.sliderHeight,
                        child: Slider(
                          value: 1 - settings.glassOpacity,
                          min: 0,
                          max: 0.8,
                          divisions: 80,
                          label:
                              '${(100 * (1 - settings.glassOpacity)).round()}%',
                          // 按滑块的整数百分比换算，避免 1 - 0.8 略小于合法下限 0.2。
                          onChanged: (value) => _edit(
                            () => settings.glassOpacity =
                                (100 - (value * 100).round()) / 100,
                            submit: false,
                          ),
                          onChangeStart: (_) => _adjustingOpacity = true,
                          onChangeEnd: (_) {
                            _adjustingOpacity = false;
                            _save();
                          },
                        ),
                      ),
                      const Text('更改后自动保存并应用到所有窗口；系统“减少透明度”开启时保持材料不透明。'),
                    ],
                  ),
                  NativeGlassGroup(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '排除应用',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          NativeGlassSurface(
                            material: true,
                            child: TextButton.icon(
                              onPressed: _addExclusion,
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('添加应用'),
                            ),
                          ),
                        ],
                      ),
                      for (final app in settings.excludedApps.entries)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(app.value),
                          trailing: NativeGlassSurface(
                            material: true,
                            child: IconButton(
                              tooltip: '移除排除项',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () => _edit(
                                () => settings.excludedApps.remove(app.key),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  NativeGlassGroup(
                    children: [
                      NativeGlassSwitchTile(
                        title: '登录时启动',
                        value: settings.launchAtLogin,
                        onChanged: (v) =>
                            _edit(() => settings.launchAtLogin = v),
                      ),
                      if (_status['loginNeedsApproval'] == true)
                        NativeGlassSurface(
                          material: true,
                          child: TextButton(
                            onPressed: () => _channel.invokeMethod<void>(
                              MethodNames.openLoginItems,
                            ),
                            child: const Text('在系统设置中允许登录项'),
                          ),
                        ),
                    ],
                  ),
                  // 系统权限集中在一张卡片，登录启动单独成组。
                  NativeGlassGroup(
                    children: [
                      ListTile(
                        minTileHeight: 56,
                        contentPadding: EdgeInsets.zero,
                        title: Row(
                          children: [
                            const Text('辅助功能权限'),
                            const SizedBox(width: 8),
                            Text(
                              _status['accessibility'] == true ? '已授权' : '未授权',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        trailing: NativeGlassSurface(
                          material: true,
                          child: TextButton(
                            onPressed: () => _channel.invokeMethod<void>(
                              MethodNames.openAccessibility,
                            ),
                            child: const Text('打开设置'),
                          ),
                        ),
                      ),
                      ListTile(
                        key: const ValueKey('屏幕录制权限'),
                        minTileHeight: 56,
                        contentPadding: EdgeInsets.zero,
                        title: Row(
                          children: [
                            const Text('屏幕录制权限'),
                            const SizedBox(width: 8),
                            Text(
                              _status['screenAccess'] == true ? '已授权' : '未授权',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        trailing: NativeGlassSurface(
                          material: true,
                          child: TextButton(
                            onPressed: _recording ? null : _requestScreenAccess,
                            child: Text(
                              _status['screenAccess'] == true ? '重新检查' : '申请权限',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else if (_section == SettingsSection.translation) ...[
                  NativeGlassGroup(
                    children: [
                      const Text(
                        '翻译语言',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      _language(
                        '主要语言',
                        settings.primaryLanguage,
                        (v) => settings.primaryLanguage = v,
                      ),
                      const Divider(height: 1),
                      _language(
                        '次要语言（可选）',
                        settings.secondaryLanguage ?? '',
                        (v) =>
                            settings.secondaryLanguage = v.isEmpty ? null : v,
                        optional: true,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          '当翻译文本识别为主要语言时，会自动翻译成次要语言',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                  NativeGlassGroup(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '翻译服务',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          NativeGlassSurface(
                            material: true,
                            child: TextButton.icon(
                              onPressed: () => _editService(),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('添加服务'),
                            ),
                          ),
                        ],
                      ),
                      NativeGlassDropdown<String>(
                        label: '默认翻译服务',
                        value: settings.defaultServiceId,
                        items: {
                          ServiceConfig.builtinId: '谷歌翻译',
                          for (final service in settings.services)
                            service.id: service.displayName,
                        },
                        onChanged: (value) =>
                            _edit(() => settings.defaultServiceId = value),
                      ),

                      for (final service in settings.services)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(service.displayName),
                          subtitle: Text(
                            '${ServiceConfig.kinds[service.kind]}${service.isModel ? ' · ${service.model}' : ''}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              NativeGlassSurface(
                                material: true,
                                child: IconButton(
                                  tooltip: '编辑 ${service.displayName}',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _editService(service),
                                ),
                              ),
                              const SizedBox(width: GlassMetrics.actionGap),
                              NativeGlassSurface(
                                material: true,
                                child: IconButton(
                                  tooltip: '删除 ${service.displayName}',
                                  onPressed: () => _edit(() {
                                    settings.services.remove(service);
                                    _credentials[service.id] = null;
                                    if (settings.defaultServiceId ==
                                        service.id) {
                                      settings.defaultServiceId =
                                          ServiceConfig.builtinId;
                                    }
                                  }),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ),
                            ],
                          ),
                        ),
                      NativeGlassSwitchTile(
                        title: '仅使用快捷键',
                        value: !settings.automatic,
                        onChanged: (v) => _edit(() => settings.automatic = !v),
                      ),
                    ],
                  ),
                  NativeGlassGroup(
                    children: [
                      ..._shortcutBlock(
                        title: '全局翻译快捷键',
                        code: settings.shortcutModifiers,
                        label: settings.shortcutLabel,
                        screenshot: false,
                      ),
                    ],
                  ),
                ] else ...[
                  NativeGlassGroup(
                    children: [
                      const Text(
                        '截图目录',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        key: const ValueKey('截图目录'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          settings.screenshotSaveDirectory.isEmpty
                              ? '系统图片目录/截图'
                              : settings.screenshotSaveDirectory,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: const Text('默认截图存放路径'),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            NativeGlassSurface(
                              material: true,
                              child: TextButton(
                                onPressed: _recording
                                    ? null
                                    : _chooseScreenshotDirectory,
                                child: const Text('选择…'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  NativeGlassGroup(
                    children: [
                      const Text(
                        'GIF 导出',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      NativeGlassDropdown<int>(
                        label: '帧率',
                        value: settings.gifFramesPerSecond,
                        items: {
                          for (var fps = 1; fps <= 30; fps++) fps: '$fps fps',
                        },
                        onChanged: (fps) =>
                            _edit(() => settings.gifFramesPerSecond = fps),
                      ),
                      const SizedBox(height: 8),
                      NativeGlassField(
                        label: '最大宽度（像素）',
                        child: TextField(
                          key: const Key('gif-maximum-width'),
                          controller: _gifMaximumWidth,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(hintText: '不限制'),
                          // 留空保留原宽；非法非空值进入统一设置校验，不能当作无限制保存。
                          onChanged: (text) => _edit(
                            () => settings.gifMaximumWidth = text.trim().isEmpty
                                ? null
                                : int.tryParse(text) ?? 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                  NativeGlassGroup(
                    children: [
                      ..._shortcutBlock(
                        title: '区域截图快捷键',
                        code: settings.screenshotShortcutModifiers,
                        label: settings.screenshotShortcutLabel,
                        screenshot: true,
                      ),
                    ],
                  ),
                  NativeGlassGroup(
                    children: [
                      ExpansionTile(
                        key: const ValueKey('screenshot-toolbar-section'),
                        initiallyExpanded: false,
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(top: 8),
                        minTileHeight: 40,
                        shape: const Border(),
                        collapsedShape: const Border(),
                        title: const Text(
                          '截图工具栏',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        children: [
                          ScreenshotToolbarEditor(
                            value: settings.screenshotToolbar,
                            onChanged: (value) => _edit(
                              () => _settings!.screenshotToolbar = value,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 16),
                if (_failed && _dirty && !_conflicted)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: NativeGlassSurface(
                      material: true,
                      child: TextButton(
                        onPressed: _save,
                        child: const Text('重试自动保存'),
                      ),
                    ),
                  ),
                if (_conflicted)
                  NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      onPressed: () {
                        _dirty = false;
                        _load();
                      },
                      child: const Text('重新加载设置'),
                    ),
                  ),
                if (_message != null && !_saving)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _message!,
                      style: TextStyle(
                        color: _failed
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
