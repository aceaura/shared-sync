/// Shared data model for the sync engine. See DESIGN.md §4.1.
library;

/// File mode as stored in a git tree: 100644 (regular) or 100755 (executable).
enum EntryMode {
  regular,
  executable;

  /// Git tree mode string for `update-index --index-info`.
  String get gitMode => this == EntryMode.executable ? '100755' : '100644';

  static EntryMode fromGitMode(String mode) =>
      mode == '100755' ? EntryMode.executable : EntryMode.regular;
}

/// One file in a tree snapshot (base / local / remote / merged).
class FileEntry {
  /// Relative path from the shared root, forward slashes, no leading slash.
  final String path;

  /// Git blob SHA-1 (40 hex chars) of the content.
  final String hash;

  final EntryMode mode;

  const FileEntry({
    required this.path,
    required this.hash,
    this.mode = EntryMode.regular,
  });

  /// Content-equality used by the three-way planner (hash + mode).
  bool sameContent(FileEntry? other) =>
      other != null && hash == other.hash && mode == other.mode;

  @override
  bool operator ==(Object other) =>
      other is FileEntry &&
      other.path == path &&
      other.hash == hash &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(path, hash, mode);

  @override
  String toString() => 'FileEntry($path, ${hash.substring(0, 7)}, $mode)';
}

/// Snapshot of a whole tree: relative path -> entry.
typedef TreeState = Map<String, FileEntry>;

/// True when both trees contain exactly the same paths with the same
/// content hash and mode.
bool treesEqual(TreeState a, TreeState b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!entry.value.sameContent(b[entry.key])) return false;
  }
  return true;
}

/// Cached stat info from the last successful sync, used to skip re-hashing
/// unchanged files. `mtime` is a fast filter only, never a conflict criterion.
class CachedStat {
  final int size;
  final int mtimeMs;
  final String hash;
  final EntryMode mode;

  const CachedStat({
    required this.size,
    required this.mtimeMs,
    required this.hash,
    required this.mode,
  });
}

/// Result of a full local scan.
class LocalScanResult {
  final TreeState files;

  /// Paths that were still changing during the scan (or modified less than
  /// the stability delay ago). The engine freezes these for this cycle.
  final Set<String> unstablePaths;

  /// Fresh stat+hash for every scanned file, to persist as the next cache.
  final Map<String, CachedStat> stats;

  const LocalScanResult({
    required this.files,
    required this.unstablePaths,
    required this.stats,
  });
}

/// Write remote blob [hash] to local [path].
class DownloadAction {
  final String path;
  final String hash;
  final EntryMode mode;

  const DownloadAction({
    required this.path,
    required this.hash,
    this.mode = EntryMode.regular,
  });
}

/// Local content at [originalPath] must be preserved as [copyPath] before the
/// original path is overwritten or deleted.
class ConflictCopy {
  final String originalPath;
  final String copyPath;
  final String localHash;
  final EntryMode mode;

  const ConflictCopy({
    required this.originalPath,
    required this.copyPath,
    required this.localHash,
    this.mode = EntryMode.regular,
  });
}

/// Local delete vs remote modify: the remote file is kept and the local
/// delete is recorded as a conflict (requirements §10.2).
class DeleteConflict {
  final String path;

  const DeleteConflict({required this.path});
}

/// Output of the three-way planner (DESIGN.md §3).
class SyncPlan {
  /// The tree to commit and push (authoritative next snapshot).
  final TreeState mergedTree;

  final List<DownloadAction> downloads;
  final List<String> localDeletes;
  final List<ConflictCopy> conflictCopies;
  final List<DeleteConflict> deleteConflicts;

  /// True when [mergedTree] differs from the remote tree, i.e. a commit must
  /// be pushed.
  final bool hasRemoteChanges;

  const SyncPlan({
    required this.mergedTree,
    required this.downloads,
    required this.localDeletes,
    required this.conflictCopies,
    required this.deleteConflicts,
    required this.hasRemoteChanges,
  });

  bool get isNoop =>
      !hasRemoteChanges &&
      downloads.isEmpty &&
      localDeletes.isEmpty &&
      conflictCopies.isEmpty &&
      deleteConflicts.isEmpty;
}

/// One line in `.sync/conflicts.jsonl`.
class ConflictRecord {
  final DateTime time;

  /// `modify` | `delete` | `create`
  final String kind;
  final String path;
  final String? copyPath;
  final String clientId;

  const ConflictRecord({
    required this.time,
    required this.kind,
    required this.path,
    required this.copyPath,
    required this.clientId,
  });

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'kind': kind,
        'path': path,
        'copyPath': copyPath,
        'clientId': clientId,
      };

  factory ConflictRecord.fromJson(Map<String, dynamic> json) => ConflictRecord(
        time: DateTime.parse(json['time'] as String),
        kind: json['kind'] as String,
        path: json['path'] as String,
        copyPath: json['copyPath'] as String?,
        clientId: json['clientId'] as String? ?? '',
      );
}

enum SyncPhase { idle, scanning, fetching, planning, pushing, applying, error }

/// Summary of one completed sync cycle.
class SyncReport {
  final DateTime startedAt;
  final Duration duration;
  final int uploaded;
  final int downloaded;
  final int deletedLocal;
  final int deletedRemote;
  final List<ConflictRecord> conflicts;
  final bool compressionDetected;
  final String? pushedCommit;
  final String? error;

  const SyncReport({
    required this.startedAt,
    required this.duration,
    this.uploaded = 0,
    this.downloaded = 0,
    this.deletedLocal = 0,
    this.deletedRemote = 0,
    this.conflicts = const [],
    this.compressionDetected = false,
    this.pushedCommit,
    this.error,
  });

  bool get hasError => error != null;

  bool get isNoop =>
      uploaded == 0 &&
      downloaded == 0 &&
      deletedLocal == 0 &&
      deletedRemote == 0 &&
      conflicts.isEmpty &&
      error == null;

  String summary() {
    if (hasError) return 'error: $error';
    if (isNoop) return 'no changes';
    final parts = <String>[
      if (uploaded > 0) 'up $uploaded',
      if (downloaded > 0) 'down $downloaded',
      if (deletedLocal > 0) 'del-local $deletedLocal',
      if (deletedRemote > 0) 'del-remote $deletedRemote',
      if (conflicts.isNotEmpty) 'conflicts ${conflicts.length}',
      if (compressionDetected) 'history-compression-detected',
    ];
    return parts.join(', ');
  }
}
