import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// capturedAt 为本地截图时间；返回带毫秒时间的 PNG 名称，重名序号由原生文件写入负责。
String screenshotFilename(DateTime capturedAt) {
  String pad(int value, [int width = 2]) =>
      value.toString().padLeft(width, '0');
  return '截图_${capturedAt.year}-${pad(capturedAt.month)}-${pad(capturedAt.day)}_'
      '${pad(capturedAt.hour)}-${pad(capturedAt.minute)}-${pad(capturedAt.second)}-'
      '${pad(capturedAt.millisecond, 3)}.png';
}

/// 独立截图预览入口；channel 连接原生内存截图、剪贴板和系统保存面板。
class ScreenshotApp extends StatefulWidget {
  const ScreenshotApp({
    super.key,
    this.channel = const MethodChannel('translateapp/screenshot'),
  });

  final MethodChannel channel;

  /// 无参数；创建单个预览窗口的操作状态。
  @override
  State<ScreenshotApp> createState() => _ScreenshotAppState();
}

class _ScreenshotAppState extends State<ScreenshotApp> {
  Map<Object?, Object?> _capture = {};
  bool _busy = false;
  bool _failed = false;
  String? _message;
  String? _savedPath;

  /// 无参数；先监听再拉取快照，首张截图无需等待引擎启动通知，无返回值。
  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == 'screenshotChanged') {
        _replace(Map<Object?, Object?>.from(call.arguments as Map));
      }
    });
    _load();
  }

  /// value 为原生截图快照；替换图片并清除上一张的操作结果，无返回值。
  void _replace(Map<Object?, Object?> value) {
    if (!mounted) return;
    setState(() {
      _capture = value;
      _message = value['error'] as String?;
      _failed = _message != null;
      _savedPath = null;
      _busy = false;
    });
  }

  /// 无参数；拉取内存截图与目录，失败保留可见错误，无返回值。
  Future<void> _load() async {
    try {
      final snapshot =
          await widget.channel.invokeMapMethod('getScreenshot') ?? {};
      if (_capture.isEmpty) _replace(snapshot);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  /// action 为复制/保存/组合/另存为；取消保存不复制，部分成功给出准确结果，无返回值。
  Future<void> _export(String action) async {
    final id = _capture['id'];
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    String? saved;
    try {
      if (action != 'copy') {
        saved = await widget.channel.invokeMethod<String>('saveScreenshot', {
          'id': id,
          'name': screenshotFilename(
            DateTime.fromMillisecondsSinceEpoch(_capture['capturedAt'] as int),
          ),
          'saveAs': action == 'saveAs',
        });
        if (saved == null) return;
      }
      if (!mounted || _capture['id'] != id) return;
      if (action == 'copy' || action == 'both') {
        await widget.channel.invokeMethod<void>('copyScreenshot', {'id': id});
      }
      if (!mounted || _capture['id'] != id) return;
      setState(() {
        _savedPath = saved ?? _savedPath;
        _message = action == 'both'
            ? '已复制并保存'
            : action == 'copy'
            ? '已复制图片'
            : '已保存截图';
      });
    } on PlatformException catch (error) {
      if (!mounted || _capture['id'] != id) return;
      setState(() {
        _savedPath = saved ?? _savedPath;
        _message = saved == null ? error.message : '已保存，但复制失败：${error.message}';
        _failed = true;
      });
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  /// method 为非导出系统操作；目录选择立即生效，不与翻译设置的保存耦合，无返回值。
  Future<void> _command(String method) async {
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      final value = await widget.channel.invokeMethod<Object?>(method);
      if (!mounted) return;
      setState(() {
        if (method == 'chooseDirectory' && value is String) {
          _capture['directory'] = value;
        }
        if (method == 'clearDirectory') _capture['directory'] = '';
        if (method == 'requestScreenAccess' && value is Map) {
          _capture['screenAccess'] = value['screenAccess'];
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
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 无参数；解除原生回调，无返回值。
  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// context 为预览窗口上下文；返回截图及操作界面，不初始化翻译会话。
  @override
  Widget build(BuildContext context) {
    final bytes = _capture['bytes'] as Uint8List?;
    final directory = _capture['directory'] as String? ?? '';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF286A65),
        useMaterial3: true,
      ),
      home: Scaffold(
        backgroundColor: const Color(0xFFF4F6F8),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.crop_free, size: 28),
                  const SizedBox(width: 12),
                  const Text(
                    '截图',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _command('captureRegion'),
                    icon: const Icon(Icons.add),
                    label: const Text('重新截图'),
                  ),
                  IconButton(
                    tooltip: '关闭截图',
                    onPressed: _busy ? null : () => _command('closeScreenshot'),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (_capture['screenAccess'] == false)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _command('requestScreenAccess'),
                    child: const Text('授予屏幕录制权限'),
                  ),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: const Color(0xFFE6EBEF),
                    child: Center(
                      child: bytes == null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.screenshot_monitor,
                                  size: 56,
                                  color: Color(0xFF667781),
                                ),
                                const SizedBox(height: 16),
                                const Text('框选屏幕区域，预览后复制或保存'),
                              ],
                            )
                          : InteractiveViewer(
                              minScale: 0.2,
                              maxScale: 5,
                              child: Image.memory(
                                bytes,
                                key: ValueKey(_capture['id']),
                                fit: BoxFit.contain,
                                semanticLabel: '截图预览',
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    bytes == null
                        ? '图片仅保存在本机'
                        : '${(_capture['width'] as num).toInt()} × ${(_capture['height'] as num).toInt()} 像素 · PNG',
                  ),
                  const Spacer(),
                  if (_busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: bytes == null || _busy
                        ? null
                        : () => _export('copy'),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('复制图片'),
                  ),
                  OutlinedButton.icon(
                    onPressed: bytes == null || _busy
                        ? null
                        : () => _export('save'),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                  OutlinedButton(
                    onPressed: bytes == null || _busy
                        ? null
                        : () => _export('both'),
                    child: const Text('复制并保存'),
                  ),
                  TextButton(
                    onPressed: bytes == null || _busy
                        ? null
                        : () => _export('saveAs'),
                    child: const Text('另存为…'),
                  ),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      directory.isEmpty ? '保存时选择位置' : directory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _command('chooseDirectory'),
                    child: const Text('固定目录…'),
                  ),
                  if (directory.isNotEmpty)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _command('clearDirectory'),
                      child: const Text('每次询问'),
                    ),
                ],
              ),
              if (_message != null)
                SelectableText(
                  _message!,
                  style: TextStyle(
                    color: _failed
                        ? Colors.red.shade700
                        : const Color(0xFF286A65),
                  ),
                ),
              if (_savedPath != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => widget.channel.invokeMethod<void>(
                      'revealFile',
                      {'path': _savedPath},
                    ),
                    child: const Text('在 Finder 中显示'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
