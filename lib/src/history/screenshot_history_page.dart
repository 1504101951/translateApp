import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_history.dart';

/// 历史窗口的截图分段；数据以主引擎为准，文件操作交给原生（#29）。
class ScreenshotHistoryPage extends StatefulWidget {
  /// channel 为历史窗口通道，version 递增时重新读取（主引擎通知变更后由窗口传入）。
  const ScreenshotHistoryPage({
    super.key,
    required this.channel,
    required this.version,
  });
  final MethodChannel channel;
  final int version;

  /// 缩略图宽度与最高高度，单位为点，对应样式Spec #67。
  static const thumbnailWidth = 240.0;
  static const thumbnailMaxHeight = 180.0;

  /// 无参数；返回维护截图列表与开关的界面状态。
  @override
  State<ScreenshotHistoryPage> createState() => _ScreenshotHistoryPageState();
}

/// 持有最近一次读取的截图记录、开关与操作反馈；不在窗口内另存数据。
class _ScreenshotHistoryPageState extends State<ScreenshotHistoryPage> {
  List<ScreenshotRecord>? _records;
  bool? _recording;
  String? _message;

  /// 无参数；首次读取列表与开关，无返回值。
  @override
  void initState() {
    super.initState();
    _load();
  }

  /// old 为上一版组件；主引擎通知变更（version 变化）时重新读取，无返回值。
  @override
  void didUpdateWidget(ScreenshotHistoryPage old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _load();
  }

  /// 无参数；读取截图记录与「记录截图历史」开关，失败时显示原因，返回读取结束的 Future。
  Future<void> _load() async {
    try {
      final rows = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
        MethodNames.screenshotHistoryList,
      );
      final recording = await widget.channel.invokeMethod<bool>(
        MethodNames.screenshotHistoryRecording,
      );
      if (!mounted) return;
      setState(() {
        _records = rows!.map(ScreenshotRecord.fromMap).toList();
        _recording = recording!;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? '无法读取截图历史');
    }
  }

  /// method 为主引擎或原生操作，arguments 为参数；执行后按需重新读取，失败显示原因，返回结束的 Future。
  Future<void> _run(
    String method, [
    Map<String, Object>? arguments,
    bool reload = false,
  ]) async {
    try {
      await widget.channel.invokeMethod<Object?>(method, arguments);
      if (reload) await _load();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? '操作失败，请重试。');
    }
  }

  /// context 提供主题；返回开关栏与截图卡片列表。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = _records;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: GlassMetrics.pagePadding,
          ),
          child: Row(
            children: [
              const Text('记录截图历史'),
              const SizedBox(width: 8),
              NativeGlassSwitch(
                label: '记录截图历史',
                value: _recording ?? false,
                onChanged: _recording == null
                    ? null
                    : (enabled) async {
                        await _run(MethodNames.setScreenshotHistoryRecording, {
                          'enabled': enabled,
                        }, true);
                      },
              ),
              const Spacer(),
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  onPressed: records == null || records.isEmpty
                      ? null
                      : () => _run(
                          MethodNames.clearScreenshotHistory,
                          null,
                          true,
                        ),
                  child: const Text('清空截图历史'),
                ),
              ),
            ],
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.all(GlassMetrics.panelPadding),
            child: Text(_message!),
          ),
        Expanded(
          child: records == null
              ? const Center(child: CircularProgressIndicator())
              : records.isEmpty
              ? Center(
                  child: Text(
                    _recording == true
                        ? '暂无截图历史'
                        : '未开启记录截图历史；开启后复制、保存或贴图的截图会出现在这里。',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                  itemCount: records.length,
                  itemBuilder: (context, index) => _card(theme, records[index]),
                ),
        ),
      ],
    );
  }

  /// theme 为当前主题，record 为一条截图历史；返回缩略图、时间、尺寸与操作按钮组成的卡片。
  Widget _card(ThemeData theme, ScreenshotRecord record) {
    final date = DateTime.fromMillisecondsSinceEpoch(record.capturedAt);
    final timestamp =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    // 缩略图按原图比例缩放到 240pt 宽，过高时限制在 180pt。
    final height = record.width == 0
        ? ScreenshotHistoryPage.thumbnailMaxHeight
        : (ScreenshotHistoryPage.thumbnailWidth * record.height / record.width)
              .clamp(1.0, ScreenshotHistoryPage.thumbnailMaxHeight);
    final path = {'path': record.path};

    /// tooltip/icon/method 为按钮提示、图标与原生操作；返回 16pt 玻璃图标按钮。
    Widget action(String tooltip, IconData icon, VoidCallback onPressed) =>
        NativeGlassSurface(
          material: true,
          child: IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            icon: Icon(icon, size: 16),
            visualDensity: VisualDensity.standard,
          ),
        );
    return Card(
      key: ValueKey('screenshot-history-${record.id}'),
      margin: const EdgeInsets.only(bottom: GlassMetrics.groupGap),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(GlassMetrics.panelPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: ScreenshotHistoryPage.thumbnailWidth,
              height: height,
              child: record.exists
                  ? Image.file(
                      File(record.path),
                      fit: BoxFit.contain,
                      cacheWidth: (ScreenshotHistoryPage.thumbnailWidth * 2)
                          .round(),
                    )
                  : const Center(child: Text('图片文件已缺失')),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(timestamp, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Text(
                    '${record.width} × ${record.height}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      // 文件缺失时只保留删除。
                      if (record.exists) ...[
                        action(
                          '打开',
                          Icons.open_in_new,
                          () => _run(MethodNames.openFile, path),
                        ),
                        action(
                          '复制图片',
                          Icons.copy_outlined,
                          () => _run(MethodNames.copyImageFile, path),
                        ),
                        action(
                          '在 Finder 中显示',
                          Icons.folder_open,
                          () => _run(MethodNames.revealFile, path),
                        ),
                      ],
                      action(
                        '删除截图',
                        Icons.delete_outline,
                        () => _run(MethodNames.deleteScreenshotHistory, {
                          'id': record.id,
                        }, true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
