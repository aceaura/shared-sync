/// Thin wrapper around the system `git` CLI (plumbing only). DESIGN.md §4.6.
///
/// Every command passes `--git-dir` explicitly and runs with
/// `GIT_TERMINAL_PROMPT=0` so authentication failures fail fast instead of
/// hanging on a prompt. Commit identity is supplied per command via
/// `-c user.name/-c user.email`, never relying on global git config.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'logger.dart';
import 'models.dart';

/// Failure of a git subprocess that is not an expected domain outcome
/// (expected outcomes: missing remote branch -> `null`, non-fast-forward
/// push -> `false`).
class GitException implements Exception {
  final String message;
  final String? stderr;

  GitException(this.message, [this.stderr]);

  @override
  String toString() {
    final detail = stderr?.trim();
    return detail == null || detail.isEmpty
        ? 'GitException: $message'
        : 'GitException: $message\n$detail';
  }
}

/// Wrapper around one hidden bare repository (`<sharedDir>/.sync/repo`).
class GitRepo {
  /// Absolute path of the bare repository.
  final String gitDir;

  /// URL (or local path) of the `origin` remote.
  final String remoteUrl;

  final SyncLogger? logger;

  GitRepo({required this.gitDir, required this.remoteUrl, this.logger});

  /// Commit identity at command level so a missing global config can never
  /// make commit-tree fail or leak the user's personal identity.
  static const List<String> _identity = [
    '-c',
    'user.name=sync-engine',
    '-c',
    'user.email=sync@shared-sync.local',
  ];

  /// `LC_ALL=C` keeps git messages untranslated: [fetchCurrent] and
  /// [pushCurrent] classify outcomes by matching English stderr text.
  Map<String, String> _env([Map<String, String>? extra]) => {
        'GIT_TERMINAL_PROMPT': '0',
        'LC_ALL': 'C',
        ...?extra,
      };

