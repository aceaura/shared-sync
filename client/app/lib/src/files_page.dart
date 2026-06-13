/// 文件页:像访达(macOS)/ 资源管理器(Windows)一样的文件管理器界面。
///
/// 四区布局:
///  1. 顶部工具栏:后退/前进/上级、路径面包屑(可点 + DragTarget)、视图切换、
///     搜索框、新建文件夹、刷新。
///  2. 左侧侧栏:共享根入口 + 懒加载文件夹树([FileTreeSidebar]),与主区联动高亮。
///  3. 主区:图标网格视图(默认)/ 详情列表视图(可点列头排序)。Finder 式选择:
///     单击选中、双击打开/进入;支持 Cmd/Ctrl 多选与 Shift 范围选;右键未选中项
///     时先选中再弹菜单;保留应用内拖动移动 + 从访达拖入导入。
///  4. 底部状态栏:项数 / 已选数 / 已选合计大小。
///
/// 设计约束:只读 [AppState.config] 取共享根;所有写操作直接落到共享目录里的
/// 真实文件,同步引擎会在下个周期自动捕获并传播(无需手动触发);一切异常在本层
/// 捕获并转成 SnackBar 文案,绝不让 UI 崩溃;写操作以 isWithin/equals 双校验限制
/// 在 sharedDir 内;隐藏 `.sync`。
///
/// 注意:顶层纯逻辑函数 [moveEntry] / [importPaths] 与 [MoveResult] /
/// [ImportResult] / [MoveOutcome] 有单元测试,签名保持不变,UI 复用它们。
library;

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_state.dart';
import 'file_browser_common.dart';
import 'file_tree_sidebar.dart';

/// 应用内移动一个条目到目标目录的结果(供 UI 选择文案/是否刷新)。
enum MoveOutcome {
  /// 移动成功。
  moved,

  /// 源与目标在同一目录,无需移动。
  sameDir,

  /// 试图把文件夹移进它自己或其子孙,已拒绝。
  intoSelf,

  /// 目标目录已存在同名项,已拒绝(更安全)。
  nameClash,

  /// 目标越出共享根,已拒绝。
  outsideRoot,

  /// 文件系统操作失败(message 带原因)。
  failed,
}

/// 一次移动的结果与可选错误信息。
class MoveResult {
  const MoveResult(this.outcome, [this.message]);
  final MoveOutcome outcome;
  final String? message;
}

/// 把 [sourceAbs](文件或文件夹)移动进 [destDirAbs] 目录。
///
/// 这是从 UI 抽出的纯逻辑(只依赖 dart:io / path),便于单测:
/// - 自我/子孙嵌套:拒绝(避免 rename 自我嵌套破坏)。
/// - 同目录:视为无操作。
/// - 目标越出 [sharedDir]:拒绝(写操作不得越界)。
/// - 目标已存在同名:拒绝(比覆盖更安全)。
/// 全程不抛异常,失败转成 [MoveOutcome.failed]。
Future<MoveResult> moveEntry({
  required String sharedDir,
  required String sourceAbs,
  required String destDirAbs,
}) async {
  final source = p.normalize(sourceAbs);
  final destDir = p.normalize(destDirAbs);
  final name = p.basename(source);
  final target = p.join(destDir, name);

  // 目标必须落在共享根内(destDir == sharedDir 时 isWithin 为 false,需额外放行)。
  final destOk = p.equals(destDir, sharedDir) || p.isWithin(sharedDir, destDir);
  if (!destOk) {
    return const MoveResult(MoveOutcome.outsideRoot, '目标超出共享目录范围');
  }

  // 同一目录:无操作。
  if (p.equals(p.dirname(source), destDir)) {
    return const MoveResult(MoveOutcome.sameDir);
  }

  final isDir =
      FileSystemEntity.typeSync(source) == FileSystemEntityType.directory;

  // 禁止把文件夹移动到它自己或其子孙之内(含直接等于自身)。
  if (isDir &&
      (p.equals(source, destDir) || p.isWithin(source, destDir))) {
    return const MoveResult(MoveOutcome.intoSelf, '不能把文件夹移动到它自己或其子目录中');
  }

  // 目标已存在同名:拒绝。
  if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
    return const MoveResult(MoveOutcome.nameClash, '目标位置已存在同名项');
  }

  try {
    if (isDir) {
      await Directory(source).rename(target);
    } else {
      await File(source).rename(target);
    }
    return const MoveResult(MoveOutcome.moved);
  } catch (e) {
    return MoveResult(MoveOutcome.failed, '$e');
  }
}

/// 一次外部导入(复制)的汇总结果。
class ImportResult {
  const ImportResult({
    required this.imported,
    required this.renamed,
    required this.skipped,
    required this.errors,
  });

  /// 成功导入的条目数。
  final int imported;

  /// 因冲突自动改名的条目数。
  final int renamed;

  /// 因越界等原因被跳过的条目数。
  final int skipped;

