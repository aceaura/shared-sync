/// Sync engine orchestrator: wires scanner / git / planner / index DB into
/// the full sync cycle of DESIGN.md §2 (API contract §4.9).
///
/// Core philosophy: prefer giving up the current cycle over silently
/// overwriting or losing user data. The index DB is only advanced after a
/// fully successful cycle, so any abort simply replans from the old base.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import 'config.dart';
import 'git.dart';
import 'ignore.dart';
import 'index_db.dart';
import 'logger.dart';
import 'merge.dart';
import 'models.dart';
import 'scanner.dart';

/// One observable engine event; every event is also written to the log file.
class SyncEvent {
  final DateTime time;
  final String message;
  final LogLevel level;

  const SyncEvent({
    required this.time,
    required this.message,
    required this.level,
  });

  @override
  String toString() => '[${level.name}] $message';
}

/// Orchestrates the full sync cycle over one shared directory.
///
/// Lifecycle: [initialize] (creates `.sync/` structure, takes the lock) →
/// any number of [syncOnce] calls and/or [startAuto] → [stop].
/// [syncOnce] never throws: all failures end up in [SyncReport.error].
class SyncEngine {
  SyncEngine(SyncConfig config, {SyncLogger? logger, this.onEvent})
      : config = config,
        _ownsLogger = logger == null,
        _logger = logger ?? SyncLogger(config.logsDir);

  final SyncConfig config;

  /// Optional listener for engine events (UI status feed).
  final void Function(SyncEvent)? onEvent;

  final SyncLogger _logger;
  final bool _ownsLogger;

  /// File-count threshold above which a cycle warns that per-cycle full-scan
  /// memory grows with the directory size (DESIGN.md §21). Each cycle rebuilds
  /// base/local/remote/merged TreeStates proportional to the file count; this
  /// is a heads-up, not a hard limit.
  static const int largeDirectoryWarnThreshold = 50000;

  GitRepo? _git;
  IndexDb? _db;
  bool _initialized = false;
  bool _stopped = false;

  SyncPhase _phase = SyncPhase.idle;
  SyncReport? _lastReport;
  final _reportsController = StreamController<SyncReport>.broadcast();

  // Serializes syncOnce invocations (direct calls and auto triggers alike).
  Future<void> _chain = Future.value();

  // Compression flag of the cycle in flight, so an error report can still
  // carry compressionDetected.
  bool _cycleCompression = false;

  StreamSubscription<WatchEvent>? _watchSub;
  Timer? _debounce;
  Timer? _periodic;
  bool _autoActive = false;
  bool _autoSyncRunning = false;
  bool _autoSyncPending = false;

  SyncPhase get phase => _phase;

  SyncReport? get lastReport => _lastReport;

  /// Broadcast stream emitting one [SyncReport] per completed [syncOnce].
  Stream<SyncReport> get reports => _reportsController.stream;

  String get _lockPath => p.join(config.syncDir, 'lock');

  /// Creates the `.sync/{repo,staging,logs}` structure, initializes the bare
  /// repo, opens the index DB and takes the `.sync/lock` file.
  ///
  /// Throws [StateError] when another live process already holds the lock;
  /// a lock left behind by a dead process is taken over.
  Future<void> initialize() async {
    if (_initialized) return;
    await Directory(config.repoDir).create(recursive: true);
    await Directory(config.stagingDir).create(recursive: true);
    await Directory(config.logsDir).create(recursive: true);
    await _acquireLock();
    final git = GitRepo(
        gitDir: config.repoDir, remoteUrl: config.serverUrl, logger: _logger);
    await git.ensureInitialized();
    _git = git;
    _db = await IndexDb.open(config.dbPath);
    _initialized = true;
    _emit(LogLevel.info,
        'engine initialized (client ${config.clientId}, dir ${config.sharedDir})');
  }

  Future<void> _acquireLock() async {
    final lock = File(_lockPath);
    if (await lock.exists()) {
      final raw = (await lock.readAsString()).trim();
      final other = int.tryParse(raw);
      if (other != null && other != pid && await _pidAlive(other)) {
        throw StateError(
            'another sync instance (pid $other) holds ${lock.path}');
      }
      _emit(LogLevel.warn, 'taking over stale lock file (previous pid: $raw)');
    }
    await lock.writeAsString('$pid\n', flush: true);
  }