  Future<ProcessResult> _git(
    List<String> args, {
    Map<String, String>? extraEnv,
    List<int>? stdinBytes,
  }) async {
    final fullArgs = <String>['--git-dir=$gitDir', ...args];
    if (stdinBytes == null) {
      return Process.run(
        'git',
        fullArgs,
        environment: _env(extraEnv),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    }
    final proc = await Process.start(
      'git',
      fullArgs,
      environment: _env(extraEnv),
    );
    // Start draining stdout/stderr before writing stdin to avoid pipe
    // deadlocks; swallow stdin errors (child may exit early), the failure
    // then surfaces through the exit code.
    final stdoutFuture = utf8.decodeStream(proc.stdout);
    final stderrFuture = utf8.decodeStream(proc.stderr);
    try {
      proc.stdin.add(stdinBytes);
      await proc.stdin.flush();
      await proc.stdin.close();
    } catch (_) {}
    final exitCode = await proc.exitCode;
    return ProcessResult(
        proc.pid, exitCode, await stdoutFuture, await stderrFuture);
  }

  /// Runs git and throws [GitException] on a non-zero exit; returns stdout.
  Future<String> _gitChecked(
    List<String> args, {
    Map<String, String>? extraEnv,
    List<int>? stdinBytes,
    String? what,
  }) async {
    final r = await _git(args, extraEnv: extraEnv, stdinBytes: stdinBytes);
    if (r.exitCode != 0) {
      throw GitException(
        'git ${what ?? args.first} failed (exit ${r.exitCode})',
        r.stderr as String,
      );
    }
    return r.stdout as String;
  }

  /// Creates the bare repository if missing and makes sure `origin` points
  /// to [remoteUrl]. Idempotent; corrects a stale remote URL.
  Future<void> ensureInitialized() async {
    if (!File(p.join(gitDir, 'HEAD')).existsSync()) {
      await Directory(gitDir).create(recursive: true);
      await _gitChecked(['init', '--bare', '--quiet'], what: 'init');
      logger?.info('initialized bare repo at $gitDir');
    }
    final current = await _git(['remote', 'get-url', 'origin']);
    if (current.exitCode != 0) {
      await _gitChecked(['remote', 'add', 'origin', remoteUrl],
          what: 'remote add');
    } else if ((current.stdout as String).trim() != remoteUrl) {
      await _gitChecked(['remote', 'set-url', 'origin', remoteUrl],
          what: 'remote set-url');
      logger?.info('updated origin url to $remoteUrl');
    }
  }

  /// Fetches the remote `current` branch into `refs/remotes/origin/current`
  /// (forced refspec: the local mirror ref always tracks the remote, even
  /// after server-side history compression rewrote the branch).
  ///
  /// Returns the remote head sha, or `null` when the branch does not exist
  /// yet (fresh server). Network/auth/other failures throw [GitException] —
  /// they must never be mistaken for an empty remote, or the engine could
  /// plan against R=∅ and push a tree that drops remote files.
  Future<String?> fetchCurrent() async {
    final r = await _git([
      'fetch',
      '--quiet',
      'origin',
      '+refs/heads/current:refs/remotes/origin/current',
    ]);
    if (r.exitCode != 0) {
      final err = r.stderr as String;
      if (err.contains("couldn't find remote ref")) return null;
      throw GitException('git fetch failed (exit ${r.exitCode})', err);
    }
    final sha = await resolve('refs/remotes/origin/current');
    if (sha == null) {
      throw GitException(
          'fetch succeeded but refs/remotes/origin/current is unresolvable');
    }
    return sha;
  }

  /// Reads the full tree of [commit] as a [TreeState].
  ///
  /// Symlinks (mode 120000) and any other non-blob entries are skipped with
  /// a warning — the engine does not sync them.
  Future<TreeState> readTree(String commit) async {
    final out =
        await _gitChecked(['ls-tree', '-r', '-z', commit], what: 'ls-tree');
    final tree = <String, FileEntry>{};
    for (final record in out.split('\x00')) {
      if (record.isEmpty) continue;
      final tab = record.indexOf('\t');
      if (tab < 0) continue;
      // Record format: "<mode> <type> <sha>\t<path>".
      final meta = record.substring(0, tab).split(' ');
      final path = record.substring(tab + 1);
      if (meta.length < 3) continue;
      final mode = meta[0];
      final sha = meta[2];
      if (mode == '120000') {
        logger?.warn('skipping symlink in remote tree (not synced): $path');
        continue;
      }
      if (mode != '100644' && mode != '100755') {
        logger?.warn('skipping unsupported tree entry (mode $mode): $path');
        continue;
      }
      tree[path] =
          FileEntry(path: path, hash: sha, mode: EntryMode.fromGitMode(mode));
    }
    return tree;
  }

  /// Computes the git blob sha of [absPath] without writing the object
  /// (scanner fallback). Returns `null` if the file cannot be read.
  Future<String?> blobHashOfFile(String absPath) async {
    final r = await _git(['hash-object', '--', absPath]);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trim();
  }

  /// Writes the content of [absPath] into the object database and returns
  /// its blob sha.
  Future<String> writeBlob(String absPath) async {
    final out =
        await _gitChecked(['hash-object', '-w', '--', absPath], what: 'hash-object -w');
    return out.trim();
  }

  /// Builds a tree object from [tree] using a throwaway index file and
  /// creates a commit with the given [parents] (0, 1 or 2) and [message].
  ///
  /// All blobs referenced by [tree] must already exist in the object
  /// database (via [writeBlob] or [fetchCurrent]).
  Future<String> commitTree(
    TreeState tree, {
    required List<String> parents,
    required String message,
  }) async {
    // A temporary GIT_INDEX_FILE keeps the bare repo's (nonexistent) default
    // index untouched and makes concurrent commitTree calls safe.
    final tmpDir = await Directory.systemTemp.createTemp('sync-engine-index-');
    final extraEnv = {'GIT_INDEX_FILE': p.join(tmpDir.path, 'index')};
    try {
      final input = StringBuffer();
      for (final entry in tree.values) {
        input.write('${entry.mode.gitMode} ${entry.hash}\t${entry.path}\n');
      }
      await _gitChecked(
        ['update-index', '--index-info'],
        extraEnv: extraEnv,
        stdinBytes: utf8.encode(input.toString()),
        what: 'update-index --index-info',
      );
      final treeSha =
          (await _gitChecked(['write-tree'], extraEnv: extraEnv)).trim();
      final commitSha = (await _gitChecked(
        [
          ..._identity,
          'commit-tree',
          treeSha,
          for (final parent in parents) ...['-p', parent],
          '-m',
          message,
        ],
        what: 'commit-tree',
      ))
          .trim();
      return commitSha;
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Pushes [commit] to the remote `current` branch.
  ///
  /// Returns `false` when the push is rejected as non-fast-forward (another
  /// client advanced the branch first — the engine refetches and replans).
  /// Any other failure throws [GitException].
  Future<bool> pushCurrent(String commit) async {
    final r = await _git(['push', 'origin', '$commit:refs/heads/current']);
    if (r.exitCode == 0) return true;
    final err = r.stderr as String;
    final lower = err.toLowerCase();
    if (lower.contains('non-fast-forward') ||
        lower.contains('fetch first') ||
        lower.contains('rejected')) {
      logger?.info('push rejected (non-fast-forward), retry after refetch');
      return false;
    }
    throw GitException('git push failed (exit ${r.exitCode})', err);
  }

  /// True when commit [a] is an ancestor of commit [b]
  /// (`merge-base --is-ancestor`). A commit is an ancestor of itself.
  Future<bool> isAncestor(String a, String b) async {
    final r = await _git(['merge-base', '--is-ancestor', a, b]);
    if (r.exitCode == 0) return true;
    if (r.exitCode == 1) return false;
    throw GitException(
        'git merge-base --is-ancestor failed (exit ${r.exitCode})',
        r.stderr as String);
  }

  /// Streams blob [hash] into [destAbsPath] (parent directories created).
  ///
  /// The content is piped as raw bytes — never decoded to a string — so
  /// arbitrarily large or binary files are safe. On failure the partially
  /// written file is removed.
  Future<void> catBlobToFile(String hash, String destAbsPath) async {
    final dest = File(destAbsPath);
    await dest.parent.create(recursive: true);
    final proc = await Process.start(
      'git',
      ['--git-dir=$gitDir', 'cat-file', 'blob', hash],
      environment: _env(),
    );
    unawaited(proc.stdin.close());
    final stderrBuf = StringBuffer();
    final stderrDone =
        proc.stderr.transform(utf8.decoder).forEach(stderrBuf.write);
    final sink = dest.openWrite();
    try {
      await sink.addStream(proc.stdout);
      await sink.flush();
    } catch (_) {
      proc.kill();
      rethrow;
    } finally {
      await sink.close();
    }
    final exitCode = await proc.exitCode;
    await stderrDone;
    if (exitCode != 0) {
      try {
        await dest.delete();
      } catch (_) {}
      throw GitException(
        'git cat-file blob $hash failed (exit $exitCode)',
        stderrBuf.toString(),
      );
    }
  }

  /// Resolves [ref] to a sha (`rev-parse --verify`); `null` if unresolvable.
  Future<String?> resolve(String ref) async {
    final r = await _git(['rev-parse', '--verify', '--quiet', ref]);
    if (r.exitCode != 0) return null;
    final sha = (r.stdout as String).trim();
    return sha.isEmpty ? null : sha;
  }
}
