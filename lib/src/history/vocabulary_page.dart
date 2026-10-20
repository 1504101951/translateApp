import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import 'vocabulary.dart';

/// 历史窗口的生词本分段；只展示主引擎生词本，删除与导出都经通道交给主引擎和系统保存面板（#102）。
class VocabularyPage extends StatefulWidget {
  /// channel 为历史窗口通道，version 递增时重新读取（主引擎通知变更后由窗口传入）。
  const VocabularyPage({
    super.key,
    required this.channel,
    required this.version,
  });
  final MethodChannel channel;
  final int version;

  /// 无参数；返回维护生词列表与导出状态的界面状态。
  @override
  State<VocabularyPage> createState() => _VocabularyPageState();
}

/// 持有最近一次读取的生词与操作反馈；数据以主引擎为准，不在窗口内另存。
class _VocabularyPageState extends State<VocabularyPage> {
  List<VocabularyEntry>? _entries;
  String? _message;
  bool _exporting = false;

  /// 无参数；首次读取生词本，无返回值。
  @override
  void initState() {
    super.initState();
    _load();
  }

  /// old 为上一版组件；主引擎通知变更（version 变化）时重新读取，无返回值。
  @override
  void didUpdateWidget(VocabularyPage old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _load();
  }

  /// 无参数；读取全部生词，失败时显示原因，返回读取结束的 Future。
  Future<void> _load() async {
    try {
      final rows = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
        MethodNames.vocabularyList,
      );
      if (!mounted) return;
      setState(() => _entries = rows!.map(VocabularyEntry.fromMap).toList());
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? '无法读取生词本');
    }
  }

  /// word 为待删除单词；删除后重新读取，返回结束的 Future。
  Future<void> _delete(String word) async {
    await widget.channel.invokeMethod<void>(MethodNames.deleteVocabulary, {
      'word': word,
    });
    await _load();
  }

  /// 无参数；取得 CSV 后经系统保存面板保存，取消不提示，返回结束的 Future。
  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _message = null;
    });
    try {
      final csv = await widget.channel.invokeMethod<String>(
        MethodNames.vocabularyCsv,
      );
      final now = DateTime.now();
      final date =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final path = await widget.channel.invokeMethod<String>(
        MethodNames.saveTextFile,
        {'text': csv!, 'suggestedName': 'TranslateApp 生词本 $date.csv'},
      );
      if (!mounted || path == null) return;
      setState(() => _message = '已导出到 $path');
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message ?? '导出失败，请重试。');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// context 提供主题；返回生词卡片列表与底部导出栏。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    return Column(
      children: [
        Expanded(
          child: entries == null
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? const Center(child: Text('生词本为空'))
              : ListView.builder(
                  padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final date = DateTime.fromMillisecondsSinceEpoch(
                      entry.addedAt,
                    );
                    return Card(
                      key: ValueKey('vocabulary-${entry.word}'),
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
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.word,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                Text(
                                  '${date.year}-'
                                  '${date.month.toString().padLeft(2, '0')}-'
                                  '${date.day.toString().padLeft(2, '0')}',
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(width: 8),
                                NativeGlassSurface(
                                  material: true,
                                  child: IconButton(
                                    tooltip: '删除生词',
                                    onPressed: () => _delete(entry.word),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 16,
                                    ),
                                    visualDensity: VisualDensity.standard,
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 28),
                            Text('译文', style: theme.textTheme.labelLarge),
                            const SizedBox(height: 8),
                            SelectableText(
                              entry.translation,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const Divider(height: 21, thickness: 1),
                            Text('释义', style: theme.textTheme.labelLarge),
                            const SizedBox(height: 8),
                            SelectableText(
                              entry.definition,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(GlassMetrics.pagePadding),
          child: Row(
            children: [
              Expanded(child: Text(_message ?? '')),
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  onPressed: _exporting || (entries?.isEmpty ?? true)
                      ? null
                      : _export,
                  child: const Text('导出 CSV'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
