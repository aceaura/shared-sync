import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sync_engine/src/ignore.dart';
import 'package:sync_engine/src/models.dart';
import 'package:sync_engine/src/scanner.dart';
import 'package:test/test.dart';

/// Reference git blob SHA-1 (what `git hash-object` would print).
String gitBlobSha1(String content) {
  final bytes = utf8.encode(content);
  return sha1
      .convert([...ascii.encode('blob ${bytes.length}\x00'), ...bytes])
      .toString();
}

Future<void> writeFile(String root, String rel, String content) async {
  final file = File(p.join(root, rel));
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_scanner_test_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<Scanner> makeScanner({int stableDelaySeconds = 0}) async {
    final ignore = await IgnoreMatcher.fromSharedDir(tmp.path, '.syncignore');
    return Scanner(
      sharedDir: tmp.path,
      ignore: ignore,
      stableDelaySeconds: stableDelaySeconds,
    );
  }

  test('scans nested tree with forward-slash relative paths and git hashes',
      () async {
    await writeFile(tmp.path, 'a.txt', 'hello\n');
    await writeFile(tmp.path, 'sub/b.txt', 'world\n');
    await writeFile(tmp.path, 'sub/deeper/c.txt', '');

    final scanner = await makeScanner();
    final result = await scanner.scan({});

    expect(result.files.keys.toSet(),
        {'a.txt', 'sub/b.txt', 'sub/deeper/c.txt'});
    // Well-known git blob hash for "hello\n".
    expect(result.files['a.txt']!.hash,
        'ce013625030ba8dba906f756967f9e9ca394464a');
    expect(result.files['sub/b.txt']!.hash, gitBlobSha1('world\n'));
    expect(result.files['sub/deeper/c.txt']!.hash, gitBlobSha1(''));
    expect(result.unstablePaths, isEmpty);
    // FileEntry invariants.
    final entry = result.files['sub/b.txt']!;
    expect(entry.path, 'sub/b.txt');
    expect(entry.mode, EntryMode.regular);
  });

  test('stats carry size, mtime and hash for every scanned file', () async {
    await writeFile(tmp.path, 'a.txt', 'hello\n');
    final scanner = await makeScanner();
    final result = await scanner.scan({});

    final st = await File(p.join(tmp.path, 'a.txt')).stat();
    final cached = result.stats['a.txt']!;
    expect(cached.size, 6);
    expect(cached.mtimeMs, st.modified.millisecondsSinceEpoch);
    expect(cached.hash, result.files['a.txt']!.hash);
    expect(cached.mode, EntryMode.regular);
    expect(result.stats.keys.toSet(), result.files.keys.toSet());
  });

  test('.sync directory is pruned and default ignores apply', () async {
    await writeFile(tmp.path, 'kept.txt', 'k');
    await writeFile(tmp.path, '.sync/repo/HEAD', 'ref: refs/heads/current');
    await writeFile(tmp.path, '.sync/index.db', 'junk');
    await writeFile(tmp.path, '.DS_Store', 'mac junk');
    await writeFile(tmp.path, 'sub/note.tmp', 'temp junk');

    final scanner = await makeScanner();
    final result = await scanner.scan({});

    expect(result.files.keys.toSet(), {'kept.txt'});
  });

  test('.syncignore patterns are honored (files and directory pruning)',
      () async {
    await writeFile(tmp.path, '.syncignore', '*.bak\nsecret/\n');
    await writeFile(tmp.path, 'keep.txt', 'x');
    await writeFile(tmp.path, 'old.bak', 'x');
    await writeFile(tmp.path, 'sub/also.bak', 'x');
    await writeFile(tmp.path, 'secret/hidden.txt', 'x');

    final scanner = await makeScanner();
    final result = await scanner.scan({});

    // .syncignore itself is a regular file and stays synced.
    expect(result.files.keys.toSet(), {'.syncignore', 'keep.txt'});
  });

  test('symlinks are skipped, not followed', () async {
    await writeFile(tmp.path, 'real.txt', 'data');
    await writeFile(tmp.path, 'dir/inner.txt', 'data');
    await Link(p.join(tmp.path, 'link.txt'))
        .create(p.join(tmp.path, 'real.txt'));
    await Link(p.join(tmp.path, 'dirlink')).create(p.join(tmp.path, 'dir'));

    final scanner = await makeScanner();
    final result = await scanner.scan({});

    expect(result.files.keys.toSet(), {'real.txt', 'dir/inner.txt'});
  });

  test('executable bit maps to EntryMode.executable', () async {
    await writeFile(tmp.path, 'run.sh', '#!/bin/sh\necho hi\n');
    await writeFile(tmp.path, 'plain.txt', 'hi');
    final chmod = await Process.run(
        'chmod', ['755', p.join(tmp.path, 'run.sh')]);
    expect(chmod.exitCode, 0);

    final scanner = await makeScanner();
    final result = await scanner.scan({});

    expect(result.files['run.sh']!.mode, EntryMode.executable);
    expect(result.files['plain.txt']!.mode, EntryMode.regular);
    expect(result.stats['run.sh']!.mode, EntryMode.executable);
  }, skip: Platform.isWindows ? 'no executable bit on Windows' : false);

  test('statCache hit (same size+mtime) reuses cached hash without hashing',
      () async {
    await writeFile(tmp.path, 'a.txt', 'hello\n');
    final st = await File(p.join(tmp.path, 'a.txt')).stat();
    // Deliberately wrong hash: if the scanner re-hashed, it would not return
    // this value — proving the cache short-circuit.
    const bogus = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
    final cache = {
      'a.txt': CachedStat(
        size: st.size,
        mtimeMs: st.modified.millisecondsSinceEpoch,
        hash: bogus,
        mode: EntryMode.regular,
      ),
    };

    final scanner = await makeScanner();
    final result = await scanner.scan(cache);

    expect(result.files['a.txt']!.hash, bogus);
    expect(result.stats['a.txt']!.hash, bogus);
    expect(result.unstablePaths, isEmpty);
  });

  test('statCache miss (size or mtime differs) forces a fresh hash', () async {
    await writeFile(tmp.path, 'a.txt', 'hello\n');
    final st = await File(p.join(tmp.path, 'a.txt')).stat();
    const bogus = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
    final cache = {
      'a.txt': CachedStat(
        size: st.size + 1, // mismatch
        mtimeMs: st.modified.millisecondsSinceEpoch,
        hash: bogus,
        mode: EntryMode.regular,
      ),
    };

    final scanner = await makeScanner();
    final result = await scanner.scan(cache);

    expect(result.files['a.txt']!.hash, gitBlobSha1('hello\n'));
  });

  test('freshly written files land in unstablePaths when delay is large',
      () async {
    await writeFile(tmp.path, 'fresh.txt', 'just written');
    await writeFile(tmp.path, 'sub/also.txt', 'me too');

    final scanner = await makeScanner(stableDelaySeconds: 3600);
    final result = await scanner.scan({});

    expect(result.unstablePaths, {'fresh.txt', 'sub/also.txt'});
    // Unstable files are still part of files/stats — the engine freezes them.
    expect(result.files.keys.toSet(), {'fresh.txt', 'sub/also.txt'});
    expect(result.stats.keys.toSet(), {'fresh.txt', 'sub/also.txt'});
  });

  test('recent mtime makes even a cache hit unstable', () async {
    await writeFile(tmp.path, 'fresh.txt', 'data');
    final st = await File(p.join(tmp.path, 'fresh.txt')).stat();
    final cache = {
      'fresh.txt': CachedStat(
        size: st.size,
        mtimeMs: st.modified.millisecondsSinceEpoch,
        hash: gitBlobSha1('data'),
        mode: EntryMode.regular,
      ),
    };

    final scanner = await makeScanner(stableDelaySeconds: 3600);
    final result = await scanner.scan(cache);

    expect(result.unstablePaths, {'fresh.txt'});
  });

  test('unreadable file is frozen (unstable) instead of reported deleted',
      () async {
    await writeFile(tmp.path, 'locked.txt', 'secret');
    await writeFile(tmp.path, 'ok.txt', 'fine');
    final lockedPath = p.join(tmp.path, 'locked.txt');
    expect((await Process.run('chmod', ['000', lockedPath])).exitCode, 0);
    addTearDown(() => Process.run('chmod', ['644', lockedPath]));

    final scanner = await makeScanner();
    final result = await scanner.scan({});

    // Not in files (cannot hash it) but frozen so the engine treats l:=b
    // and never uploads a deletion for it.
    expect(result.files.keys.toSet(), {'ok.txt'});
    expect(result.unstablePaths, {'locked.txt'});
  }, skip: Platform.isWindows ? 'POSIX permissions only' : false);

  test('unlistable directory freezes its previously known paths', () async {
    await writeFile(tmp.path, 'vault/a.txt', 'x');
    await writeFile(tmp.path, 'vault/sub/b.txt', 'y');
    await writeFile(tmp.path, 'outside.txt', 'z');
    final vault = p.join(tmp.path, 'vault');
    final cache = {
      'vault/a.txt': CachedStat(
          size: 1, mtimeMs: 1, hash: 'a' * 40, mode: EntryMode.regular),
      'vault/sub/b.txt': CachedStat(
          size: 1, mtimeMs: 1, hash: 'b' * 40, mode: EntryMode.regular),
      'outside.txt': CachedStat(
          size: 1, mtimeMs: 1, hash: 'c' * 40, mode: EntryMode.regular),
    };
    expect((await Process.run('chmod', ['000', vault])).exitCode, 0);
    addTearDown(() => Process.run('chmod', ['755', vault]));

    final scanner = await makeScanner();
    final result = await scanner.scan(cache);

    expect(result.unstablePaths, {'vault/a.txt', 'vault/sub/b.txt'});
    expect(result.files.keys.toSet(), {'outside.txt'});
  }, skip: Platform.isWindows ? 'POSIX permissions only' : false);

  test('empty shared dir yields an empty result', () async {
    final scanner = await makeScanner();
    final result = await scanner.scan({});
    expect(result.files, isEmpty);
    expect(result.unstablePaths, isEmpty);
    expect(result.stats, isEmpty);
  });
}
