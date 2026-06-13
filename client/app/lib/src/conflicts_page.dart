/// 冲突页:展示 conflicts.jsonl 中的最近冲突记录,可在文件管理器中定位。
library;

import 'package:flutter/material.dart';
import 'package:sync_engine/sync_engine.dart';

import 'app_state.dart';

/// 冲突记录列表页。
class ConflictsPage extends StatefulWidget {
  const ConflictsPage({super.key, required this.state});

  final AppState state;

  @override
  State<ConflictsPage> createState() => _ConflictsPageState();
}

class _ConflictsPageState extends State<ConflictsPage> {
  late Future<List<ConflictRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.state.recentConflicts();
  }

  void _refresh() {
    setState(() {
      _future = widget.state.recentConflicts();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('冲突记录', style: Theme.of(context).textTheme.titleMedium),
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
            child: FutureBuilder<List<ConflictRecord>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      '读取冲突记录失败:${snapshot.error}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  );
                }
                final records = snapshot.data ?? const [];
                if (records.isEmpty) {
                  return const Center(child: Text('暂无冲突记录'));
                }
                // 引擎返回文件末尾(时间正序),展示时新的在前。
                final reversed = records.reversed.toList();
                return ListView.separated(
                  itemCount: reversed.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _ConflictTile(
                    record: reversed[index],
                    onReveal: (path) => _reveal(context, path),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reveal(BuildContext context, String relativePath) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await widget.state.revealInFileManager(relativePath);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}

class _ConflictTile extends StatelessWidget {
  const _ConflictTile({required this.record, required this.onReveal});

  final ConflictRecord record;
  final void Function(String relativePath) onReveal;

  @override
  Widget build(BuildContext context) {
    final copyPath = record.copyPath;
    // 副本是用户内容的去处,优先定位副本;没有副本就定位原路径。
    final revealTarget = copyPath ?? record.path;
    return GestureDetector(
      onSecondaryTap: () => onReveal(revealTarget),
      child: ListTile(
        leading: _KindBadge(kind: record.kind),
        title: Text(record.path, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          copyPath == null
              ? formatDateTime(record.time)
              : '${formatDateTime(record.time)}\n副本:$copyPath',
        ),
        isThreeLine: copyPath != null,
        trailing: IconButton(
          tooltip: '在文件管理器中显示',
          icon: const Icon(Icons.folder_open),
          onPressed: () => onReveal(revealTarget),
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (kind) {
      'delete' => ('删除', Colors.red),
      'create' => ('新建', Colors.blue),
      'modify' => ('修改', Colors.orange),
      _ => (kind, Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.shade700,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