  // `kill -0` semantics: signal 0 probes process existence without touching it.
  static Future<bool> _pidAlive(int pid) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run(
            'tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
        return (r.stdout as String).contains('"$pid"');
      }
      final r = await Process.run('kill', ['-0', '$pid']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Runs one full sync cycle (DESIGN.md §2). Never throws; concurrent calls
  /// are queued so at most one cycle runs at a time.
  Future<SyncReport> syncOnce() {
    final result = _chain.then((_) => _syncOnceGuarded());
    _chain = result.then((_) {});
    return result;
  }

  Future<SyncReport> _syncOnceGuarded() async {
    final startedAt = DateTime.now();
    final sw = Stopwatch()..start();
    _cycleCompression = false;

    SyncReport finish(SyncReport report) {
      _lastReport = report;
      _phase = report.hasError ? SyncPhase.error : SyncPhase.idle;
      if (!_reportsController.isClosed) _reportsController.add(report);
      return report;
    }

    if (!_initialized) {
      return finish(SyncReport(
          startedAt: startedAt,
          duration: sw.elapsed,
          error: 'engine not initialized'));
    }
    try {
      return finish(await _runCycle(startedAt, sw));
    } catch (e, st) {
      // Requirements §17: error stack traces must be logged.
      _logger.error('sync cycle failed', e, st);
      onEvent?.call(SyncEvent(
          time: DateTime.now(),
          message: 'sync cycle failed: $e',
          level: LogLevel.error));
      return finish(SyncReport(
          startedAt: startedAt,
          duration: sw.elapsed,
          compressionDetected: _cycleCompression,
          error: '$e'));
    }
  }

  Future<SyncReport> _runCycle(DateTime startedAt, Stopwatch sw) async {
    final git = _git!;
    final db = _db!;

    var compression = false;
    String? remoteHead;
    String? pushedCommit;
    var uploaded = 0;
    late TreeState remote;
    late TreeState base;
    late LocalScanResult scan;
    late SyncPlan plan;
    // Paths in base/remote that match the current ignore rules. They are
    // routed through the planner's frozen mechanism so an ignored file never
    // participates in sync, conflict detection or delete propagation
    // (requirements §12) — remote keeps its copy, the local file and the base
    // entry stay untouched.
    var ignoredReconcile = <String>{};

    // The whole fetch→push sequence is redone on a rejected push or when an
    // upload source file changed under our feet (DESIGN §2 step 8c).
    for (var attempt = 0;; attempt++) {
      _phase = SyncPhase.fetching;
      remoteHead = await git.fetchCurrent();
      _emit(LogLevel.info,
          'fetch result: ${remoteHead ?? '(remote branch empty)'}');
      remote = remoteHead == null
          ? <String, FileEntry>{}
          : await git.readTree(remoteHead);

      final last = db.lastSyncedCommit;
      if (last != null &&
          (remoteHead == null || !await git.isAncestor(last, remoteHead))) {
        compression = true;
        _cycleCompression = true;
        // 日志带事件名 compressionDetected(DESIGN §2 步骤 3:记录
        // compressionDetected 事件日志),便于 e2e/运维 grep 识别。
        _emit(LogLevel.warn,
            'compressionDetected: 检测到服务端历史压缩,基于 index.db 基线安全重建');
      }

      _phase = SyncPhase.scanning;
      _emit(LogLevel.info, 'scan started');
      final ignore = await IgnoreMatcher.fromSharedDir(
          config.sharedDir, config.ignoreFileName);
      final scanner = Scanner(
          sharedDir: config.sharedDir,
          ignore: ignore,
          stableDelaySeconds: config.fileStableDelaySeconds,
          logger: _logger);
      scan = await scanner.scan(await db.statCache());
      base = await db.baseTree();

      // Requirements §12: a base/remote path matching the ignore rules (e.g.
      // a rule added after the file was synced) is frozen — no upload, no
      // download, no delete propagation, base entry kept as-is. The scanner
      // already prunes ignored paths, so L never contains them. Computed
      // before the change logs below so an ignored base path is not reported
      // as a (never propagated) local delete every cycle.
      ignoredReconcile = {
        for (final path in {...base.keys, ...remote.keys})
          if (ignore.isIgnored(path, isDir: false)) path,
      };
      if (ignoredReconcile.isNotEmpty) {
        final sample = (ignoredReconcile.toList()..sort()).take(5).join(', ');
        _emit(
            LogLevel.info,
            'ignored paths excluded from sync (§12): '
            '${ignoredReconcile.length} (e.g. $sample)');
      }

      _emit(
          LogLevel.info,
          'scan finished: ${scan.files.length} files, '
          '${scan.unstablePaths.length} unstable, '
          '${_countChanges(base, scan.files, ignoredReconcile)} '
          'local changes vs base');
      // Memory heads-up (DESIGN §21): every cycle rebuilds base/local/remote/
      // merged TreeStates proportional to the file count, with no upper bound.
      // Warn once per cycle when the union grows large so an operator can plan
      // for very large directories before memory pressure bites.
      final unionSize = {...base.keys, ...scan.files.keys, ...remote.keys}.length;
      if (unionSize > largeDirectoryWarnThreshold) {
        _emit(
            LogLevel.warn,
            '共享目录文件数较多($unionSize),每轮全量扫描内存占用随之上升,'
            '超大目录(十万级以上)建议拆分或评估专用方案');
      }
      // Requirements §17 "检测到的本地变化": one info line per local change.
      _logLocalChanges(base, scan.files, ignoredReconcile);

      // Frozen paths: plan with l := b so an unstable file neither uploads
      // nor receives any download/delete action this cycle.
      final local = Map.of(scan.files);
      for (final path in scan.unstablePaths) {
        final b = base[path];
        if (b != null) {
          local[path] = b;
        } else {
          local.remove(path);
        }
      }

      _phase = SyncPhase.planning;
      final now = DateTime.now();
      plan = planSync(
        base: base,
        local: local,
        remote: remote,
        frozenPaths: {...scan.unstablePaths, ...ignoredReconcile},
        conflictNamer: (originalPath, exists) => config.conflictCopyPath(
            originalPath,
            now,
            (c) => exists(c) || File(_abs(c)).existsSync()),
      );
      _emit(
          LogLevel.info,
          'plan result: downloads=${plan.downloads.length} '
          'localDeletes=${plan.localDeletes.length} '
          'conflictCopies=${plan.conflictCopies.length} '
          'deleteConflicts=${plan.deleteConflicts.length} '
          'pushNeeded=${plan.hasRemoteChanges}');

      if (!plan.hasRemoteChanges) break;

      _phase = SyncPhase.pushing;
      // §2 step 7: conflict copies hit the disk before push — their blobs
      // are part of the merged tree being committed.
      final copiesWritten = <String>[];
      var attemptUploads = 0;
      var abortRound = false;
      try {
        try {
          for (final c in plan.conflictCopies) {
            await _writeConflictCopy(c);
            copiesWritten.add(c.copyPath);
          }
          // Everything in the merged tree that the remote does not already
          // hold must come from a local file (scan result or conflict copy).
          for (final entry in plan.mergedTree.values) {
            if (remote[entry.path]?.sameContent(entry) ?? false) continue;
            final abs = _abs(entry.path);
            final scanStat = scan.stats[entry.path];
            if (scanStat != null && await _changedSinceScan(abs, scanStat)) {
              _emit(LogLevel.warn,
                  'file changed during sync, restarting cycle: ${entry.path}');
              abortRound = true;
              break;
            }
            final sha = await git.writeBlob(abs);
            if (sha != entry.hash) {
              // Conflict copies have no scan stat; the sha check catches a
              // source file that changed between scan and copy.
              _emit(LogLevel.warn,
                  'content changed while uploading ${entry.path}, restarting cycle');
              abortRound = true;
              break;
            }
            attemptUploads++;
          }
        } on FileSystemException catch (e) {
          _emit(LogLevel.warn,
              'file vanished/changed during upload, restarting cycle: ${e.message}');
          abortRound = true;
        }

        if (!abortRound) {
          final commit = await git.commitTree(
            plan.mergedTree,
            parents: [if (remoteHead != null) remoteHead],
            message: 'sync from ${config.clientId} '
                'at ${DateTime.now().toUtc().toIso8601String()}',
          );
          if (await git.pushCurrent(commit)) {
            pushedCommit = commit;
            uploaded = attemptUploads;
            _emit(LogLevel.info,
                'push result: ok $commit ($attemptUploads blobs uploaded)');
            break;
          }
          _emit(LogLevel.warn, 'push result: rejected (non-fast-forward)');
        }
      } on GitException {
        // A hard push-phase failure aborts the whole cycle: remove this
        // round's conflict copies so they don't linger and get duplicated
        // next cycle. Their content comes from local files that are still
        // untouched, so deleting the copies loses nothing — the next cycle
        // replans and rewrites them.
        await _removeFiles(copiesWritten);
        rethrow;
      }

      // Round abandoned: remove the conflict copies written this round (the
      // originals are still untouched) so the retry replans from scratch
      // without duplicating copies.
      await _removeFiles(copiesWritten);
      if (attempt >= config.maxPushRetries) {
        throw StateError(
            'gave up after ${attempt + 1} attempts (push rejected or local '
            'files kept changing); will retry next cycle');
      }
    }

    // ---- Apply phase: all writes to the working directory. ----
    _phase = SyncPhase.applying;
    final newStats = Map<String, CachedStat>.of(scan.stats);

    // Backups of everything about to be overwritten or deleted (always done;
    // mandatory under compression — same code path). Taken lazily right
    // before each destructive action so paths skipped by the safety recheck
    // (e.g. a case-collision retried every cycle) do not pile up one backup
    // directory per cycle.
    final backupDir =
        p.join(config.stagingDir, 'backup-${_utcCompact(DateTime.now())}');
    var backedUp = 0;
    Future<void> backup(String rel) async {
      final src = File(_abs(rel));
      if (!await src.exists()) return;
      final dest = File(p.joinAll([backupDir, ...rel.split('/')]));
      await dest.parent.create(recursive: true);
      await src.copy(dest.path);
      backedUp++;
    }

    // Record fresh stats for the conflict copies written before push.
    for (final c in plan.conflictCopies) {
      final st = await _statOrNull(_abs(c.copyPath));
      if (st != null) {
        newStats[c.copyPath] = CachedStat(
            size: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch,
            hash: c.localHash,
            mode: c.mode);
      }
    }

    // Paths whose planned download / localDelete was *not* applied: their
    // base entry must not advance either (see computeBaseToStore), or the
    // next cycle would mistake the never-materialized remote state for an
    // already-seen one and turn local content into a phantom delete/overwrite.
    final skippedPaths = <String>{};

    // Case-collision diagnosis: on a case-insensitive filesystem two remote
    // paths differing only in letter case map to one on-disk file. The safety
    // recheck below skips the second download anyway (stat hits the other
    // file); this map turns that into an explicit warning and is extended
    // with each completed download to catch two new colliding remote files.
    final lowercaseToPath = <String, String>{
      for (final path in scan.files.keys) path.toLowerCase(): path,
    };

    void warnSkipped(String path) {
      final other = lowercaseToPath[path.toLowerCase()];
      if (other != null && other != path) {
        _emit(LogLevel.warn,
            '大小写不敏感文件系统路径碰撞,文件未同步到本地: $path 与 $other(远端两个文件均保留)');
      } else {
        _emit(LogLevel.warn, '文件在同步期间被修改,顺延到下一轮: $path');
      }
    }

    // Downloads: staging tmp file + atomic rename into place.
    final tmpDir = Directory(p.join(config.stagingDir, 'tmp'));
    await tmpDir.create(recursive: true);
    var downloaded = 0;
    var tmpSeq = 0;
    for (final d in plan.downloads) {
      final abs = _abs(d.path);
      if (await _unsafeToTouch(abs, scan.stats[d.path])) {
        skippedPaths.add(d.path);
        warnSkipped(d.path);
        continue;
      }
      final tmpPath =
          p.join(tmpDir.path, '${tmpSeq++}-${p.posix.basename(d.path)}');
      await _git!.catBlobToFile(d.hash, tmpPath);
      await _applyMode(tmpPath, d.mode);
      // Backup, then a second safety recheck right before the rename:
      // catBlobToFile (and the backup copy) may take a long time for large
      // files, and an edit (or a file appearing at a path the scan saw as
      // absent) inside that window must never be overwritten — rechecking
      // after the backup keeps the unguarded window at rename-only size.
      await backup(d.path);
      if (await _unsafeToTouch(abs, scan.stats[d.path])) {
        skippedPaths.add(d.path);
        try {
          await File(tmpPath).delete();
        } catch (_) {}
        warnSkipped(d.path);
        continue;
      }
      await File(abs).parent.create(recursive: true);
      await File(tmpPath).rename(abs);
      downloaded++;
      lowercaseToPath[d.path.toLowerCase()] = d.path;
      final st = await _statOrNull(abs);
      if (st != null) {
        newStats[d.path] = CachedStat(
            size: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch,
            hash: d.hash,
            mode: d.mode);
      }
      _emit(LogLevel.info, 'downloaded: ${d.path}');
    }

    // Local deletes, with the same safety recheck, then bottom-up cleanup of
    // directories the deletes emptied.
    var deletedLocal = 0;
    final dirsToPrune = <String>{};
    for (final rel in plan.localDeletes) {
      final abs = _abs(rel);
      final st = await _statOrNull(abs);
      if (st == null) continue; // already gone
      final scanStat = scan.stats[rel];
      if (scanStat == null ||
          st.size != scanStat.size ||
          st.modified.millisecondsSinceEpoch != scanStat.mtimeMs) {
        skippedPaths.add(rel);
        _emit(LogLevel.warn, '文件在同步期间被修改,顺延到下一轮: $rel');
        continue;
      }
      // Backup, then recheck so an edit made while the backup copy was
      // running is still caught before the delete.
      await backup(rel);
      if (await _unsafeToTouch(abs, scanStat)) {
        skippedPaths.add(rel);
        _emit(LogLevel.warn, '文件在同步期间被修改,顺延到下一轮: $rel');
        continue;
      }
      await File(abs).delete();
      deletedLocal++;
      dirsToPrune.add(p.dirname(abs));
      _emit(LogLevel.info, 'deleted locally: $rel');
    }
    for (final dir in dirsToPrune) {
      await _pruneEmptyDirs(dir);
    }
    if (backedUp > 0) {
      _emit(LogLevel.info,
          'recovery: backed up $backedUp files to be overwritten/deleted into $backupDir');
    }

    // §2 step 10: conflict records.
    final records = <ConflictRecord>[];
    final recordTime = DateTime.now();
    for (final c in plan.conflictCopies) {
      final kind = !plan.mergedTree.containsKey(c.originalPath)
          ? 'delete' // local modify vs remote delete
          : (base.containsKey(c.originalPath) ? 'modify' : 'create');
      records.add(ConflictRecord(
          time: recordTime,
          kind: kind,
          path: c.originalPath,
          copyPath: c.copyPath,
          clientId: config.clientId));
    }
    for (final dc in plan.deleteConflicts) {
      records.add(ConflictRecord(
          time: recordTime,
          kind: 'delete',
          path: dc.path,
          copyPath: null,
          clientId: config.clientId));
    }
    if (records.isNotEmpty) {
      final sink = StringBuffer();
      for (final r in records) {
        sink.writeln(jsonEncode(r.toJson()));
        _emit(LogLevel.warn,
            'conflict (${r.kind}): ${r.path}${r.copyPath == null ? '' : ' -> ${r.copyPath}'}');
      }
      await File(config.conflictsPath)
          .writeAsString(sink.toString(), mode: FileMode.append, flush: true);
    }

    // §2 step 11: advance the base — but every path whose local state was
    // not brought in line with mergedTree this cycle (frozen/unstable,
    // apply-phase skips, §12 ignored reconcile) keeps its old base value so
    // the next cycle re-evaluates it against an un-advanced base.
    final baseToStore = computeBaseToStore(plan.mergedTree, base,
        {...scan.unstablePaths, ...skippedPaths, ...ignoredReconcile});
    final commitForDb = pushedCommit ?? remoteHead;
    await db.replaceBase(baseToStore, commitForDb, newStats);

    // §2 step 12: staging hygiene + log retention (drop daily logs older than
    // config.logRetentionDays so a long-running / offline client does not
    // accumulate logs without bound).
    await _cleanupStaging();
    await _logger.cleanupOldLogs(config.logRetentionDays);
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}

    final deletedRemote = pushedCommit == null
        ? 0
        : remote.keys.where((k) => !plan.mergedTree.containsKey(k)).length;

    return SyncReport(
      startedAt: startedAt,
      duration: sw.elapsed,
      uploaded: uploaded,
      downloaded: downloaded,
      deletedLocal: deletedLocal,
      deletedRemote: deletedRemote,
      conflicts: records,
      compressionDetected: compression,
      pushedCommit: pushedCommit,
    );
  }

