import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'permission_wizard.dart';

/// 首次启动逐步授权窗口；每步调用本进程系统 API，不写 TCC.db。
class PermissionWizardApp extends StatefulWidget {
  const PermissionWizardApp({
    super.key,
    this.channel = const MethodChannel('translateapp/settings'),
  });

  final MethodChannel channel;

  @override
  State<PermissionWizardApp> createState() => _PermissionWizardAppState();
}

class _PermissionWizardAppState extends State<PermissionWizardApp>
    with WidgetsBindingObserver {
  bool _accessibility = false;
  bool _screenAccess = false;
  bool _busy = false;
  // 稍后只跳过当前步的本地标记；刷新不能把它打回辅助功能。
  bool _skippedAccessibility = false;
  String? _message;

  PermissionWizardStep get _step => permissionWizardStep(
        accessibilityGranted: _accessibility || _skippedAccessibility,
        screenRecordingGranted: _screenAccess,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == 'permissionStatusChanged') {
        await _refresh();
      }
    });
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  /// 无参数；读取当前授权与向导标记。
  Future<void> _refresh() async {
    final status = await widget.channel.invokeMapMethod<Object?, Object?>(
      'permissionWizardStatus',
    );
    if (!mounted || status == null) return;
    setState(() {
      _accessibility = status['accessibility'] == true;
      _screenAccess = status['screenAccess'] == true;
    });
    if (_step == PermissionWizardStep.done) {
      await widget.channel.invokeMethod<void>('finishPermissionWizard');
      await widget.channel.invokeMethod<void>('closePermissionWizard');
    }
  }

  /// 无参数；已授权则只刷新，否则申请当前步权限。
  Future<void> _requestCurrent() async {
    setState(() => _busy = true);
    try {
      if (_step == PermissionWizardStep.accessibility) {
        if (_accessibility) {
          await _refresh();
          return;
        }
        await widget.channel.invokeMethod<void>('openAccessibility');
      } else if (_step == PermissionWizardStep.screenRecording) {
        if (_screenAccess) {
          await _refresh();
          return;
        }
        await widget.channel.invokeMethod<void>('requestScreenAccess');
      }
      await _refresh();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 无参数；辅助功能稍后只进入录屏步；录屏稍后才结束向导。
  Future<void> _skip() async {
    if (_step == PermissionWizardStep.accessibility) {
      setState(() => _skippedAccessibility = true);
      return;
    }
    await widget.channel.invokeMethod<void>('finishPermissionWizard');
    await widget.channel.invokeMethod<void>('closePermissionWizard');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_step) {
      PermissionWizardStep.accessibility => '允许读取选中文字',
      PermissionWizardStep.screenRecording => '允许截取屏幕',
      PermissionWizardStep.done => '已完成',
    };
    final body = switch (_step) {
      PermissionWizardStep.accessibility =>
        '翻译需要辅助功能权限。授权后回到此窗口，会自动进入下一步。',
      PermissionWizardStep.screenRecording =>
        '截图需要屏幕录制权限。授权后 TranslateApp 会出现在系统列表中；已授权则不再重复申请。',
      PermissionWizardStep.done => '可以开始使用 TranslateApp。',
    };
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Text(body),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(_message!, style: const TextStyle(color: Colors.red)),
              ],
              const Spacer(),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy ? null : _skip,
                    child: const Text('稍后'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _busy ? null : _requestCurrent,
                    child: Text(_step == PermissionWizardStep.screenRecording
                        ? '申请录屏权限'
                        : '授权'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
