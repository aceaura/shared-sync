/// 日志页:展示当天日志末尾 200 行,等宽字体,可手动刷新。
library;

import 'package:flutter/material.dart';

import 'app_state.dart';

/// 日志查看页。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  /// 显示的行数上限(logger.tail 参数)。
  static const int tailLines = 200;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  late Future<List<String>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.state.tailLogs(LogsPage.tailLines);
  }

  void _refresh() {
    setState(() {
      _future = widget.state.tailLogs(LogsPage.tailLines);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('同步日志(最近 ${LogsPage.tailLines} 行)',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
                onPressed: _refresh,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: FutureBuilder<List<String>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        '读取日志失败:${snapshot.error}',
                        style: TextStyle(color: scheme.error),
                      ),
                    );
                  }
                  final lines = snapshot.data ?? const [];
                  if (lines.isEmpty) {
                    return Center(
                      child: Text(
                        widget.state.isConfigured
                            ? '今天还没有日志'
                            : '完成配置后这里会显示同步日志',
                        style: TextStyle(color: scheme.outline),
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      lines.join('\n'),
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        fontFamily: 'Menlo',
                        fontFamilyFallback: ['Consolas', 'monospace'],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