  /// Starts auto mode: a [DirectoryWatcher] (debounced by
  /// `fileStableDelaySeconds`) plus a periodic timer every
  /// `syncIntervalSeconds`. Only one cycle runs at a time; a trigger during a
  /// running cycle marks it pending and one more cycle runs afterwards.
  Future<void> startAuto() async {
    if (!_initialized) throw StateError('initialize() must be called first');
    if (_autoActive || _stopped) return;
    _autoActive = true;
    final ignore = await IgnoreMatcher.fromSharedDir(
        config.sharedDir, config.ignoreFileName);
    final watcher = DirectoryWatcher(config.sharedDir);
    _watchSub = watcher.events.listen((event) {
      final rel = _relOf(event.path);
      if (rel == null || rel == '.sync' || rel.startsWith('.sync/')) return;
      if (ignore.isIgnored(rel, isDir: false)) return;
      _debounce?.cancel();
      _debounce = Timer(
          Duration(seconds: config.fileStableDelaySeconds), _requestSync);
    }, onError: (Object e) {
      _emit(LogLevel.warn, 'watcher error: $e');
    });
    _periodic = Timer.periodic(
        Duration(seconds: config.syncIntervalSeconds), (_) => _requestSync());
    await watcher.ready;
    _emit(LogLevel.info,
        'auto sync started (watcher + ${config.syncIntervalSeconds}s timer)');
  }

