import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';
import '../translation/glossary.dart';
import 'app_settings.dart';

/// 术语表管理弹窗：列出全部术语，可添加、编辑、删除；每次改动经 onChanged 交给设置页自动保存（#104）。
class GlossaryManager extends StatefulWidget {
  /// glossary 为当前术语表，defaultLanguage 为新增术语的目标语言，onChanged 接收改动后的完整列表。
  const GlossaryManager({
    super.key,
    required this.glossary,
    required this.defaultLanguage,
    required this.onChanged,
  });

  final List<GlossaryEntry> glossary;
  final String defaultLanguage;
  final ValueChanged<List<GlossaryEntry>> onChanged;

  /// 无参数；返回持有弹窗内术语列表的状态。
  @override
  State<GlossaryManager> createState() => _GlossaryManagerState();
}

/// 持有弹窗内展示的术语列表；设置页保存的是每次改动后交回的完整副本。
class _GlossaryManagerState extends State<GlossaryManager> {
  late final List<GlossaryEntry> _entries = [...widget.glossary];

  /// change 修改弹窗内列表；刷新界面后把完整副本交给设置页，无返回值。
  void _change(VoidCallback change) {
    setState(change);
    widget.onChanged([..._entries]);
  }

  /// index 为待编辑术语的下标，新增时为空；确定后更新列表，取消不改变，返回编辑结束的 Future。
  Future<void> _edit([int? index]) async {
    final entry = await showDialog<GlossaryEntry>(
      context: context,
      barrierDismissible: false,
      // GlossaryEditor 只返回不与其余条目重复的术语草稿。
      builder: (_) => GlossaryEditor(
        entry: index == null ? null : _entries[index],
        others: [
          for (final (i, other) in _entries.indexed)
            if (i != index) other,
        ],
        defaultLanguage: widget.defaultLanguage,
      ),
    );
    if (entry == null || !mounted) return;
    _change(() {
      if (index == null) {
        _entries.add(entry);
      } else {
        _entries[index] = entry;
      }
    });
  }

  /// context 为弹窗上下文；返回生效范围说明、术语列表与添加/完成操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: const Text('术语表'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '只对模型服务（OpenAI、DeepSeek、Anthropic）的翻译生效；译法留空表示保留原文不译。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (_entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('暂无术语'),
            )
          else
            // 条目多时只在弹窗内滚动，标题与操作保持可见。
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (index, entry) in _entries.indexed)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        entry.translation.isEmpty
                            ? '${entry.term}（保留原文）'
                            : '${entry.term} → ${entry.translation}',
                      ),
                      subtitle: Text(
                        AppSettings.languages[entry.language] ?? entry.language,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NativeGlassSurface(
                            material: true,
                            child: IconButton(
                              tooltip: '编辑 ${entry.term}',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _edit(index),
                            ),
                          ),
                          const SizedBox(width: GlassMetrics.actionGap),
                          NativeGlassSurface(
                            material: true,
                            child: IconButton(
                              tooltip: '删除 ${entry.term}',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  _change(() => _entries.removeAt(index)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton.icon(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加术语'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ),
    ],
  );
}

/// 添加或编辑一条术语的弹窗；只持有草稿，确定后返回条目，由设置页自动保存（#104）。
class GlossaryEditor extends StatefulWidget {
  /// entry 为待编辑条目（新增时为空），others 为其余条目用于查重，defaultLanguage 为新增时的目标语言。
  const GlossaryEditor({
    super.key,
    this.entry,
    required this.others,
    required this.defaultLanguage,
  });

  final GlossaryEntry? entry;
  final List<GlossaryEntry> others;
  final String defaultLanguage;

  /// 无参数；返回维护术语草稿的弹窗状态。
  @override
  State<GlossaryEditor> createState() => _GlossaryEditorState();
}

/// 持有原文术语、译法与目标语言草稿及重复提示；取消时不返回任何条目。
class _GlossaryEditorState extends State<GlossaryEditor> {
  final _term = TextEditingController();
  final _translation = TextEditingController();
  late String _language;
  bool _duplicate = false;

  /// 无参数；编辑时载入原条目，新增时目标语言取主要语言，无返回值。
  @override
  void initState() {
    super.initState();
    _term.text = widget.entry?.term ?? '';
    _translation.text = widget.entry?.translation ?? '';
    _language = widget.entry?.language ?? widget.defaultLanguage;
  }

  /// 无参数；释放输入控制器，无返回值。
  @override
  void dispose() {
    _term.dispose();
    _translation.dispose();
    super.dispose();
  }

  /// 无参数；去掉首尾空白后查重，重复时留在弹窗内提示，否则关闭并返回条目，无返回值。
  void _submit() {
    final entry = GlossaryEntry(
      term: _term.text.trim(),
      translation: _translation.text.trim(),
      language: _language,
    );
    if (widget.others.any((other) => other.key == entry.key)) {
      setState(() => _duplicate = true);
      return;
    }
    Navigator.pop(context, entry);
  }

  /// context 为弹窗上下文；返回术语字段、目标语言下拉与取消/确定操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: Text(widget.entry == null ? '添加术语' : '编辑术语'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NativeGlassField(
            label: '原文术语',
            child: TextField(
              key: const ValueKey('原文术语'),
              controller: _term,
              // 修改术语后重新判断「确定」是否可用，并清除旧的重复提示。
              onChanged: (_) => setState(() => _duplicate = false),
              decoration: const InputDecoration(),
            ),
          ),
          NativeGlassField(
            label: '译法',
            helper: '留空表示保留原文不译',
            child: TextField(
              key: const ValueKey('译法'),
              controller: _translation,
              decoration: const InputDecoration(),
            ),
          ),
          NativeGlassDropdown<String>(
            label: '目标语言',
            value: _language,
            // 主要语言可能是列表外的系统语言，保留当前值作为选项。
            items: {
              ...AppSettings.languages,
              if (!AppSettings.languages.containsKey(_language))
                _language: _language,
            },
            onChanged: (value) => setState(() {
              _language = value;
              _duplicate = false;
            }),
          ),
          if (_duplicate)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('该目标语言下已有此术语。'),
            ),
        ],
      ),
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: _term.text.trim().isEmpty ? null : _submit,
          child: const Text('确定'),
        ),
      ),
    ],
  );
}
