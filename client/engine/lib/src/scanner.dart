/// Local directory scanner: produces the L (local) tree state.
/// See DESIGN.md §4.7.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ignore.dart';
import 'logger.dart';
import 'models.dart';

/// Recursively scans the shared directory and hashes file contents as git
/// blob SHA-1s.
///
/// - Symlinks are never followed; they are logged and skipped.
/// - Ignore rules prune whole directories before descending.
/// - A file whose size+mtime exactly match the previous [CachedStat] reuses
///   the cached hash instead of re-reading content.
/// - Files modified less than [stableDelaySeconds] ago, or that change while
///   being hashed, are reported in [LocalScanResult.unstablePaths] (but still
///   appear in `files`/`stats`; the engine freezes them for this cycle).
class Scanner {
  Scanner({
    required this.sharedDir,
    required this.ignore,
    required this.stableDelaySeconds,
    this.logger,
  });

  /// Absolute path of the shared root.
  final String sharedDir;

  final IgnoreMatcher ignore;

  /// Minimum age (seconds since mtime) before a file is considered stable.
  final int stableDelaySeconds;

  final SyncLogger? logger;

  /// Scans the whole tree. [statCache] comes from the index DB and is only
  /// read, never modified.
  Future<LocalScanResult> scan(Map<String, CachedStat> statCache) async {
    final files = <String, FileEntry>{};
    final unstable = <String>{};
    final stats = <String, CachedStat>{};
    await _walk(Directory(sharedDir), statCache, files, unstable, stats);
    return LocalScanResult(files: files, unstablePaths: unstable, stats: stats);
  }

  Future<void> _walk(
    Directory dir,
    Map<String, CachedStat> cache,
    Map<String, FileEntry> files,
    Set<String> unstable,
    Map<String, CachedStat> stats,
  ) async {
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } on FileSystemException catch (e) {
      logger?.warn('scan: cannot list ${dir.path}: ${e.message}');
      // The directory's files are now absent from `files`, which the planner
      // would read as local deletions. Freeze every previously known path
      // under it so nothing is deleted remotely because of a read error.
      final rel = _rel(dir.path);
      final prefix = rel == '.' ? '' : '$rel/';
      unstable.addAll(cache.keys.where((path) => path.startsWith(prefix)));
      return;
    }
    for (final entity in entries) {
      final rel = _rel(entity.path);
      if (entity is Link) {
        logger?.info('scan: skipping symlink $rel');
        continue;
      }
      if (entity is Directory) {
        if (ignore.isIgnored(rel, isDir: true)) continue;
        await _walk(entity, cache, files, unstable, stats);
      } else if (entity is File) {
        if (ignore.isIgnored(rel, isDir: false)) continue;
        await _processFile(entity, rel, cache, files, unstable, stats);
      }
      // Other entity types (sockets, fifos…) are silently irrelevant here.
    }
  }

  Future<void> _processFile(
    File file,
    String rel,
    Map<String, CachedStat> cache,
    Map<String, FileEntry> files,
    Set<String> unstable,
    Map<String, CachedStat> stats,
  ) async {
    // A file we saw in the listing but cannot stat/read must not silently
    // disappear from `files` — the planner would treat that as a local
    // deletion and propagate it. Freezing the path (unstable, l:=b) is the
    // lossless fallback; a genuine deletion is picked up next cycle.
    final FileStat st;
    try {
      st = await file.stat();
    } on FileSystemException catch (e) {
      logger?.warn('scan: cannot stat $rel, freezing: ${e.message}');
      unstable.add(rel);
      return;
    }
    if (st.type == FileSystemEntityType.notFound) {
      logger?.warn('scan: $rel vanished during scan, freezing');
      unstable.add(rel);
      return;
    }
    final size = st.size;
    final mtimeMs = st.modified.millisecondsSinceEpoch;
    final mode = _modeOf(st);

    var isUnstable = DateTime.now().millisecondsSinceEpoch - mtimeMs <
        stableDelaySeconds * 1000;

    String hash;
    final cached = cache[rel];
    if (cached != null && cached.size == size && cached.mtimeMs == mtimeMs) {
      hash = cached.hash;
    } else {
      try {
        hash = await _gitBlobSha1(file, size);
      } on FileSystemException catch (e) {
        logger?.warn('scan: cannot read $rel, freezing: ${e.message}');
        unstable.add(rel);
        return;
      }
      // Re-stat after hashing: if the file changed underneath us the hash is
      // not trustworthy — freeze the path for this cycle. We keep the *old*
      // stat in the cache so the next scan is guaranteed to re-hash.
      try {
        final st2 = await file.stat();
        if (st2.type == FileSystemEntityType.notFound ||
            st2.size != size ||
            st2.modified.millisecondsSinceEpoch != mtimeMs) {
          isUnstable = true;
        }
      } on FileSystemException {
        isUnstable = true;
      }
    }

    if (isUnstable) unstable.add(rel);
    files[rel] = FileEntry(path: rel, hash: hash, mode: mode);
    stats[rel] =
        CachedStat(size: size, mtimeMs: mtimeMs, hash: hash, mode: mode);
  }

  /// Streams `"blob <size>\0" + content` through SHA-1 — identical to
  /// `git hash-object`, without loading the file into memory.
  Future<String> _gitBlobSha1(File file, int size) async {
    Stream<List<int>> blob() async* {
      yield ascii.encode('blob $size\x00');
      yield* file.openRead();
    }

    final digest = await sha1.bind(blob()).first;
    return digest.toString();
  }

  EntryMode _modeOf(FileStat st) {
    if (Platform.isWindows) return EntryMode.regular;
    // 0x49 == 0o111: any of the user/group/other execute bits.
    return (st.mode & 0x49) != 0 ? EntryMode.executable : EntryMode.regular;
  }

  // Relative path with forward slashes regardless of platform.
  String _rel(String absPath) =>
      p.split(p.relative(absPath, from: sharedDir)).join('/');
}
