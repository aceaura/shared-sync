/// Local sync index backed by SQLite. See DESIGN.md §4.5.
///
/// Stores the base tree (B) of the last successful sync cycle plus the stat
/// cache used by the scanner to skip re-hashing unchanged files. The database
/// is derived data: losing it only forces a full re-scan / three-way replan,
/// never data loss.
library;

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

/// Persistent index database (`<sharedDir>/.sync/index.db`).
///
/// All write operations are synchronous under the hood (sqlite3 FFI) but the
/// API is async-shaped per the design contract. The database must only be
/// updated via [replaceBase] after a fully successful sync cycle (DESIGN.md
/// core decision 5).
class IndexDb {
  IndexDb._(this._db, this._lastSyncedCommit);

  final Database _db;
  String? _lastSyncedCommit;

  static const _schemaVersion = '1';
  static const _lastSyncedCommitKey = 'last_synced_commit';
  static const _schemaVersionKey = 'schema_version';

  /// Opens (creating if necessary) the database at [dbPath].
  ///
  /// Schema creation is idempotent. On a schema version mismatch the tables
  /// are dropped and recreated — the index is a cache, rebuilding it merely
  /// costs one full re-hash cycle.
  static Future<IndexDb> open(String dbPath) async {
    final db = sqlite3.open(dbPath);
    try {
      _ensureSchema(db);
      return IndexDb._(db, _readMeta(db, _lastSyncedCommitKey));
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  static void _ensureSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT
      );
    ''');
    final version = _readMeta(db, _schemaVersionKey);
    if (version != null && version != _schemaVersion) {
      db.execute('DROP TABLE IF EXISTS entries');
      db.execute('DELETE FROM meta');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS entries (
        path               TEXT PRIMARY KEY,
        content_hash       TEXT,
        size               INTEGER,
        mtime_ms           INTEGER,
        mode               INTEGER,
        last_synced_commit TEXT,
        deleted            INTEGER DEFAULT 0,
        last_seen_at       INTEGER
      );
    ''');
    _writeMeta(db, _schemaVersionKey, _schemaVersion);
  }

  static String? _readMeta(Database db, String key) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static void _writeMeta(Database db, String key, String value) {
    db.execute(
      'INSERT INTO meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  /// The base tree B of the last successful sync (rows with `deleted = 0`).
  Future<TreeState> baseTree() async {
    final rows = _db.select(
      'SELECT path, content_hash, mode FROM entries WHERE deleted = 0',
    );
    final tree = <String, FileEntry>{};
    for (final row in rows) {
      final path = row['path'] as String;
      tree[path] = FileEntry(
        path: path,
        hash: row['content_hash'] as String,
        mode: _modeFromInt(row['mode'] as int),
      );
    }
    return tree;
  }

  /// Stat cache for the scanner: path -> size/mtime/hash of the last sync.
  ///
  /// Rows stored with size 0 / mtime 0 (see [replaceBase]) never match a real
  /// file stat, which forces a re-hash on the next scan.
  Future<Map<String, CachedStat>> statCache() async {
    final rows = _db.select(
      'SELECT path, content_hash, size, mtime_ms, mode FROM entries '
      'WHERE deleted = 0',
    );
    final cache = <String, CachedStat>{};
    for (final row in rows) {
      cache[row['path'] as String] = CachedStat(
        size: row['size'] as int,
        mtimeMs: row['mtime_ms'] as int,
        hash: row['content_hash'] as String,
        mode: _modeFromInt(row['mode'] as int),
      );
    }
    return cache;
  }

  /// Commit sha of the last successfully synced remote snapshot, or null
  /// before the first successful sync.
  String? get lastSyncedCommit => _lastSyncedCommit;

  /// Persists [commit] (null clears it, e.g. before the first sync).
  Future<void> setLastSyncedCommit(String? commit) async {
    if (commit == null) {
      _db.execute('DELETE FROM meta WHERE key = ?', [_lastSyncedCommitKey]);
    } else {
      _writeMeta(_db, _lastSyncedCommitKey, commit);
    }
    _lastSyncedCommit = commit;
  }

  /// Atomically replaces the whole base tree and updates [lastSyncedCommit].
  ///
  /// Called exactly once per successful sync cycle. Paths missing from
  /// [stats] — or whose cached hash does not match the tree entry (e.g. a
  /// remote-won conflict where the local file still holds the old content) —
  /// are stored with size/mtime 0 so the next scan re-hashes them instead of
  /// trusting a stale cache.
  Future<void> replaceBase(
    TreeState tree,
    String? commit,
    Map<String, CachedStat> stats,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('DELETE FROM entries');
      final insert = _db.prepare(
        'INSERT INTO entries '
        '(path, content_hash, size, mtime_ms, mode, last_synced_commit, '
        ' deleted, last_seen_at) '
        'VALUES (?, ?, ?, ?, ?, ?, 0, ?)',
      );
      try {
        for (final entry in tree.values) {
          final stat = stats[entry.path];
          final statUsable = stat != null &&
              stat.hash == entry.hash &&
              stat.mode == entry.mode;
          insert.execute([
            entry.path,
            entry.hash,
            statUsable ? stat.size : 0,
            statUsable ? stat.mtimeMs : 0,
            _modeToInt(entry.mode),
            commit,
            now,
          ]);
        }
      } finally {
        insert.dispose();
      }
      if (commit == null) {
        _db.execute('DELETE FROM meta WHERE key = ?', [_lastSyncedCommitKey]);
      } else {
        _writeMeta(_db, _lastSyncedCommitKey, commit);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _lastSyncedCommit = commit;
  }

  /// Reads an arbitrary metadata value, or null when absent.
  Future<String?> getMeta(String key) async => _readMeta(_db, key);

  /// Writes an arbitrary metadata value (upsert).
  Future<void> setMeta(String key, String value) async =>
      _writeMeta(_db, key, value);

  /// Closes the database. The instance must not be used afterwards.
  void close() => _db.dispose();

  // Modes are stored as the git tree mode number (100644 / 100755) so the
  // raw database remains self-describing.
  static int _modeToInt(EntryMode mode) =>
      mode == EntryMode.executable ? 100755 : 100644;

  static EntryMode _modeFromInt(int mode) =>
      mode == 100755 ? EntryMode.executable : EntryMode.regular;
}