  /// 失败原因列表(逐条)。
  final List<String> errors;

  bool get hasError => errors.isNotEmpty;
}

/// 把外部的 [sourcePaths](文件或文件夹,通常来自 Finder 拖入)**复制**进
/// [destDirAbs]。这是从 UI 抽出的纯逻辑,便于单测:
/// - 名称冲突 → 自动改名(`name (2).ext`),不覆盖已有内容。
/// - 文件夹 → 递归复制。
/// - 目标越出 [sharedDir] → 跳过(不复制)。
/// - 复制(非移动)源:外部文件不属于共享目录。
/// 单条失败被收进 [ImportResult.errors],不影响其余条目。
Future<ImportResult> importPaths({
  required String sharedDir,
  required String destDirAbs,
  required List<String> sourcePaths,
}) async {
  final destDir = p.normalize(destDirAbs);
  final destOk = p.equals(destDir, sharedDir) || p.isWithin(sharedDir, destDir);
  if (!destOk) {
    return ImportResult(
      imported: 0,
      renamed: 0,
      skipped: sourcePaths.length,
      errors: const ['目标目录超出共享目录范围,已全部跳过'],
    );
  }

  var imported = 0;
  var renamed = 0;
  var skipped = 0;
  final errors = <String>[];

  for (final raw in sourcePaths) {
    final source = p.normalize(raw);
    final type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.notFound) {
      skipped++;
      errors.add('找不到源:${p.basename(source)}');
      continue;
    }
    // 不允许把共享目录内部的东西通过"导入"复制(那应走移动);也防自包含递归。
    if (p.equals(source, destDir) || p.isWithin(source, destDir)) {
      skipped++;
      continue;
    }

    final baseName = p.basename(source);
    final targetPath = _uniqueTarget(destDir, baseName);
    if (targetPath != p.join(destDir, baseName)) renamed++;

    // 目标必须仍在共享根内(改名后的路径同样校验)。
    if (!(p.equals(p.normalize(targetPath), sharedDir) ||
        p.isWithin(sharedDir, targetPath))) {
      skipped++;
      continue;
    }

    try {
      if (type == FileSystemEntityType.directory) {
        await _copyDirectory(Directory(source), Directory(targetPath));
      } else {
        await File(source).copy(targetPath);
      }
      imported++;
    } catch (e) {
      errors.add('${p.basename(source)}:$e');
    }
  }

  return ImportResult(
    imported: imported,
    renamed: renamed,
    skipped: skipped,
    errors: errors,
  );
}

/// 在 [destDir] 中为 [name] 找一个不冲突的目标路径;冲突时追加 ` (2)`、` (3)`…
/// 保留扩展名(仅对文件;文件夹整体加后缀)。
String _uniqueTarget(String destDir, String name) {
  var candidate = p.join(destDir, name);
  if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.notFound) {
    return candidate;
  }
  final ext = p.extension(name);
  final stem = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  for (var i = 2; i < 10000; i++) {
    candidate = p.join(destDir, '$stem ($i)$ext');
    if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return candidate;
}

/// 递归复制目录 [source] 到 [dest](dest 尚不存在)。
Future<void> _copyDirectory(Directory source, Directory dest) async {
  await dest.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final newPath = p.join(dest.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(newPath));
    } else if (entity is File) {
      await entity.copy(newPath);
    }
  }
}

/// 主区视图模式。
enum _ViewMode { grid, list }

