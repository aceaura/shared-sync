/// 左侧侧栏:共享根入口 + 懒加载文件夹树(Finder sidebar / Explorer 文件夹树)。
///
/// 设计:
/// - 顶部「共享目录」根入口(图标 + 名称),点击回到根。
/// - 下方一棵从共享根递归展开的文件夹树;**懒加载**:展开某节点时才去列它的
///   子目录,避免大目录一次性扫描卡顿。
/// - 点击某文件夹节点 → 通过 [onNavigate] 让主区导航到该目录;并以
///   [currentRelative] 与主区当前目录联动高亮。
/// - 每个文件夹节点同时是 [DragTarget]<[FileEntry]>:把主区的项拖到节点上即
///   移动进该目录(通过 [onMoveInto] 调用保留的 moveEntry)。
/// - 隐藏顶层 `.sync`。
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'file_browser_common.dart';

/// 文件夹树侧栏。
class FileTreeSidebar extends StatefulWidget {
  const FileTreeSidebar({
    super.key,
    required this.sharedDir,
    required this.currentRelative,
    required this.onNavigate,
    required this.onMoveInto,
    required this.refreshTick,
  });

  /// 共享根绝对路径。
  final String sharedDir;

  /// 主区当前目录相对共享根的正斜杠路径(根为空串),用于联动高亮。
  final String currentRelative;

  /// 点击某节点导航到目标目录(传入相对共享根的路径段列表)。
  final void Function(List<String> segments) onNavigate;

  /// 把主区拖来的 [entry] 移动进 [destDirAbs] 目录。
  final Future<void> Function(FileEntry entry, String destDirAbs) onMoveInto;

  /// 外部数据变化的「脉冲」:每次主区刷新后自增,促使已展开节点重列子目录。
  final int refreshTick;

  @override
  State<FileTreeSidebar> createState() => _FileTreeSidebarState();
}

class _FileTreeSidebarState extends State<FileTreeSidebar> {
  /// 已展开的目录(相对共享根的正斜杠路径;根为空串始终视作展开)。
  final Set<String> _expanded = {''};

  /// 已加载的子目录名缓存:relPath → 子目录名列表(null 表示尚未加载)。
  final Map<String, List<String>?> _childrenCache = {};

  @override
  void initState() {
    super.initState();
    _load('');
    _expandAncestorsOf(widget.currentRelative);
  }

  @override
  void didUpdateWidget(covariant FileTreeSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 主区刷新后清缓存并重列已展开节点,保持树与磁盘一致。
    if (oldWidget.refreshTick != widget.refreshTick ||
        oldWidget.sharedDir != widget.sharedDir) {
      _childrenCache.clear();
      for (final rel in _expanded) {
        _load(rel);
      }
    }
    if (oldWidget.currentRelative != widget.currentRelative) {
      _expandAncestorsOf(widget.currentRelative);
    }
  }

  String _absOf(String rel) =>
      rel.isEmpty ? widget.sharedDir : p.joinAll([widget.sharedDir, ...rel.split('/')]);

  /// 确保当前目录的所有祖先节点都展开(便于高亮可见)。
  void _expandAncestorsOf(String rel) {
    if (rel.isEmpty) return;
    final parts = rel.split('/');
    var acc = '';
    for (final part in parts) {
      acc = acc.isEmpty ? part : '$acc/$part';
      // 展开到父级即可(目标自身不必展开)。
      final parent = acc == rel ? null : acc;
      if (parent != null && _expanded.add(parent)) {
        _load(parent);
      }
    }
    // 父链都要确保加载。
    acc = '';
    for (var i = 0; i < parts.length - 1; i++) {
      acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
      _expanded.add(acc);
      _load(acc);
    }
    if (mounted) setState(() {});
  }

  Future<void> _load(String rel) async {
    final names = await listSubDirNames(_absOf(rel), hideSyncDir: rel.isEmpty);
    if (!mounted) return;
    setState(() => _childrenCache[rel] = names);
  }

  void _toggle(String rel) {
    setState(() {
      if (_expanded.contains(rel)) {
        _expanded.remove(rel);
      } else {
        _expanded.add(rel);
        if (_childrenCache[rel] == null) _load(rel);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: kSidebarWidth,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // 顶部「共享目录」根入口。
          _RootEntry(
            selected: widget.currentRelative.isEmpty,
            onTap: () => widget.onNavigate(const []),
            onMoveInto: (entry) =>
                widget.onMoveInto(entry, widget.sharedDir),
          ),
          ..._buildNodes('', 0),
        ],
      ),
    );
  }

  /// 递归构建某层的节点列表;[depth] 用于缩进。
  List<Widget> _buildNodes(String parentRel, int depth) {
    final children = _childrenCache[parentRel];
    if (children == null || children.isEmpty) return const [];
    final widgets = <Widget>[];
    for (final name in children) {
      final rel = parentRel.isEmpty ? name : '$parentRel/$name';
      final isExpanded = _expanded.contains(rel);
      widgets.add(_TreeNode(
        name: name,
        depth: depth,
        expanded: isExpanded,
        selected: widget.currentRelative == rel,
        onTap: () => widget.onNavigate(rel.split('/')),
        onToggle: () => _toggle(rel),
        onMoveInto: (entry) => widget.onMoveInto(entry, _absOf(rel)),
      ));
      if (isExpanded) {
        widgets.addAll(_buildNodes(rel, depth + 1));
      }
    }
    return widgets;
  }
}

/// 顶部「共享目录」根入口。
class _RootEntry extends StatelessWidget {
  const _RootEntry({
    required this.selected,
    required this.onTap,
    required this.onMoveInto,
  });

  final bool selected;
  final VoidCallback onTap;
  final void Function(FileEntry entry) onMoveInto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<FileEntry>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onMoveInto(d.data),
      builder: (context, candidate, rejected) {
        final hot = candidate.isNotEmpty;
        return Material(
          color: selected
              ? scheme.secondaryContainer
              : hot
                  ? scheme.primaryContainer
                  : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.folder_shared_outlined,
                      size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '共享目录',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 树节点:展开箭头 + 文件夹图标 + 名称;可点导航、可作为放置目标。
class _TreeNode extends StatelessWidget {
  const _TreeNode({
    required this.name,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.onTap,
    required this.onToggle,
    required this.onMoveInto,
  });

  final String name;
  final int depth;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final void Function(FileEntry entry) onMoveInto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<FileEntry>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onMoveInto(d.data),
      builder: (context, candidate, rejected) {
        final hot = candidate.isNotEmpty;
        return Material(
          color: selected
              ? scheme.secondaryContainer
              : hot
                  ? scheme.primaryContainer
                  : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.only(
                left: 8.0 + depth * 16,
                right: 8,
                top: 6,
                bottom: 6,
              ),
              child: Row(
                children: [
                  InkWell(
                    onTap: onToggle,
                    borderRadius: BorderRadius.circular(12),
                    child: Icon(
                      expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.chevron_right,
                      size: 18,
                      color: scheme.outline,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.folder, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
