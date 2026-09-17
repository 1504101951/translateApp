import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 独立翻译历史窗口；数据由主引擎 SQLite 分页提供。
class HistoryApp extends StatefulWidget {
  const HistoryApp({
    super.key,
    this.channel = const MethodChannel('translateapp/settings'),
  });

  final MethodChannel channel;

  @override
  State<HistoryApp> createState() => _HistoryAppState();
}

class _HistoryAppState extends State<HistoryApp> {
  final _items = <Map<Object?, Object?>>[];
  bool _recording = true;
  bool _loading = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _loadRecording();
  }

  Future<void> _loadRecording() async {
    final value = await widget.channel.invokeMethod<bool>('historyRecording');
    if (mounted && value != null) setState(() => _recording = value);
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    final page = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
          'historyPage',
          {'offset': _items.length, 'limit': 10},
        ) ??
        [];
    if (!mounted) return;
    setState(() {
      _items.addAll(page);
      _done = page.length < 10;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('翻译历史'),
          actions: [
            Row(
              children: [
                const Text('记录'),
                Switch(
                  value: _recording,
                  onChanged: (value) async {
                    await widget.channel.invokeMethod<void>(
                      'setHistoryRecording',
                      {'enabled': value},
                    );
                    setState(() => _recording = value);
                  },
                ),
              ],
            ),
          ],
        ),
        body: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < 80) {
              _loadMore();
            }
            return false;
          },
          child: ListView.separated(
            itemCount: _items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = _items[index];
              return ListTile(
                title: Text('${item['translatedText'] ?? ''}'),
                subtitle: Text('${item['sourceText'] ?? ''}'),
              );
            },
          ),
        ),
      ),
    );
  }
}