/// 文件浏览页。根目录为 [AppState.config] 的 `sharedDir`。
///
/// 交互约定:**单击 = 选中**,**双击 = 打开文件 / 进入文件夹**。
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.state});

  final AppState state;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  /// 相对共享根的当前路径段;空列表表示在根目录。
  List<String> _segments = const [];

  /// 导航历史栈(每项为一个路径段列表)与当前位置游标。
  final List<List<String>> _history = [const []];
  int _historyIndex = 0;

  List<FileEntry> _entries = const [];
  bool _loading = false;
  String? _error;

  _ViewMode _viewMode = _ViewMode.grid;
  SortColumn _sortColumn = SortColumn.name;
  bool _sortAsc = true;

  /// 当前选中项的名称集合(Finder 式多选)。
  final Set<String> _selected = {};

  /// 最近一次单击锚点(用于 Shift 范围选);为 null 表示尚无锚点。
  String? _anchor;

  /// 实时搜索关键字(过滤当前目录名称,不区分大小写)。
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  /// 主区焦点节点(承载键盘快捷键)。
  final FocusNode _bodyFocus = FocusNode();

  /// Finder 拖入悬停中(用于给主区高亮)。
  bool _dropHover = false;

  /// 每次刷新后自增,通知侧栏树重列已展开节点。
  int _refreshTick = 0;

  /// 手动双击识别:上次单击的项与时刻(避免用 GestureDetector.onDoubleTap 带来的
  /// 单击延迟与遗留定时器)。同一项在阈值内的第二次单击视为双击。
  String? _lastClickName;
  DateTime? _lastClickAt;
  static const Duration _doubleClickWindow = Duration(milliseconds: 400);

  String? get _sharedDir => widget.state.config?.sharedDir;

  /// 当前目录的绝对路径。
  String get _currentAbs => p.joinAll([_sharedDir!, ..._segments]);

  /// 当前目录相对共享根的正斜杠路径(根目录为空串)。
  String get _currentRelative => _segments.join('/');

  bool get _canBack => _historyIndex > 0;
  bool get _canForward => _historyIndex < _history.length - 1;
  bool get _canUp => _segments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_sharedDir != null) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  /// 当前目录过滤 + 排序后的可见条目(UI 渲染用)。
  List<FileEntry> get _visibleEntries {
    final q = _query.trim().toLowerCase();
    var list = q.isEmpty
        ? List<FileEntry>.from(_entries)
        : _entries.where((e) => e.name.toLowerCase().contains(q)).toList();
    list.sort(_compareEntries);
    return list;
  }

  /// 排序比较:文件夹恒排在文件前;其余按所选列升/降序。
  int _compareEntries(FileEntry a, FileEntry b) {
    // 文件夹优先(在「类型」列也保持分组)。
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    int cmp;
    switch (_sortColumn) {
      case SortColumn.name:
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SortColumn.kind:
        cmp = kindLabel(a).compareTo(kindLabel(b));
        if (cmp == 0) {
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
      case SortColumn.size:
        cmp = (a.size ?? -1).compareTo(b.size ?? -1);
        if (cmp == 0) {
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
      case SortColumn.modified:
        final at = a.modified?.millisecondsSinceEpoch ?? 0;
        final bt = b.modified?.millisecondsSinceEpoch ?? 0;
        cmp = at.compareTo(bt);
        if (cmp == 0) {
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
    }
    return _sortAsc ? cmp : -cmp;
  }

  /// 重新列出当前目录。文件夹在前、文件在后,各自按名称(忽略大小写)排序。
  Future<void> _refresh() async {
    if (_sharedDir == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await listEntries(_currentAbs,
          hideSyncDir: _segments.isEmpty);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        // 清理已不存在的选中项。
        final names = entries.map((e) => e.name).toSet();
        _selected.removeWhere((n) => !names.contains(n));
        _refreshTick++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _loading = false;
        _error = '读取目录失败:$e';
        _refreshTick++;
      });
    }
  }

  // ---- 导航(历史栈) ----

  /// 导航到指定路径段(压入历史);[record] 为 false 时不动历史(用于前进/后退)。
  void _navigateTo(List<String> segments, {bool record = true}) {
    setState(() {
      _segments = List<String>.from(segments);
      _selected.clear();
      _anchor = null;
      if (record) {
        // 截断当前位置之后的历史,压入新位置。
        _history.removeRange(_historyIndex + 1, _history.length);
        _history.add(List<String>.from(segments));
        _historyIndex = _history.length - 1;
      }
    });
    _refresh();
  }

  void _back() {
    if (!_canBack) return;
    _historyIndex--;
    _navigateTo(_history[_historyIndex], record: false);
  }

  void _forward() {
    if (!_canForward) return;
    _historyIndex++;
    _navigateTo(_history[_historyIndex], record: false);
  }

  void _goUp() {
    if (!_canUp) return;
    _navigateTo(_segments.sublist(0, _segments.length - 1));
  }

  /// 进入子文件夹(双击 / Enter / 树点击)。
  void _enter(String name) => _navigateTo([..._segments, name]);

  /// 跳到面包屑某一层级([count] 个段;0 表示共享根)。
  void _jumpTo(int count) => _navigateTo(_segments.sublist(0, count));

  /// 拼出某个项相对共享根的正斜杠路径(传给 revealInFileManager)。
  String _relativeOf(String name) =>
      _segments.isEmpty ? name : '$_currentRelative/$name';

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- 选择模型 ----

  /// 主区某项被左键点击:手动识别单击/双击。
  ///
  /// 用 GestureDetector.onTap(而非 onDoubleTap)+ 自管时间窗,避免 onDoubleTap
  /// 引入的单击延迟与「widget 树 dispose 后仍有定时器」问题:第一次点击立即选中,
  /// 同一项在 [_doubleClickWindow] 内的第二次点击触发打开/进入。
  void _handleActivate(FileEntry e) {
    final now = DateTime.now();
    final isDouble = _lastClickName == e.name &&
        _lastClickAt != null &&
        now.difference(_lastClickAt!) <= _doubleClickWindow;
    // 单击始终先更新选中(Finder 行为:第二次点击前该项已是选中态)。
    _selectOnClick(e);
    if (isDouble) {
      _lastClickName = null;
      _lastClickAt = null;
      _open(e);
    } else {
      _lastClickName = e.name;
      _lastClickAt = now;
    }
  }

  /// 单击选中:按修饰键决定单选 / 切换多选 / 范围选。
  void _selectOnClick(FileEntry e) {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final multi = pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    final range = pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    setState(() {
      if (range && _anchor != null) {
        _selectRange(_anchor!, e.name);
      } else if (multi) {
        if (!_selected.add(e.name)) _selected.remove(e.name);
        _anchor = e.name;
      } else {
        _selected
          ..clear()
          ..add(e.name);
        _anchor = e.name;
      }
    });
    _bodyFocus.requestFocus();
  }

  /// 在可见顺序里选中 [from]..[to] 之间(含两端)的所有项。
  void _selectRange(String from, String to) {
    final names = _visibleEntries.map((e) => e.name).toList();
    final i = names.indexOf(from);
    final j = names.indexOf(to);
    if (i < 0 || j < 0) {
      _selected
        ..clear()
        ..add(to);
      return;
    }
    final lo = i < j ? i : j;
    final hi = i < j ? j : i;
    _selected
      ..clear()
      ..addAll(names.sublist(lo, hi + 1));
  }

  /// 打开:进入文件夹 / 打开文件(双击、Enter、菜单「打开」共用)。
  void _open(FileEntry e) {
    if (e.isDir) {
      _enter(e.name);
    } else {
      _openFile(e.name);
    }
  }

  /// 右键某项:若未被选中则先单选它,再返回它(供菜单使用)。
  void _ensureSelected(FileEntry e) {
    if (!_selected.contains(e.name)) {
      setState(() {
        _selected
          ..clear()
          ..add(e.name);
        _anchor = e.name;
      });
    }
  }

  // ---- 文件操作 ----

  /// 用系统默认程序打开文件(按平台分支,参考 revealInFileManager 写法)。
  Future<void> _openFile(String name) async {
    final abs = p.join(_currentAbs, name);
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [abs]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [abs]);
      } else {
        await Process.run('xdg-open', [abs]);
      }
    } catch (e) {
      _showSnack('无法打开文件:$e');
    }
  }

  Future<void> _reveal(String name) async {
    final error = await widget.state.revealInFileManager(_relativeOf(name));
    if (error != null) _showSnack(error);
  }

  /// 校验新名称:非空、不含路径分隔符、不与现有项重名。返回错误文案或 null。
  String? _validateName(String raw, {String? exclude}) {
    final name = raw.trim();
    if (name.isEmpty) return '名称不能为空';
    if (name.contains('/') || name.contains(r'\')) return '名称不能包含路径分隔符';
    if (name == '.' || name == '..') return '名称不合法';
    if (name == exclude) return null;
    final exists =
        _entries.any((e) => e.name.toLowerCase() == name.toLowerCase());
    if (exists) return '已存在同名项:$name';
    return null;
  }

  Future<void> _newFolder() async {
    final name = await _promptName(
      title: '新建文件夹',
      label: '文件夹名称',
      confirmLabel: '创建',
    );
    if (name == null) return;
    try {
      await Directory(p.join(_currentAbs, name)).create();
      await _refresh();
      _showSnack('已创建文件夹:$name,将自动同步');
    } catch (e) {
      _showSnack('创建失败:$e');
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final name = await _promptName(
      title: '重命名',
      label: '新名称',
      confirmLabel: '重命名',
      initial: entry.name,
    );
    if (name == null || name == entry.name) return;
    final from = p.join(_currentAbs, entry.name);
    final to = p.join(_currentAbs, name);
    try {
      if (entry.isDir) {
        await Directory(from).rename(to);
      } else {
        await File(from).rename(to);
      }
      await _refresh();
      _showSnack('已重命名为:$name,将自动同步');
    } catch (e) {
      _showSnack('重命名失败:$e');
    }
  }

  /// 删除一个或多个条目(带确认)。[entries] 为空时无操作。
  Future<void> _delete(List<FileEntry> entries) async {
    if (entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(_deletePrompt(entries)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    var ok = 0;
    final failures = <String>[];
    for (final entry in entries) {
      final abs = p.join(_currentAbs, entry.name);
      try {
        if (entry.isDir) {
          await Directory(abs).delete(recursive: true);
        } else {
          await File(abs).delete();
        }
        ok++;
      } catch (e) {
        failures.add('${entry.name}:$e');
      }
    }
    await _refresh();
    if (failures.isEmpty) {
      _showSnack(entries.length == 1
          ? '已删除:${entries.first.name}'
          : '已删除 $ok 项');
    } else {
      _showSnack('删除完成 $ok 项,失败 ${failures.length} 项');
    }
  }

  String _deletePrompt(List<FileEntry> entries) {
    if (entries.length == 1) {
      final e = entries.first;
      return e.isDir
          ? '将永久删除文件夹「${e.name}」及其全部内容,此操作不可撤销。'
          : '将永久删除文件「${e.name}」,此操作不可撤销。';
    }
    return '将永久删除选中的 ${entries.length} 项(含其中文件夹的全部内容),此操作不可撤销。';
  }

  /// 删除当前选中(供键盘 / 批量菜单)。
  Future<void> _deleteSelected() async {
    final entries =
        _entries.where((e) => _selected.contains(e.name)).toList();
    await _delete(entries);
  }

  // ---- 拖拽:应用内移动 ----

  /// 把 [entry] 移动进 [destDirAbs] 目录。
  Future<void> _moveEntryTo(FileEntry entry, String destDirAbs) async {
    final sourceAbs = p.join(_currentAbs, entry.name);
    final result = await moveEntry(
      sharedDir: _sharedDir!,
      sourceAbs: sourceAbs,
      destDirAbs: destDirAbs,
    );
    switch (result.outcome) {
      case MoveOutcome.moved:
        await _refresh();
        _showSnack('已移动「${entry.name}」,将自动同步');
      case MoveOutcome.sameDir:
        break;
      case MoveOutcome.intoSelf:
        _showSnack(result.message ?? '不能移动到自身或其子目录');
      case MoveOutcome.nameClash:
        _showSnack('目标已存在同名项,已取消移动');
      case MoveOutcome.outsideRoot:
        _showSnack('目标超出共享目录,已取消移动');
      case MoveOutcome.failed:
        _showSnack('移动失败:${result.message}');
    }
  }

  /// 跳到面包屑第 [count] 层(0=根)对应的目录,并把 [entry] 移过去。
  Future<void> _moveEntryToBreadcrumb(int count, FileEntry entry) async {
    final destAbs = p.joinAll([_sharedDir!, ..._segments.sublist(0, count)]);
    await _moveEntryTo(entry, destAbs);
  }

  /// 把当前目录里的 [entry] 移动到上一级目录(工具栏「上级」按钮 DragTarget)。
  Future<void> _moveEntryUp(FileEntry entry) async {
    if (_segments.isEmpty) return;
    final parentAbs = p.joinAll(
        [_sharedDir!, ..._segments.sublist(0, _segments.length - 1)]);
    await _moveEntryTo(entry, parentAbs);
  }

  // ---- 拖拽:外部导入(复制) ----

  /// 把从 Finder 拖入的若干路径复制进当前目录,并以 SnackBar 汇总结果。
  Future<void> _importDropped(List<String> paths) async {
    if (paths.isEmpty) return;
    final result = await importPaths(
      sharedDir: _sharedDir!,
      destDirAbs: _currentAbs,
      sourcePaths: paths,
    );
    await _refresh();
    final parts = <String>[];
    if (result.imported > 0) parts.add('导入 ${result.imported} 项');
    if (result.renamed > 0) parts.add('改名 ${result.renamed} 项');
    if (result.skipped > 0) parts.add('跳过 ${result.skipped} 项');
    if (result.hasError) parts.add('失败 ${result.errors.length} 项');
    if (parts.isEmpty) {
      _showSnack('没有可导入的内容');
    } else {
      final suffix = result.imported > 0 ? ',将自动同步' : '';
      _showSnack('${parts.join(',')}$suffix');
    }
  }

  /// 弹出输入框收集名称并实时校验;确定返回名称,取消返回 null。
  Future<String?> _promptName({
    required String title,
    required String label,
    required String confirmLabel,
    String? initial,
  }) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            void submit() {
              final problem =
                  _validateName(controller.text, exclude: initial);
              if (problem != null) {
                setLocal(() => error = problem);
                return;
              }
              Navigator.of(ctx).pop(controller.text.trim());
            }

            return AlertDialog(
              title: Text(title),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: label,
                  border: const OutlineInputBorder(),
                  errorText: error,
                ),
                onChanged: (_) {
                  if (error != null) setLocal(() => error = null);
                },
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(onPressed: submit, child: Text(confirmLabel)),
              ],
            );
          },
        );
      },
    );
  }

  // ---- 上下文菜单 ----

  /// 条目操作菜单项(三点/右键复用同一份);多选时「打开」与「重命名」隐藏,
  /// 「删除」改为批量。
  List<PopupMenuEntry<String>> _entryMenuItems(FileEntry entry) {
    final multi = _selected.length > 1 && _selected.contains(entry.name);
    return [
      if (!multi)
        PopupMenuItem(
          value: 'open',
          child: Text(entry.isDir ? '进入文件夹' : '打开文件'),
        ),
      const PopupMenuItem(value: 'reveal', child: Text('在访达中显示')),
      if (!multi) const PopupMenuItem(value: 'rename', child: Text('重命名')),
      PopupMenuItem(
        value: 'delete',
        child: Text(
          multi ? '删除选中 ${_selected.length} 项' : '删除',
          style: const TextStyle(color: Colors.red),
        ),
      ),
    ];
  }

  Future<void> _showEntryMenu(FileEntry entry, Offset globalPosition) async {
    _ensureSelected(entry);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: _entryMenuItems(entry),
    );
    if (value == null) return;
    switch (value) {
      case 'open':
        _open(entry);
      case 'reveal':
        await _reveal(entry.name);
      case 'rename':
        await _rename(entry);
      case 'delete':
        final targets = _selected.length > 1 && _selected.contains(entry.name)
            ? _entries.where((e) => _selected.contains(e.name)).toList()
            : [entry];
        await _delete(targets);
    }
  }

  /// 空白处右键菜单(新建文件夹 / 刷新)。
  Future<void> _showBlankAreaMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: 'newFolder', child: Text('新建文件夹')),
        PopupMenuItem(value: 'refresh', child: Text('刷新')),
      ],
    );
    switch (value) {
      case 'newFolder':
        await _newFolder();
      case 'refresh':
        await _refresh();
    }
  }

  // ---- 键盘 ----

  /// Enter 打开选中;Delete/Backspace 删除选中;方向键移动选中。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final e = _singleSelected();
      if (e != null) {
        _open(e);
        return KeyEventResult.handled;
      }
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (_selected.isNotEmpty) {
        _deleteSelected();
        return KeyEventResult.handled;
      }
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(1);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 若恰好选中一项则返回它,否则 null。
  FileEntry? _singleSelected() {
    if (_selected.length != 1) return null;
    final name = _selected.first;
    for (final e in _entries) {
      if (e.name == name) return e;
    }
    return null;
  }

  /// 方向键在可见列表中上下移动单选。
  void _moveSelection(int delta) {
    final names = _visibleEntries.map((e) => e.name).toList();
    if (names.isEmpty) return;
    var index = _anchor == null ? -1 : names.indexOf(_anchor!);
    index += delta;
    if (index < 0) index = 0;
    if (index >= names.length) index = names.length - 1;
    final name = names[index];
    setState(() {
      _selected
        ..clear()
        ..add(name);
      _anchor = name;
    });
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    if (_sharedDir == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off, size: 48),
            SizedBox(height: 12),
            Text('请先在设置中完成配置'),
          ],
        ),
      );
    }

    final theme = Theme.of(context);
    return Column(
      children: [
        _buildToolbar(theme),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FileTreeSidebar(
                sharedDir: _sharedDir!,
                currentRelative: _currentRelative,
                onNavigate: _navigateTo,
                onMoveInto: _moveEntryTo,
                refreshTick: _refreshTick,
              ),
              Expanded(child: _buildMainArea(theme)),
            ],
          ),
        ),
        const Divider(height: 1),
        _buildStatusBar(theme),
      ],
    );
  }

  // ---- 工具栏 ----

  Widget _buildToolbar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '后退',
            icon: const Icon(Icons.arrow_back),
            onPressed: _canBack ? _back : null,
          ),
          IconButton(
            tooltip: '前进',
            icon: const Icon(Icons.arrow_forward),
            onPressed: _canForward ? _forward : null,
          ),
          _UpButton(
            enabled: _canUp,
            onUp: _goUp,
            onAcceptUp: _canUp ? _moveEntryUp : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Breadcrumbs(
              segments: _segments,
              onJump: _jumpTo,
              onAcceptTo: _moveEntryToBreadcrumb,
            ),
          ),
          const SizedBox(width: 8),
          // 视图切换。
          SegmentedButton<_ViewMode>(
            segments: const [
              ButtonSegment(
                value: _ViewMode.grid,
                icon: Icon(Icons.grid_view),
                tooltip: '图标视图',
              ),
              ButtonSegment(
                value: _ViewMode.list,
                icon: Icon(Icons.view_list),
                tooltip: '详情视图',
              ),
            ],
            selected: {_viewMode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _viewMode = s.first),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 180,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索当前目录',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: '清除',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _newFolder,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
    );
  }

  // ---- 主区 ----

  Widget _buildMainArea(ThemeData theme) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropHover = true),
      onDragExited: (_) => setState(() => _dropHover = false),
      onDragDone: (detail) {
        setState(() => _dropHover = false);
        final paths = detail.files
            .map((f) => f.path)
            .where((s) => s.isNotEmpty)
            .toList();
        _importDropped(paths);
      },
      child: Focus(
        focusNode: _bodyFocus,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 点空白处:清空选择并取焦点(便于键盘操作)。
          onTap: () {
            setState(() => _selected.clear());
            _bodyFocus.requestFocus();
          },
          onSecondaryTapDown: (d) => _showBlankAreaMenu(d.globalPosition),
          child: Container(
            color: _dropHover
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
                : null,
            child: _dropHover ? _buildDropHint(theme) : _buildBody(theme),
          ),
        ),
      ),
    );
  }

  Widget _buildDropHint(ThemeData theme) {
    final where = _segments.isEmpty ? '共享目录' : _currentRelative;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.file_download_outlined,
              size: 40, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text('松开以导入到「$where」',
              style: TextStyle(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!,
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final visible = _visibleEntries;
    if (visible.isEmpty) {
      return _buildEmpty(theme);
    }
    return _viewMode == _ViewMode.grid
        ? _buildGrid(theme, visible)
        : _buildList(theme, visible);
  }

  Widget _buildEmpty(ThemeData theme) {
    final searching = _query.trim().isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(searching ? Icons.search_off : Icons.folder_open,
              size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 8),
          Text(searching ? '没有匹配「$_query」的项' : '此文件夹为空',
              style: TextStyle(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }

  // 图标网格视图。
  Widget _buildGrid(ThemeData theme, List<FileEntry> visible) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisExtent: 110,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final e = visible[index];
        return _GridCell(
          entry: e,
          selected: _selected.contains(e.name),
          onTap: () => _handleActivate(e),
          onContext: (pos) => _showEntryMenu(e, pos),
          onAcceptInto: e.isDir
              ? (dragged) =>
                  _moveEntryTo(dragged, p.join(_currentAbs, e.name))
              : null,
          canAccept: (dragged) => dragged.name != e.name,
        );
      },
    );
  }

  // 详情列表视图(带可排序列头)。
  Widget _buildList(ThemeData theme, List<FileEntry> visible) {
    return Column(
      children: [
        _ListHeader(
          sortColumn: _sortColumn,
          ascending: _sortAsc,
          onSort: (col) {
            setState(() {
              if (_sortColumn == col) {
                _sortAsc = !_sortAsc;
              } else {
                _sortColumn = col;
                _sortAsc = true;
              }
            });
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: visible.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final e = visible[index];
              return _ListRow(
                entry: e,
                selected: _selected.contains(e.name),
                onTap: () => _handleActivate(e),
                onContext: (pos) => _showEntryMenu(e, pos),
                onAcceptInto: e.isDir
                    ? (dragged) =>
                        _moveEntryTo(dragged, p.join(_currentAbs, e.name))
                    : null,
                canAccept: (dragged) => dragged.name != e.name,
              );
            },
          ),
        ),
      ],
    );
  }

  // ---- 状态栏 ----

  Widget _buildStatusBar(ThemeData theme) {
    final visible = _visibleEntries;
    final parts = <String>['共 ${visible.length} 项'];
    if (_selected.isNotEmpty) {
      parts.add('已选 ${_selected.length} 项');
      final totalSize = _entries
          .where((e) => _selected.contains(e.name) && !e.isDir)
          .fold<int>(0, (sum, e) => sum + (e.size ?? 0));
      if (totalSize > 0) parts.add('合计 ${formatSize(totalSize)}');
    }
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        parts.join('  ·  '),
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 工具栏「上级」按钮:也作为把条目移动到父目录的 DragTarget。
class _UpButton extends StatelessWidget {
  const _UpButton({
    required this.enabled,
    required this.onUp,
    this.onAcceptUp,
  });

  final bool enabled;
  final VoidCallback onUp;
  final void Function(FileEntry entry)? onAcceptUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<FileEntry>(
      onWillAcceptWithDetails: (_) => onAcceptUp != null,
      onAcceptWithDetails: (d) => onAcceptUp?.call(d.data),
      builder: (context, candidate, rejected) {
        final hot = candidate.isNotEmpty && onAcceptUp != null;
        return Container(
          decoration: BoxDecoration(
            color: hot ? theme.colorScheme.primaryContainer : null,
            borderRadius: BorderRadius.circular(20),
          ),
          child: IconButton(
            tooltip: '上级目录(可拖入移动到父目录)',
            icon: const Icon(Icons.arrow_upward),
            onPressed: enabled ? onUp : null,
          ),
        );
      },
    );
  }
}

