/// Real integration tests for the sync engine orchestrator: two clients
/// against a local `file://` bare remote with `receive.denyNonFastForwards`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

Future<String> rawGit(List<String> args) async {
  final r = await Process.run('git', args,
      environment: {'GIT_TERMINAL_PROMPT': '0', 'LC_ALL': 'C'});
  if (r.exitCode != 0) {
    fail('raw git $args failed: ${r.stderr}');
  }
  return (r.stdout as String).trim();
}

void main() {
  late Directory tmp;
  late String serverDir;
  late String dirA;
  late String dirB;
  late SyncEngine a;
  late SyncEngine b;
  final loggers = <SyncLogger>[];

  SyncEngine makeEngine(String sharedDir, String clientId) {
    final config = SyncConfig(
      sharedDir: sharedDir,
      serverUrl: 'file://$serverDir',
      clientId: clientId,
      // 0 so freshly written test files are never frozen as "unstable".
      fileStableDelaySeconds: 0,
      syncIntervalSeconds: 3600,
    );
    final logger = SyncLogger(config.logsDir, alsoConsole: false);
    loggers.add(logger);
    return SyncEngine(config, logger: logger);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync-engine-test-');
    serverDir = p.join(tmp.path, 'server.git');
    await rawGit(['init', '--bare', '--quiet', serverDir]);
    await rawGit([
      '--git-dir=$serverDir',
      'config',
      'receive.denyNonFastForwards',
      'true'
    ]);
    dirA = p.join(tmp.path, 'pcA');
    dirB = p.join(tmp.path, 'pcB');
    await Directory(dirA).create();
    await Directory(dirB).create();
    a = makeEngine(dirA, 'PC-A');
    b = makeEngine(dirB, 'PC-B');
    await a.initialize();
    await b.initialize();
  });

  tearDown(() async {
    await a.stop();
    await b.stop();
    for (final logger in loggers) {
      logger.close();
    }
    loggers.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> write(String dir, String rel, String content) async {
    final file = File(p.joinAll([dir, ...rel.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
  }

  Future<String> read(String dir, String rel) =>
      File(p.joinAll([dir, ...rel.split('/')])).readAsString();

  bool exists(String dir, String rel) =>
      File(p.joinAll([dir, ...rel.split('/')])).existsSync();

  /// rel path -> content for the whole shared dir, excluding `.sync`.
  Future<Map<String, String>> snapshot(String dir) async {
    final result = <String, String>{};
    await for (final entity
        in Directory(dir).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel =
          p.split(p.relative(entity.path, from: dir)).join('/');
      if (rel == '.sync' || rel.startsWith('.sync/')) continue;
      result[rel] = await entity.readAsString();
    }
    return result;
  }

  Future<SyncReport> syncOk(SyncEngine engine) async {
    final report = await engine.syncOnce();
    expect(report.error, isNull,
        reason: 'sync must succeed, got: ${report.error}');
    return report;
  }

  Future<List<String>> remotePaths() async {
    final out = await rawGit(
        ['--git-dir=$serverDir', 'ls-tree', '-r', '--name-only', 'current']);
    return out.isEmpty ? const [] : out.split('\n');
  }

  test('1. file created on A becomes visible on B', () async {
    await write(dirA, 'docs/hello.txt', 'hello from A\n');
    final ra = await syncOk(a);
    expect(ra.uploaded, 1);
    expect(ra.pushedCommit, isNotNull);

    final rb = await syncOk(b);
    expect(rb.downloaded, 1);
    expect(await read(dirB, 'docs/hello.txt'), 'hello from A\n');
  });

  test('2. modification on B propagates back to A', () async {
    await write(dirA, 'note.txt', 'v1');
    await syncOk(a);
    await syncOk(b);

    await write(dirB, 'note.txt', 'v2 from B');
    await syncOk(b);
    final ra = await syncOk(a);
    expect(ra.downloaded, 1);
    expect(await read(dirA, 'note.txt'), 'v2 from B');
  });

  test('3. deletion on A propagates to B (incl. empty dir cleanup)', () async {
    await write(dirA, 'sub/dir/gone.txt', 'bye');
    await write(dirA, 'keep.txt', 'stay');
    await syncOk(a);
    await syncOk(b);
    expect(exists(dirB, 'sub/dir/gone.txt'), isTrue);

    await File(p.join(dirA, 'sub', 'dir', 'gone.txt')).delete();
    final ra = await syncOk(a);
    expect(ra.deletedRemote, 1);

    final rb = await syncOk(b);
    expect(rb.deletedLocal, 1);
    expect(exists(dirB, 'sub/dir/gone.txt'), isFalse);
    // Emptied directories are pruned bottom-up, but never the shared root.
    expect(Directory(p.join(dirB, 'sub')).existsSync(), isFalse);
    expect(await read(dirB, 'keep.txt'), 'stay');
  });

  test('4. concurrent edits of the same file -> conflict copy, '
      'original holds first pusher content, both sides converge', () async {
    await write(dirA, 'report.txt', 'base');
    await syncOk(a);
    await syncOk(b);

    await write(dirA, 'report.txt', 'edited on A');
    await write(dirB, 'report.txt', 'edited on B');

    await syncOk(a); // A pushes first: remote = A's content
    final rb = await syncOk(b); // B detects the modify conflict
    expect(rb.conflicts, hasLength(1));
    expect(rb.conflicts.single.kind, 'modify');
    expect(rb.conflicts.single.path, 'report.txt');
    final copyPath = rb.conflicts.single.copyPath;
    expect(copyPath, isNotNull);
    expect(copyPath, contains('conflict from PC-B'));
    await syncOk(a); // A downloads B's conflict copy

    final snapA = await snapshot(dirA);
    final snapB = await snapshot(dirB);
    expect(snapA, equals(snapB));
    // Original path keeps the first pusher's (A) content.
    expect(snapA['report.txt'], 'edited on A');
    expect(snapA[copyPath], 'edited on B');

    // The conflict is also persisted in conflicts.jsonl on B.
    final records = await b.recentConflicts(limit: 10);
    expect(records, isNotEmpty);
    expect(records.last.path, 'report.txt');
  });

  test('5. A deletes x while B modifies x (B pushes first) -> '
      'x survives with B content, delete-conflict recorded', () async {
    await write(dirA, 'x.txt', 'v1');
    await syncOk(a);
    await syncOk(b);

    await File(p.join(dirA, 'x.txt')).delete();
    await write(dirB, 'x.txt', 'v2 from B');

    await syncOk(b); // B pushes its modification
    final ra = await syncOk(a); // A: local delete vs remote modify
    expect(ra.conflicts, hasLength(1));
    expect(ra.conflicts.single.kind, 'delete');
    expect(ra.conflicts.single.path, 'x.txt');
    expect(ra.conflicts.single.copyPath, isNull);
    expect(ra.downloaded, 1);

    await syncOk(b);
    expect(await read(dirA, 'x.txt'), 'v2 from B');
    expect(await read(dirB, 'x.txt'), 'v2 from B');
  });

  test('6. server-side history compression: nothing is lost and '
      'compressionDetected is reported', () async {
    await write(dirA, 'one.txt', 'first');
    await write(dirA, 'two.txt', 'second');
    await syncOk(a);
    await syncOk(b);

    // Simulate scripts/compress.sh: a new parentless commit with the very
    // same tree replaces the branch head.
    final old = await rawGit(['--git-dir=$serverDir', 'rev-parse', 'current']);
    final tree =
        await rawGit(['--git-dir=$serverDir', 'rev-parse', 'current^{tree}']);
    final newCommit = await rawGit([
      '--git-dir=$serverDir', '-c', 'user.name=server',
      '-c', 'user.email=server@test', 'commit-tree', tree, '-m', 'snapshot'
    ]);
    await rawGit([
      '--git-dir=$serverDir', 'update-ref', 'refs/heads/current', newCommit, old
    ]);

    // B has a new, not-yet-synced file when the compression happens.
    await write(dirB, 'fresh.txt', 'unsynced local work');
    final rb = await syncOk(b);
    expect(rb.compressionDetected, isTrue);
    expect(rb.pushedCommit, isNotNull);

    // Nothing lost on B, and A (also detecting compression) converges.
    expect(await read(dirB, 'one.txt'), 'first');
    expect(await read(dirB, 'two.txt'), 'second');
    final ra = await syncOk(a);
    expect(ra.compressionDetected, isTrue);
    expect(await read(dirA, 'fresh.txt'), 'unsynced local work');
    expect(await snapshot(dirA), equals(await snapshot(dirB)));
  });

  test('7. .sync never appears in the remote tree', () async {
    await write(dirA, 'a.txt', 'A');
    await syncOk(a);
    await write(dirB, 'b.txt', 'B');
    await syncOk(b);
    await syncOk(a);

    final paths = await remotePaths();
    expect(paths, isNotEmpty);
    expect(
        paths.where((path) => path == '.sync' || path.startsWith('.sync/')),
        isEmpty);
    // Sanity: the real files did make it.
    expect(paths, containsAll(['a.txt', 'b.txt']));
  });

  test('8. adding an ignore rule over a synced file never propagates '
      'deletes (§12, no phantom delete)', () async {
    await write(dirA, 'build/x.txt', 'generated artifact');
    await write(dirA, 'src/main.txt', 'source');
    await syncOk(a);
    await syncOk(b);
    expect(await read(dirB, 'build/x.txt'), 'generated artifact');

    // A starts ignoring build/: the already-synced file leaves L on the
    // next scan, which must NOT read as a local deletion.
    await write(dirA, '.syncignore', 'build/\n');
    final ra = await syncOk(a); // uploads .syncignore itself
    expect(ra.deletedRemote, 0, reason: 'ignored path must not be deleted '
        'remotely');
    expect(ra.deletedLocal, 0);
    expect(ra.conflicts, isEmpty);
    expect(await remotePaths(), contains('build/x.txt'));
    expect(exists(dirA, 'build/x.txt'), isTrue);

    // Repeated cycles stay quiet: the base entry was reverted, not advanced,
    // so it cannot drive a deletion later either.
    final ra2 = await syncOk(a);
    expect(ra2.deletedRemote, 0);
    expect(ra2.isNoop, isTrue);
    expect(await remotePaths(), contains('build/x.txt'));

    // B downloads .syncignore, then runs with the rule active: build/x.txt
    // must survive on B and on the server.
    await syncOk(b);
    final rb = await syncOk(b);
    expect(rb.deletedRemote, 0);
    expect(rb.deletedLocal, 0);
    expect(exists(dirB, 'build/x.txt'), isTrue);
    expect(await remotePaths(), contains('build/x.txt'));

    // Removing the rule resumes normal three-way sync without conflicts:
    // l == b == r for build/x.txt on A.
    await File(p.join(dirA, '.syncignore')).delete();
    final ra3 = await syncOk(a);
    expect(ra3.conflicts, isEmpty);
    expect(await remotePaths(), contains('build/x.txt'));
    expect(await read(dirA, 'build/x.txt'), 'generated artifact');
  });

  test('9. crash between push and base advance (19.4.1): next start '
      'converges with no errors, no conflict copies, nothing lost', () async {
    final dbPath = p.join(dirA, '.sync', 'index.db');
    final dbBackup = p.join(tmp.path, 'index.db.bak');

    await write(dirA, 'f1.txt', 'first file');
    await syncOk(a);
    await a.stop();
    await File(dbPath).copy(dbBackup); // base as of "f1 synced"

    a = makeEngine(dirA, 'PC-A');
    await a.initialize();
    await write(dirA, 'f2.txt', 'second file');
    final r2 = await syncOk(a);
    expect(r2.pushedCommit, isNotNull);
    await a.stop();

    // Exact simulation of "push succeeded but crashed before replaceBase":
    // remote holds f2, index.db does not.
    await File(dbBackup).copy(dbPath);

    a = makeEngine(dirA, 'PC-A');
    await a.initialize();
    final r3 = await syncOk(a);
    expect(r3.error, isNull);
    expect(r3.compressionDetected, isFalse);
    expect(r3.conflicts, isEmpty);
    expect(r3.downloaded, 0); // l == r: identical change, no action
    expect(await read(dirA, 'f2.txt'), 'second file');
    expect(await remotePaths(), containsAll(['f1.txt', 'f2.txt']));
    final snapA = await snapshot(dirA);
    expect(snapA.keys.where((k) => k.contains('conflict')), isEmpty,
        reason: 'recovery of an identical state must not fabricate copies');
    await a.stop();

    // The base advanced past the recovered state.
    final db = await IndexDb.open(dbPath);
    final baseTree = await db.baseTree();
    db.close();
    expect(baseTree.keys, containsAll(['f1.txt', 'f2.txt']));

    a = makeEngine(dirA, 'PC-A'); // restore for tearDown
    await a.initialize();
  });

  test('9b. crash recovery variant: f2 edited before the recovery sync -> '
      'both the pushed and the new content survive (conflict copy)', () async {
    final dbPath = p.join(dirA, '.sync', 'index.db');
    final dbBackup = p.join(tmp.path, 'index.db.bak');

    await write(dirA, 'f1.txt', 'first file');
    await syncOk(a);
    await a.stop();
    await File(dbPath).copy(dbBackup);

    a = makeEngine(dirA, 'PC-A');
    await a.initialize();
    await write(dirA, 'f2.txt', 'pushed before crash');
    await syncOk(a);
    await a.stop();
    await File(dbBackup).copy(dbPath); // crash before replaceBase

    a = makeEngine(dirA, 'PC-A');
    await a.initialize();
    await write(dirA, 'f2.txt', 'edited after crash');
    final r = await syncOk(a);
    // b=∅, l=new content, r=pushed content → create/create conflict row.
    expect(r.conflicts, hasLength(1));
    expect(r.conflicts.single.path, 'f2.txt');
    final snapA = await snapshot(dirA);
    expect(snapA['f2.txt'], 'pushed before crash'); // remote wins the path
    expect(snapA.values, contains('edited after crash')); // copy survives
    expect(await remotePaths(), contains('f2.txt'));
  });

  test('lock: second engine on the same dir with a live pid fails, '
      'stale lock is taken over', () async {
    // Our own pid is alive -> same-process re-init takes over (pid equal),
    // so fake a different live pid by spawning a sleeping child.
    final sleeper = await Process.start('sleep', ['30']);
    final lockFile = File(p.join(dirA, '.sync', 'lock'));
    await a.stop(); // releases our lock, closes db
    await lockFile.writeAsString('${sleeper.pid}\n', flush: true);

    final a2 = makeEngine(dirA, 'PC-A');
    await expectLater(a2.initialize(), throwsA(isA<StateError>()));
    sleeper.kill();
    await sleeper.exitCode;

    // Now the pid is dead: the lock is stale and gets taken over.
    final a3 = makeEngine(dirA, 'PC-A');
    await a3.initialize();
    expect((await lockFile.readAsString()).trim(), '$pid');
    await a3.stop();

    a = makeEngine(dirA, 'PC-A'); // restore for tearDown
    await a.initialize();
  }, testOn: '!windows');

  test('conflict report timestamps parse via ConflictRecord round-trip',
      () async {
    final record = ConflictRecord(
        time: DateTime.now(),
        kind: 'modify',
        path: 'p.txt',
        copyPath: 'p copy.txt',
        clientId: 'PC-A');
    final back = ConflictRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>);
    expect(back.path, record.path);
    expect(back.copyPath, record.copyPath);
  });
}
