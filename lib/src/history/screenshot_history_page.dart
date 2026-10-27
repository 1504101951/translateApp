import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_compose_dialogs.dart';
import 'screenshot_history.dart';

/// 截图历史操作失败且主引擎没有给出原因时的提示（#131）。
const _operationFailed = '操作失败，请重试。';

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

/// 持有最近一次读取的截图记录、开关、勾选与操作反馈；不在窗口内另存数据。
class _ScreenshotHistoryPageState extends State<ScreenshotHistoryPage> {
  List<ScreenshotRecord>? _records;
  bool? _recording;
  String? _message;

  /// 勾选的记录 id，用于拼接、拆分与比较（#109）；只在本页保存。
  Set<int> _selected = {};

  /// 无参数；返回勾选的记录，按截图时间先后（同一时刻按 id）排列。
  List<ScreenshotRecord> get _chosen =>
      [
        for (final record in _records ?? const <ScreenshotRecord>[])
          if (_selected.contains(record.id)) record,
      ]..sort(
        (a, b) => a.capturedAt != b.capturedAt
            ? a.capturedAt.compareTo(b.capturedAt)
            : a.id.compareTo(b.id),
      );

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
      final records = rows!.map(ScreenshotRecord.fromMap).toList();
      setState(() {
        _records = records;
        _recording = recording!;
        // 只保留仍存在且图片未缺失的勾选。
        _selected = {
          for (final record in records)
            if (record.exists && _selected.contains(record.id)) record.id,
        };
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
      setState(() => _message = error.message ?? _operationFailed);
    }
  }

  /// produce 调用原生生成结果图片，done 为完成提示；把结果加入截图历史、清空勾选并重新读取，失败显示原因（#109）。
  Future<void> _compose(
    Future<List<Uint8List>> Function() produce,
    String Function(int count) done,
  ) async {
    try {
      final images = await produce();
      await widget.channel.invokeMethod<void>(
        MethodNames.addScreenshotHistory,
        {'images': images},
      );
      if (!mounted) return;
      setState(() {
        _selected = {};
        _message = done(images.length);
      });
      await _load();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? _operationFailed);
    }
  }

  /// 无参数；选择方向后按时间先后拼接勾选的截图，返回结束的 Future。
  Future<void> _stitch() async {
    final chosen = _chosen;
    // StitchDialog 返回纵向（true）或横向（false），取消为 null。
    final vertical = await showDialog<bool>(
      context: context,
      builder: (_) => StitchDialog(count: chosen.length),
    );
    if (vertical == null) return;
    await _compose(
      () async => [
        (await widget.channel.invokeMethod<Uint8List>(
          MethodNames.stitchScreenshots,
          {
            'paths': [for (final record in chosen) record.path],
            'vertical': vertical,
          },
        ))!,
      ],
      (_) => '已生成拼接图',
    );
  }

  /// 无参数；选择段数后按高度等分勾选的截图，返回结束的 Future。
  Future<void> _split() async {
    final record = _chosen.single;
    // SplitDialog 返回 2–10 的段数，取消为 null。
    final parts = await showDialog<int>(
      context: context,
      builder: (_) => SplitDialog(height: record.height),
    );
    if (parts == null) return;
    await _compose(
      () async => (await widget.channel.invokeListMethod<Uint8List>(
        MethodNames.splitScreenshot,
        {'path': record.path, 'parts': parts},
      ))!,
      (count) => '已拆分为 $count 张',
    );
  }

  /// 无参数；原生逐像素比较勾选的两张截图后打开并排比较弹窗，失败显示原因，返回结束的 Future。
  Future<void> _compare() async {
    final chosen = _chosen;
    try {
      final result = (await widget.channel.invokeMapMethod<String, Object?>(
        MethodNames.compareScreenshots,
        {'first': chosen[0].path, 'second': chosen[1].path},
      ))!;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => ScreenshotCompareDialog(
          first: chosen[0],
          second: chosen[1],
          mask: result['mask'] as Uint8List,
          different: result['different'] as int,
          total: result['total'] as int,
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? _operationFailed);
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
        // 勾选后的拼接（≥2 张）、拆分（1 张）与比较（2 张）（#109）。
        if (records != null && records.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GlassMetrics.pagePadding,
              8,
              GlassMetrics.pagePadding,
              0,
            ),
            child: Row(
              children: [
                Text(
                  '已选 ${_selected.length} 张',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                for (final (label, enabled, action) in [
                  ('拼接', _selected.length >= 2, _stitch),
                  ('拆分', _selected.length == 1, _split),
                  ('比较', _selected.length == 2, _compare),
                ]) ...[
                  const SizedBox(width: 8),
                  NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      onPressed: enabled ? action : null,
                      child: Text(label),
                    ),
                  ),
                ],
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
            // 图片缺失的记录不可勾选（#109）。
            Checkbox(
              value: _selected.contains(record.id),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              semanticLabel: '选择截图',
              onChanged: record.exists
                  ? (checked) => setState(
                      () => checked == true
                          ? _selected.add(record.id)
                          : _selected.remove(record.id),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
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