/// 路径面包屑:从共享目录根开始,可点击任意层级跳转;每个上级层级是 DragTarget。
class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.segments,
    required this.onJump,
    this.onAcceptTo,
  });

  final List<String> segments;
  final void Function(int count) onJump;
  final void Function(int count, FileEntry entry)? onAcceptTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      _crumb(context, label: '共享目录', count: 0, isLast: segments.isEmpty),
    ];
    for (var i = 0; i < segments.length; i++) {
      children.add(Icon(Icons.chevron_right,
          size: 18, color: theme.colorScheme.outline));
      children.add(_crumb(
        context,
        label: segments[i],
        count: i + 1,
        isLast: i == segments.length - 1,
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(children: children),
    );
  }

  Widget _crumb(BuildContext context,
      {required String label, required int count, required bool isLast}) {
    final theme = Theme.of(context);
    if (isLast) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(label,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      );
    }
    final button = TextButton(
      onPressed: () => onJump(count),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label),
    );
    if (onAcceptTo == null) return button;
    return DragTarget<FileEntry>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onAcceptTo!(count, d.data),
      builder: (context, candidate, rejected) {
        if (candidate.isEmpty) return button;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: button,
        );
      },
    );
  }
}

/// 详情视图列头:点击列名切换排序列 / 升降序,有箭头指示。
class _ListHeader extends StatelessWidget {
  const _ListHeader({
    required this.sortColumn,
    required this.ascending,
    required this.onSort,
  });

