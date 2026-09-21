import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/constants/channel_names.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/widgets/native_glass.dart';

import 'translation_history.dart';

/// 独立历史窗口；只展示主引擎持久化结果，不持有第二份数据库。
class HistoryApp extends StatefulWidget {
  /// channel 为历史查询和记录开关通道；创建独立窗口内容。
  const HistoryApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.settings),
  });

  /// SQLite 统一由主引擎管理，避免多个窗口重复写入。
  final MethodChannel channel;

  /// 无参数；返回维护分页和记录开关的窗口状态。
  @override
  State<HistoryApp> createState() => _HistoryAppState();
}

/// 维护当前浏览列表；游标分页使新增记录不影响已加载的卡片。
class _HistoryAppState extends State<HistoryApp> {
  /// 保持数据库倒序，长文不截断。
  final _items = <TranslationRecord>[];

  /// 读取成功前禁用开关，避免猜测偏好覆盖真实设置。
  bool? _recording;
  bool _savingRecording = false;
  bool _loading = false;
  bool _done = false;
  String? _pageError;
  String? _recordingError;

  /// 无参数；读取首批记录及开关，无返回值。
  @override
  void initState() {
    super.initState();
    // 首屏与开关独立读取，开关失败不阻止历史浏览。
    _loadMore();
    _loadRecording();
  }

  /// 无参数；读取持久化开关，返回读取结束的 Future。
  Future<void> _loadRecording() async {
    try {
      final value = await widget.channel.invokeMethod<bool>(
        MethodNames.historyRecording,
      );
      if (!mounted) return;
      setState(() {
        _recording = value!;
        _recordingError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _recordingError = error.message ?? '无法读取记录设置');
    }
  }

  /// enabled 为用户选择；持久化成功后才更新显示，返回保存结束的 Future。
  Future<void> _setRecording(bool enabled) async {
    setState(() => _savingRecording = true);
    try {
      await widget.channel.invokeMethod<void>(MethodNames.setHistoryRecording, {
        'enabled': enabled,
      });
      if (!mounted) return;
      setState(() {
        _recording = enabled;
        _recordingError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _recordingError = error.message ?? '无法保存记录设置');
    } finally {
      if (mounted) setState(() => _savingRecording = false);
    }
  }

  /// 无参数；按末条游标追加最多 10 条，失败保留原游标，返回加载结束的 Future。
  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() {
      _loading = true;
      _pageError = null;
    });
    try {
      final last = _items.lastOrNull;
      final page = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
        MethodNames.historyPage,
        {
          'limit': 10,
          if (last != null)
            'before': {'completedAt': last.completedAt, 'id': last.id},
        },
      );
      if (!mounted) return;
      // 完整解析后再追加，避免失败的一页留下部分记录。
      final records = page!.map(TranslationRecord.fromMap).toList();
      setState(() {
        _items.addAll(records);
        _done = records.length < 10;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _pageError = error.message ?? '无法读取翻译历史');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 无参数；回到最新记录并重新加载首批，返回刷新完成的 Future。
  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _items.clear();
      _done = false;
    });
    // 浏览期间的新增翻译由显式刷新展示，避免打断用户当前的阅读位置。
    await _loadMore();
  }

  /// 无参数；返回列表末尾的加载、重试、空列表或完成提示组件。
  Widget _buildFooter() {
    if (_loading) return const CircularProgressIndicator();
    if (_pageError != null) {
      return Column(
        children: [
          Text(_pageError!),
          NativeGlassSurface(
            material: true,
            child: TextButton(onPressed: _loadMore, child: const Text('重试加载')),
          ),
        ],
      );
    }
    if (_items.isEmpty) return const Text('暂无翻译历史');
    if (_done) return const Text('已显示全部历史');
    // 窗口足够高而未产生滚动时，仍提供可访问的下一批入口。
    return NativeGlassSurface(
      material: true,
      child: TextButton(onPressed: _loadMore, child: const Text('加载更多')),
    );
  }

  /// context 为窗口上下文；返回来源/日期标题与译文优先的历史卡片。
  @override
  Widget build(BuildContext context) {
    return NativeGlassApp(
      home: NativeGlassWindowPage(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('翻译历史'),
            actions: [
              NativeGlassSurface(
                material: true,
                child: IconButton(
                  tooltip: '刷新历史',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const Text('记录历史'),
              NativeGlassSwitch(
                label: '记录翻译历史',
                value: _recording ?? false,
                onChanged: _recording == null || _savingRecording
                    ? null
                    : _setRecording,
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: Column(
            children: [
              if (_recordingError != null)
                ListTile(
                  title: Text(_recordingError!),
                  trailing: NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      onPressed: _loadRecording,
                      child: const Text('重新读取设置'),
                    ),
                  ),
                ),
              if (_recording == false)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('已暂停记录；已有历史仍保留。'),
                ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    // 只响应外层列表；错误后由用户显式重试，避免无限失败重试。
                    if (notification.depth == 0 &&
                        notification.metrics.extentAfter < 160 &&
                        _pageError == null) {
                      _loadMore();
                    }
                    return false;
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                    itemCount: _items.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        // 列表末项承载分页反馈，不遮挡已有结果。
                        return Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(child: _buildFooter()),
                        );
                      }
                      final item = _items[index];
                      final date = DateTime.fromMillisecondsSinceEpoch(
                        item.completedAt,
                      );
                      final timestamp =
                          '${date.year}-'
                          '${date.month.toString().padLeft(2, '0')}-'
                          '${date.day.toString().padLeft(2, '0')} '
                          '${date.hour.toString().padLeft(2, '0')}:'
                          '${date.minute.toString().padLeft(2, '0')}';
                      return Card(
                        key: ValueKey('history-${item.id}'),
                        margin: const EdgeInsets.only(
                          bottom: GlassMetrics.groupGap,
                        ),
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(
                            GlassMetrics.panelPadding,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  Text(
                                    item.sourceLabel ?? '未记录来源',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  Text(
                                    timestamp,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                              const Divider(height: 28),
                              Text(
                                '译文',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: 8),
                              SelectableText(item.translatedText),
                              // 译文与原文独立阅读，分隔线不进入可复制正文。
                              const Divider(height: 21, thickness: 1),
                              Text(
                                '原文',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: 8),
                              SelectableText(item.sourceText),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