  void _requestSync() {
    if (_stopped) return;
    if (_autoSyncRunning) {
      _autoSyncPending = true;
      return;
    }
    _autoSyncRunning = true;
    unawaited(() async {
      try {
        do {
          _autoSyncPending = false;
          await syncOnce();
        } while (_autoSyncPending && !_stopped);
      } finally {
        _autoSyncRunning = false;
      }
    }());
  }

  /// Stops auto mode, waits for an in-flight cycle, closes the DB, releases
  /// the lock and closes an internally created logger. Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _debounce?.cancel();
    _periodic?.cancel();
    await _watchSub?.cancel();
    _watchSub = null;
    _autoActive = false;
    await _chain; // let an in-flight cycle finish cleanly
    if (!_reportsController.isClosed) await _reportsController.close();
    _db?.close();
    _db = null;
    _initialized = false;
    try {
      final lock = File(_lockPath);
      if (await lock.exists() &&
          (await lock.readAsString()).trim() == '$pid') {
        await lock.delete();
      }
    } catch (_) {}
    _logger.info('engine stopped');
    if (_ownsLogger) _logger.close();
  }

  /// Last [limit] records of `.sync/conflicts.jsonl` in file (chronological)
  /// order. Malformed lines are skipped.
  Future<List<ConflictRecord>> recentConflicts({int limit = 100}) async {
    final file = File(config.conflictsPath);
    if (!await file.exists()) return const [];
    final lines = await file.readAsLines();
    final records = <ConflictRecord>[];
    for (final line in lines.reversed) {
      if (records.length >= limit) break;
      if (line.trim().isEmpty) continue;
      try {
        records.add(ConflictRecord.fromJson(
            jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // Skip malformed lines; the file is append-only best effort.
      }
    }
    return records.reversed.toList();
  }

  // ---- helpers ----

  void _emit(LogLevel level, String message) {
    _logger.log(level, message);
    onEvent?.call(
        SyncEvent(time: DateTime.now(), message: message, level: level));
  }

  String _abs(String rel) =>
      p.joinAll([config.sharedDir, ...rel.split('/')]);

  String? _relOf(String absPath) {
    if (!p.isWithin(config.sharedDir, absPath)) return null;
    return p.split(p.relative(absPath, from: config.sharedDir)).join('/');
  }

  static int _countChanges(
      TreeState base, TreeState local, Set<String> exclude) {
    var n = 0;
    for (final key in {...base.keys, ...local.keys}) {
      if (exclude.contains(key)) continue;
      final b = base[key];
      final l = local[key];
      final same = b == null ? l == null : l != null && b.sameContent(l);
      if (!same) n++;
    }
    return n;
  }

  /// Requirements §17: one info line per detected local change vs base
  /// (added / modified / deleted), capped to keep huge first syncs readable.
  /// [exclude] holds the §12 ignored paths — absent from the scan by design,
  /// not user deletions.
  void _logLocalChanges(TreeState base, TreeState local, Set<String> exclude) {
    const maxLines = 200;
    var logged = 0;
    var suppressed = 0;
    final paths = {...base.keys, ...local.keys}.toList()..sort();
    for (final path in paths) {
      if (exclude.contains(path)) continue;
      final b = base[path];
      final l = local[path];
      if (b == null ? l == null : l != null && b.sameContent(l)) continue;
      if (logged >= maxLines) {
        suppressed++;
        continue;
      }
      final kind = b == null ? 'added' : (l == null ? 'deleted' : 'modified');
      _emit(LogLevel.info, 'local change: $kind $path');
      logged++;
    }
    if (suppressed > 0) {
      _emit(LogLevel.info,
          'local change: ... and $suppressed more (logging capped at $maxLines)');
    }
  }

  Future<FileStat?> _statOrNull(String absPath) async {
    final st = await File(absPath).stat();
    return st.type == FileSystemEntityType.notFound ? null : st;
  }

  /// True when [absPath] no longer matches what the scan saw — including a
  /// file that appeared at a path the scan saw as absent (never overwrite
  /// content the planner has not seen).
  Future<bool> _unsafeToTouch(String absPath, CachedStat? scanStat) async {
    final st = await _statOrNull(absPath);
    if (scanStat == null) return st != null;
    return st == null ||
        st.size != scanStat.size ||
        st.modified.millisecondsSinceEpoch != scanStat.mtimeMs;
  }

  Future<bool> _changedSinceScan(String absPath, CachedStat scanStat) async {
    final st = await _statOrNull(absPath);
    return st == null ||
        st.size != scanStat.size ||
        st.modified.millisecondsSinceEpoch != scanStat.mtimeMs;
  }

  Future<void> _writeConflictCopy(ConflictCopy c) async {
    final src = File(_abs(c.originalPath));
    final dest = File(_abs(c.copyPath));
    await dest.parent.create(recursive: true);
    await src.copy(dest.path);
    await _applyMode(dest.path, c.mode);
    _emit(LogLevel.info,
        'conflict copy written: ${c.originalPath} -> ${c.copyPath}');
  }

  Future<void> _applyMode(String absPath, EntryMode mode) async {
    if (Platform.isWindows || mode != EntryMode.executable) return;
    await Process.run('chmod', ['+x', absPath]);
  }

  Future<void> _removeFiles(List<String> relPaths) async {
    for (final rel in relPaths) {
      try {
        await File(_abs(rel)).delete();
      } catch (_) {}
    }
  }

  /// Removes directories emptied by deletions, walking up but never crossing
  /// the shared root and never touching `.sync`.
  Future<void> _pruneEmptyDirs(String dirAbs) async {
    var dir = dirAbs;
    while (p.isWithin(config.sharedDir, dir) &&
        !p.equals(dir, config.syncDir) &&
        !p.isWithin(config.syncDir, dir)) {
      try {
        final d = Directory(dir);
        if (!await d.exists()) {
          dir = p.dirname(dir);
          continue;
        }
        if (await d.list(followLinks: false).isEmpty) {
          await d.delete();
          _emit(LogLevel.info, 'removed empty dir: ${_relOf(dir) ?? dir}');
          dir = p.dirname(dir);
        } else {
          break;
        }
      } on FileSystemException {
        break;
      }
    }
  }

  /// Deletes `staging/backup-*` directories older than 7 days.
  Future<void> _cleanupStaging() async {
    final staging = Directory(config.stagingDir);
    if (!await staging.exists()) return;
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 7));
    await for (final entity in staging.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('backup-')) continue;
      final stamp = DateTime.tryParse(name.substring('backup-'.length)) ??
          (await entity.stat()).modified.toUtc();
      if (stamp.isBefore(cutoff)) {
        try {
          await entity.delete(recursive: true);
          _emit(LogLevel.info, 'staging cleanup: removed old $name');
        } catch (_) {}
      }
    }
  }

  // Compact UTC ISO timestamp (`20260613T101530Z`) — parseable by
  // `DateTime.parse` and free of characters illegal in file names.
  static String _utcCompact(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
        'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }
}
