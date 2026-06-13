import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_engine/src/index_db.dart';
import 'package:sync_engine/src/models.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late IndexDb db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('index_db_test_');
    dbPath = p.join(tempDir.path, 'index.db');
    db = await IndexDb.open(dbPath);
  });

  tearDown(() async {
    db.close();
    await tempDir.delete(recursive: true);
  });

  FileEntry entry(String path, String hash,
          [EntryMode mode = EntryMode.regular]) =>
      FileEntry(path: path, hash: hash, mode: mode);

  // 40-hex fake blob shas.
  final hashA = 'a' * 40;
  final hashB = 'b' * 40;
  final hashC = 'c' * 40;

  test('empty database: baseTree/statCache empty, lastSyncedCommit null',
      () async {
    expect(await db.baseTree(), isEmpty);
    expect(await db.statCache(), isEmpty);
    expect(db.lastSyncedCommit, isNull);
  });

  test('replaceBase round-trips baseTree and statCache', () async {
    final tree = <String, FileEntry>{
      'a.txt': entry('a.txt', hashA),
      'dir/b.sh': entry('dir/b.sh', hashB, EntryMode.executable),
    };
    final stats = {
      'a.txt': CachedStat(
          size: 5, mtimeMs: 111, hash: hashA, mode: EntryMode.regular),
      'dir/b.sh': CachedStat(
          size: 9, mtimeMs: 222, hash: hashB, mode: EntryMode.executable),
    };
    await db.replaceBase(tree, 'commit1', stats);

    final base = await db.baseTree();
    expect(base.length, 2);
    expect(base['a.txt'], tree['a.txt']);
    expect(base['dir/b.sh'], tree['dir/b.sh']);
    expect(base['dir/b.sh']!.mode, EntryMode.executable);

    final cache = await db.statCache();
    expect(cache.length, 2);
    expect(cache['a.txt']!.size, 5);
    expect(cache['a.txt']!.mtimeMs, 111);
    expect(cache['a.txt']!.hash, hashA);
    expect(cache['a.txt']!.mode, EntryMode.regular);
    expect(cache['dir/b.sh']!.size, 9);
    expect(cache['dir/b.sh']!.mtimeMs, 222);
    expect(cache['dir/b.sh']!.mode, EntryMode.executable);

    expect(db.lastSyncedCommit, 'commit1');
  });

  test('second replaceBase fully replaces previous entries', () async {
    await db.replaceBase(
      {'old.txt': entry('old.txt', hashA)},
      'commit1',
      {
        'old.txt': CachedStat(
            size: 1, mtimeMs: 1, hash: hashA, mode: EntryMode.regular),
      },
    );
    await db.replaceBase(
      {'new.txt': entry('new.txt', hashB)},
      'commit2',
      {
        'new.txt': CachedStat(
            size: 2, mtimeMs: 2, hash: hashB, mode: EntryMode.regular),
      },
    );

    final base = await db.baseTree();
    expect(base.keys, ['new.txt']);
    expect((await db.statCache()).keys, ['new.txt']);
    expect(db.lastSyncedCommit, 'commit2');
  });

  test('replaceBase stores size/mtime 0 when stat is missing or stale',
      () async {
    final tree = <String, FileEntry>{
      'missing.txt': entry('missing.txt', hashA),
      'stale.txt': entry('stale.txt', hashB),
    };
    // stale.txt: cached stat belongs to different content (hash mismatch),
    // must not be trusted next round.
    final stats = {
      'stale.txt': CachedStat(
          size: 7, mtimeMs: 777, hash: hashC, mode: EntryMode.regular),
    };
    await db.replaceBase(tree, 'commit1', stats);

    final cache = await db.statCache();
    expect(cache['missing.txt']!.size, 0);
    expect(cache['missing.txt']!.mtimeMs, 0);
    expect(cache['missing.txt']!.hash, hashA);
    expect(cache['stale.txt']!.size, 0);
    expect(cache['stale.txt']!.mtimeMs, 0);
    // The cache hash always reflects the base tree, never the stale stat.
    expect(cache['stale.txt']!.hash, hashB);
  });

  test('lastSyncedCommit set/get/null', () async {
    expect(db.lastSyncedCommit, isNull);
    await db.setLastSyncedCommit('abc123');
    expect(db.lastSyncedCommit, 'abc123');
    await db.setLastSyncedCommit(null);
    expect(db.lastSyncedCommit, isNull);

    // replaceBase with null commit also clears it.
    await db.setLastSyncedCommit('abc123');
    await db.replaceBase({}, null, {});
    expect(db.lastSyncedCommit, isNull);
  });

  test('meta key/value store', () async {
    expect(await db.getMeta('foo'), isNull);
    await db.setMeta('foo', 'bar');
    expect(await db.getMeta('foo'), 'bar');
    await db.setMeta('foo', 'baz');
    expect(await db.getMeta('foo'), 'baz');
    expect(await db.getMeta('other'), isNull);
  });

  test('data survives close and reopen', () async {
    final tree = <String, FileEntry>{
      'keep.txt': entry('keep.txt', hashA, EntryMode.executable),
    };
    await db.replaceBase(tree, 'commit9', {
      'keep.txt': CachedStat(
          size: 42, mtimeMs: 999, hash: hashA, mode: EntryMode.executable),
    });
    await db.setMeta('custom', 'value');
    db.close();

    db = await IndexDb.open(dbPath);
    expect(db.lastSyncedCommit, 'commit9');
    final base = await db.baseTree();
    expect(base['keep.txt'], tree['keep.txt']);
    final cache = await db.statCache();
    expect(cache['keep.txt']!.size, 42);
    expect(cache['keep.txt']!.mtimeMs, 999);
    expect(cache['keep.txt']!.mode, EntryMode.executable);
    expect(await db.getMeta('custom'), 'value');
  });

  test('open is idempotent on an existing database', () async {
    await db.replaceBase({'x.txt': entry('x.txt', hashA)}, 'c1', {});
    db.close();
    db = await IndexDb.open(dbPath);
    db.close();
    db = await IndexDb.open(dbPath);
    expect((await db.baseTree()).keys, ['x.txt']);
    expect(db.lastSyncedCommit, 'c1');
  });
}
