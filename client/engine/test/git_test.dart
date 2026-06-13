import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_engine/src/git.dart';
import 'package:sync_engine/src/models.dart';
import 'package:test/test.dart';

/// Runs a raw git command (test fixture only).
Future<ProcessResult> rawGit(List<String> args,
    {Map<String, String>? env}) async {
  final r = await Process.run('git', args,
      environment: {'GIT_TERMINAL_PROMPT': '0', 'LC_ALL': 'C', ...?env});
  if (r.exitCode != 0) {
    fail('raw git $args failed: ${r.stderr}');
  }
  return r;
}

void main() {
  late Directory tmp;
  late String serverDir;
  late GitRepo repoA;

  Future<String> writeFile(String relPath, List<int> bytes) async {
    final file = File(p.join(tmp.path, 'files', relPath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync-git-test-');
    serverDir = p.join(tmp.path, 'server.git');
    await rawGit(['init', '--bare', '--quiet', serverDir]);
    await rawGit(
        ['--git-dir=$serverDir', 'config', 'receive.denyNonFastForwards', 'true']);
    repoA = GitRepo(gitDir: p.join(tmp.path, 'a', 'repo'), remoteUrl: serverDir);
    await repoA.ensureInitialized();
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('ensureInitialized is idempotent and corrects the remote url', () async {
    await repoA.ensureInitialized(); // second run: no error, no re-init
    var r = await rawGit(
        ['--git-dir=${repoA.gitDir}', 'remote', 'get-url', 'origin']);
    expect((r.stdout as String).trim(), serverDir);

    final otherUrl = p.join(tmp.path, 'other.git');
    final repoA2 = GitRepo(gitDir: repoA.gitDir, remoteUrl: otherUrl);
    await repoA2.ensureInitialized();
    r = await rawGit(
        ['--git-dir=${repoA.gitDir}', 'remote', 'get-url', 'origin']);
    expect((r.stdout as String).trim(), otherUrl);
  });

  test('fetchCurrent returns null when the remote branch does not exist',
      () async {
    expect(await repoA.fetchCurrent(), isNull);
  });

  test('fetchCurrent throws GitException for an unreachable remote', () async {
    final broken = GitRepo(
        gitDir: p.join(tmp.path, 'broken', 'repo'),
        remoteUrl: p.join(tmp.path, 'no-such-repo'));
    await broken.ensureInitialized();
    expect(broken.fetchCurrent(), throwsA(isA<GitException>()));
  });

  test(
      'round-trip: writeBlob/commitTree/pushCurrent/fetchCurrent/readTree '
      'preserves content and 100755 mode', () async {
    final textPath = await writeFile('docs/hello.txt', utf8.encode('hello\n'));
    final exePath = await writeFile('tool.sh', utf8.encode('#!/bin/sh\n'));
    final textSha = await repoA.writeBlob(textPath);
    final exeSha = await repoA.writeBlob(exePath);
    expect(textSha, hasLength(40));

    final tree = <String, FileEntry>{
      'docs/hello.txt': FileEntry(path: 'docs/hello.txt', hash: textSha),
      'tool.sh': FileEntry(
          path: 'tool.sh', hash: exeSha, mode: EntryMode.executable),
    };
    final commit =
        await repoA.commitTree(tree, parents: [], message: 'c1 from test');
    expect(await repoA.pushCurrent(commit), isTrue);

    final repoB =
        GitRepo(gitDir: p.join(tmp.path, 'b', 'repo'), remoteUrl: serverDir);
    await repoB.ensureInitialized();
    final head = await repoB.fetchCurrent();
    expect(head, commit);

    final got = await repoB.readTree(head!);
    expect(got.keys, unorderedEquals(['docs/hello.txt', 'tool.sh']));
    expect(got['docs/hello.txt']!.hash, textSha);
    expect(got['docs/hello.txt']!.mode, EntryMode.regular);
    expect(got['tool.sh']!.hash, exeSha);
    expect(got['tool.sh']!.mode, EntryMode.executable);
  });

  test('catBlobToFile reproduces binary content byte for byte', () async {
    // 64KiB+ of all byte values, no trailing newline: catches any
    // string/encoding round-trip in the pipe.
    final bytes = List<int>.generate(65539, (i) => i % 256);
    final src = await writeFile('blob.bin', bytes);
    final sha = await repoA.writeBlob(src);

    final dest = p.join(tmp.path, 'out', 'nested', 'blob.bin');
    await repoA.catBlobToFile(sha, dest);
    expect(await File(dest).readAsBytes(), bytes);
  });

  test('catBlobToFile throws GitException for a missing blob', () async {
    final dest = p.join(tmp.path, 'out', 'missing.bin');
    await expectLater(
        repoA.catBlobToFile('0' * 40, dest), throwsA(isA<GitException>()));
    expect(File(dest).existsSync(), isFalse);
  });

  test('isAncestor true and false cases', () async {
    final sha = await repoA.writeBlob(await writeFile('a.txt', utf8.encode('1')));
    final c1 = await repoA.commitTree(
        {'a.txt': FileEntry(path: 'a.txt', hash: sha)},
        parents: [], message: 'c1');
    final sha2 =
        await repoA.writeBlob(await writeFile('a.txt', utf8.encode('2')));
    final c2 = await repoA.commitTree(
        {'a.txt': FileEntry(path: 'a.txt', hash: sha2)},
        parents: [c1], message: 'c2');

    expect(await repoA.isAncestor(c1, c2), isTrue);
    expect(await repoA.isAncestor(c2, c1), isFalse);
  });

  test('commitTree supports 0, 1 and 2 parents', () async {
    final c0 = await repoA.commitTree({}, parents: [], message: 'root A');
    final c1 = await repoA.commitTree({}, parents: [], message: 'root B');
    final merge =
        await repoA.commitTree({}, parents: [c0, c1], message: 'merge');

    expect(await repoA.resolve('$merge^1'), c0);
    expect(await repoA.resolve('$merge^2'), c1);
    expect(await repoA.resolve('$c0^1'), isNull);
  });

  test('pushCurrent returns false when another client advanced the branch',
      () async {
    final shaA =
        await repoA.writeBlob(await writeFile('f.txt', utf8.encode('A1')));
    final c1 = await repoA.commitTree(
        {'f.txt': FileEntry(path: 'f.txt', hash: shaA)},
        parents: [], message: 'c1');
    expect(await repoA.pushCurrent(c1), isTrue);

    // Client B fetches c1 and pushes c2 on top of it.
    final repoB =
        GitRepo(gitDir: p.join(tmp.path, 'b', 'repo'), remoteUrl: serverDir);
    await repoB.ensureInitialized();
    expect(await repoB.fetchCurrent(), c1);
    final shaB =
        await repoB.writeBlob(await writeFile('f.txt', utf8.encode('B2')));
    final c2 = await repoB.commitTree(
        {'f.txt': FileEntry(path: 'f.txt', hash: shaB)},
        parents: [c1], message: 'c2');
    expect(await repoB.pushCurrent(c2), isTrue);

    // Client A, unaware of c2, builds on the stale head c1: must be
    // rejected as non-fast-forward, reported as false (not an exception).
    final shaA2 =
        await repoA.writeBlob(await writeFile('f.txt', utf8.encode('A3')));
    final c1b = await repoA.commitTree(
        {'f.txt': FileEntry(path: 'f.txt', hash: shaA2)},
        parents: [c1], message: 'c1b');
    expect(await repoA.pushCurrent(c1b), isFalse);

    // The server head is untouched.
    final r = await rawGit(
        ['--git-dir=$serverDir', 'rev-parse', 'refs/heads/current']);
    expect((r.stdout as String).trim(), c2);
  });

  test('readTree skips 120000 symlink entries', () async {
    // Craft a commit containing a symlink entry with raw plumbing — the
    // wrapper itself can never produce one.
    final gitDir = repoA.gitDir;
    final fileSha =
        await repoA.writeBlob(await writeFile('real.txt', utf8.encode('x')));
    final targetSha =
        await repoA.writeBlob(await writeFile('target', utf8.encode('real.txt')));

    final indexDir = await Directory(tmp.path).createTemp('idx');
    final env = {'GIT_INDEX_FILE': p.join(indexDir.path, 'index')};
    final proc = await Process.start(
        'git', ['--git-dir=$gitDir', 'update-index', '--index-info'],
        environment: {'LC_ALL': 'C', ...env});
    proc.stdin.write('100644 $fileSha\treal.txt\n120000 $targetSha\tlink\n');
    await proc.stdin.close();
    expect(await proc.exitCode, 0);
    final treeSha = (await rawGit(['--git-dir=$gitDir', 'write-tree'], env: env))
        .stdout
        .toString()
        .trim();
    final commit = (await rawGit([
      '--git-dir=$gitDir',
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      'commit-tree',
      treeSha,
      '-m',
      'with symlink',
    ]))
        .stdout
        .toString()
        .trim();

    final tree = await repoA.readTree(commit);
    expect(tree.keys, ['real.txt']);
  });

  test('resolve returns null for an unknown ref', () async {
    expect(await repoA.resolve('refs/heads/nope'), isNull);
  });
}