  final SortColumn sortColumn;
  final bool ascending;
  final void Function(SortColumn column) onSort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _cell(theme, '名称', SortColumn.name, flex: 5),
          _cell(theme, '类型', SortColumn.kind, flex: 2),
          _cell(theme, '大小', SortColumn.size, flex: 2),
          _cell(theme, '修改时间', SortColumn.modified, flex: 3),
          // 与行内 trailing 菜单按钮对齐。
          const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _cell(ThemeData theme, String label, SortColumn col,
      {required int flex}) {
    final active = sortColumn == col;
    return Expanded(
      flex: flex,
      child: InkWell(
        onTap: () => onSort(col),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (active)
                Icon(
                  ascending ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 详情视图的一行:单击选中、再次单击打开(由上层 [onTap] 自管双击)、右键弹菜单;
/// 行内为 Draggable 源,文件夹行为 DragTarget。
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onContext,
    this.onAcceptInto,
    this.canAccept,
  });

  final FileEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onContext;
  final void Function(FileEntry dragged)? onAcceptInto;
  final bool Function(FileEntry dragged)? canAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget rowFor({required bool dropHot}) {
      final highlighted = selected || dropHot;
      final sizeText = entry.isDir ? '--' : formatSize(entry.size ?? 0);
      final modText =
          entry.modified == null ? '' : formatModified(entry.modified!);
      return Container(
        color: highlighted
            ? (dropHot
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.secondaryContainer)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  entryIcon(entry, theme.colorScheme, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: entry.name,
                      child: Text(entry.name, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(kindLabel(entry),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ),
            Expanded(
              flex: 2,
              child: Text(sizeText, style: theme.textTheme.bodySmall),
            ),
            Expanded(
              flex: 3,
              child: Text(modText, style: theme.textTheme.bodySmall),
            ),
            SizedBox(
              width: 40,
              child: _RowMenuButton(onContext: onContext),
            ),
          ],
        ),
      );
    }

    Widget interactive = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onSecondaryTapDown: (d) => onContext(d.globalPosition),
      child: rowFor(dropHot: false),
    );

    if (onAcceptInto != null) {
      final base = interactive;
      interactive = DragTarget<FileEntry>(
        onWillAcceptWithDetails: (d) => canAccept?.call(d.data) ?? true,
        onAcceptWithDetails: (d) => onAcceptInto!(d.data),
        builder: (context, candidate, rejected) {
          if (candidate.isEmpty) return base;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onSecondaryTapDown: (d) => onContext(d.globalPosition),
            child: rowFor(dropHot: true),
          );
        },
      );
    }

