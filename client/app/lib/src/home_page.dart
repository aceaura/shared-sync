/// 状态页:当前阶段、上次同步结果、立即同步、自动同步开关、最近事件。
library;

import 'package:flutter/material.dart';
import 'package:sync_engine/sync_engine.dart';

import 'app_state.dart';

/// 状态页。由上层 [ListenableBuilder] 监听 [AppState] 驱动重建。
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state, required this.onGoToSettings});

  final AppState state;

  /// 未配置时「前往设置」的跳转回调(由主框架切换 NavigationRail 索引)。
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) {
    if (!state.isConfigured) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            const Text('尚未完成配置'),
            if (state.startupError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  state.startupError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onGoToSettings, child: const Text('前往设置')),
          ],
        ),
      );
    }

    final theme = Theme.of(context);
    final report = state.lastReport;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _PhaseChip(phase: state.phase),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: state.isSyncing ? null : () => _syncNow(context),
                icon: state.isSyncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('立即同步'),
              ),
              const SizedBox(width: 24),
              const Text('自动同步'),
              const SizedBox(width: 4),
              Switch(
                value: state.autoSync,
                onChanged: (v) => _toggleAuto(context, v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(
                report == null
                    ? Icons.schedule
                    : report.hasError
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                color: (report?.hasError ?? false)
                    ? theme.colorScheme.error
                    : null,
              ),
              title: Text(
                state.lastSyncAt == null
                    ? '尚未同步'
                    : '上次同步:${formatDateTime(state.lastSyncAt!)}',
              ),
              subtitle: Text(report?.summary() ?? '点击「立即同步」开始第一次同步'),
            ),
          ),
          const SizedBox(height: 16),
          Text('最近事件', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Expanded(child: _EventList(events: state.events)),
        ],
      ),
    );
  }

  Future<void> _syncNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.syncNow();
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _toggleAuto(BuildContext context, bool enabled) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.setAutoSync(enabled);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.phase});

  final SyncPhase phase;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isError = phase == SyncPhase.error;
    final isBusy = phase != SyncPhase.idle && !isError;
    final color = isError
        ? scheme.error
        : isBusy
            ? scheme.primary
            : scheme.outline;
    return Chip(
      avatar: Icon(
        isError
            ? Icons.error
            : isBusy
                ? Icons.autorenew
                : Icons.pause_circle_outline,
        size: 18,
        color: color,
      ),
      label: Text(phaseLabel(phase), style: TextStyle(color: color)),
      side: BorderSide(color: color),
    );
  }
}

class _EventList extends StatelessWidget {
  const _EventList({required this.events});

  final List<SyncEvent> events;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (events.isEmpty) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('暂无事件', style: TextStyle(color: scheme.outline)),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: events.length,
        itemBuilder: (context, index) {
          final e = events[index];
          final color = switch (e.level) {
            LogLevel.error => scheme.error,
            LogLevel.warn => scheme.tertiary,
            LogLevel.debug => scheme.outline,
            LogLevel.info => scheme.onSurface,
          };
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Text(
              '${formatTime(e.time)}  ${e.message}',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: color,
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['Consolas', 'monospace'],
              ),
            ),
          );
        },
      ),
    );
  }
}
