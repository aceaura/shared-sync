/// 文件浏览器共享的小工具:条目模型、图标分类、大小/时间格式化、`.sync` 常量。
///
/// 这些被 [FilesPage](主区)与 [FileTreeSidebar](侧栏)共用,集中放在一处避免
/// 两处维护漂移。全部为纯展示逻辑,不做任何写操作。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 引擎元数据目录名,隐藏以免用户误操作破坏同步状态。
const String syncDirName = '.sync';

/// 侧栏固定宽度(Material 3 surface 配色,与主区分隔)。
const double kSidebarWidth = 220;

/// 一个目录项(文件或文件夹)的展示模型。
///
/// 这是 UI 层在主区与拖拽中传递的最小数据;真实路径由调用方按当前目录拼接。
class FileEntry {
  const FileEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  final String name;
  final bool isDir;

  /// 文件大小(字节);文件夹为 null。
  final int? size;
  final DateTime? modified;
}

/// 详情视图可排序的列。
enum SortColumn { name, kind, size, modified }

/// 按扩展名把文件粗分为几类,用于挑选大图标(图片/文档/压缩包/代码/通用)。
enum FileKind { folder, image, document, archive, code, generic }

const Set<String> _imageExts = {
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tiff', '.svg',
  '.ico',
};
const Set<String> _docExts = {
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.md',
  '.rtf', '.odt', '.pages', '.numbers', '.key', '.csv',
};
const Set<String> _archiveExts = {
  '.zip', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.7z', '.rar', '.zst',
};
const Set<String> _codeExts = {
  '.dart', '.js', '.ts', '.jsx', '.tsx', '.py', '.java', '.kt', '.swift',
  '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.go', '.rs', '.rb', '.php',
  '.html', '.css', '.scss', '.json', '.yaml', '.yml', '.toml', '.xml',
  '.sh', '.bash', '.zsh', '.sql',
};

/// 判定一个条目的种类(文件夹优先,其余看扩展名)。
FileKind kindOf(FileEntry e) {
  if (e.isDir) return FileKind.folder;
  final ext = p.extension(e.name).toLowerCase();
  if (_imageExts.contains(ext)) return FileKind.image;
  if (_docExts.contains(ext)) return FileKind.document;
  if (_archiveExts.contains(ext)) return FileKind.archive;
  if (_codeExts.contains(ext)) return FileKind.code;
  return FileKind.generic;
}

/// 种类的中文标签(详情视图「类型」列)。
String kindLabel(FileEntry e) {
  switch (kindOf(e)) {
    case FileKind.folder:
      return '文件夹';
    case FileKind.image:
      return '图片';
    case FileKind.document:
      return '文档';
    case FileKind.archive:
      return '压缩包';
    case FileKind.code:
      return '代码';
    case FileKind.generic:
      final ext = p.extension(e.name);
      return ext.isEmpty ? '文件' : '${ext.substring(1).toUpperCase()} 文件';
  }
}

/// 种类对应的图标。
IconData iconForKind(FileKind kind) {
  switch (kind) {
    case FileKind.folder:
      return Icons.folder;
    case FileKind.image:
      return Icons.image_outlined;
    case FileKind.document:
      return Icons.description_outlined;
    case FileKind.archive:
      return Icons.folder_zip_outlined;
    case FileKind.code:
      return Icons.code;
    case FileKind.generic:
      return Icons.insert_drive_file_outlined;
  }
}

/// 条目图标(文件夹用主色,其余用默认前景色)。
Icon entryIcon(FileEntry e, ColorScheme scheme, {double? size}) {
  final kind = kindOf(e);
  return Icon(
    iconForKind(kind),
    size: size,
    color: kind == FileKind.folder ? scheme.primary : null,
  );
}

/// 人类可读的文件大小(B / KB / MB / GB / TB)。
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text =
      value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// 修改时间 `yyyy-MM-dd HH:mm`(本地时区)。
String formatModified(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}'
      ' ${two(l.hour)}:${two(l.minute)}';
}

/// 列出 [dirAbs] 的直接子项,文件夹在前、文件在后,各自按名称(忽略大小写)排序。
///
/// [hideSyncDir] 为真时隐藏顶层 `.sync`(仅当 [dirAbs] 即共享根时生效,由调用方
/// 传入正确的标志)。任何 IO 异常向上抛出,由调用方兜底转成文案。
Future<List<FileEntry>> listEntries(String dirAbs,
    {required bool hideSyncDir}) async {
  final dir = Directory(dirAbs);
  final dirs = <FileEntry>[];
  final files = <FileEntry>[];
  if (await dir.exists()) {
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (hideSyncDir && name == syncDirName) continue;
      final stat = await e.stat();
      if (stat.type == FileSystemEntityType.directory) {
        dirs.add(FileEntry(
          name: name,
          isDir: true,
          size: null,
          modified: stat.modified,
        ));
      } else {
        files.add(FileEntry(
          name: name,
          isDir: false,
          size: stat.size,
          modified: stat.modified,
        ));
      }
    }
  }
  int byName(FileEntry a, FileEntry b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  dirs.sort(byName);
  files.sort(byName);
  return [...dirs, ...files];
}

/// 仅列出 [dirAbs] 的直接子目录名(供侧栏树懒加载);按名称忽略大小写排序,
/// 隐藏顶层 `.sync`。IO 失败返回空列表(侧栏不应因单目录失败而崩)。
Future<List<String>> listSubDirNames(String dirAbs,
    {required bool hideSyncDir}) async {
  try {
    final dir = Directory(dirAbs);
    if (!await dir.exists()) return const [];
    final names = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      if (hideSyncDir && name == syncDirName) continue;
      names.add(name);
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  } catch (_) {
    return const [];
  }
}