    return Draggable<FileEntry>(
      data: entry,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragFeedback(entry: entry),
      childWhenDragging: Opacity(opacity: 0.4, child: interactive),
      child: interactive,
    );
  }
}

/// 行尾的「更多操作」按钮(右键等价入口,便于纯指针用户)。
class _RowMenuButton extends StatelessWidget {
  const _RowMenuButton({required this.onContext});

  final void Function(Offset globalPosition) onContext;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '更多操作',
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.center(Offset.zero));
        onContext(pos);
      },
    );
  }
}

/// 图标网格的一格:大图标 + 名称(省略 + tooltip);单击选中、再次单击打开(由
/// 上层 [onTap] 自管双击)、右键弹菜单、可拖放。
class _GridCell extends StatelessWidget {
  const _GridCell({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onContext,
    this.onAcceptInto,
    this.canAccept,
  });

  final FileEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onContext;
  final void Function(FileEntry dragged)? onAcceptInto;
  final bool Function(FileEntry dragged)? canAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget cellFor({required bool dropHot}) {
      final highlighted = selected || dropHot;
      return Container(
        decoration: BoxDecoration(
          color: highlighted
              ? (dropHot
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.secondaryContainer)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            entryIcon(entry, theme.colorScheme, size: 44),
            const SizedBox(height: 6),
            Tooltip(
              message: entry.name,
              child: Text(
                entry.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    Widget interactive = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onSecondaryTapDown: (d) => onContext(d.globalPosition),
      child: cellFor(dropHot: false),
    );

    if (onAcceptInto != null) {
      final base = interactive;
      interactive = DragTarget<FileEntry>(
        onWillAcceptWithDetails: (d) => canAccept?.call(d.data) ?? true,
        onAcceptWithDetails: (d) => onAcceptInto!(d.data),
        builder: (context, candidate, rejected) {
          if (candidate.isEmpty) return base;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onSecondaryTapDown: (d) => onContext(d.globalPosition),
            child: cellFor(dropHot: true),
          );
        },
      );
    }

    return Draggable<FileEntry>(
      data: entry,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragFeedback(entry: entry),
      childWhenDragging: Opacity(opacity: 0.4, child: interactive),
      child: interactive,
    );
  }
}

/// 拖动时跟随指针的小卡片(显示文件/文件夹名)。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.entry});

  final FileEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            entryIcon(entry, theme.colorScheme, size: 18),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(entry.name, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
