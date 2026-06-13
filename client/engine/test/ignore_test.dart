import 'dart:io';

import 'package:path/path.dart' as p;
// Imported via src to keep this test runnable before the other modules
// re-exported by sync_engine.dart exist.
import 'package:sync_engine/src/ignore.dart' show IgnoreMatcher;
import 'package:test/test.dart';

/// One table row: [path] (+[isDir]) is checked against a matcher and must
/// yield [ignored].
class Case {
  final String path;
  final bool isDir;
  final bool ignored;
  final String? reason;

  const Case(this.path, this.ignored, {this.isDir = false, this.reason});

  @override
  String toString() =>
      '"$path"${isDir ? ' (dir)' : ''} -> ${ignored ? 'ignored' : 'kept'}'
      '${reason == null ? '' : '  [$reason]'}';
}

void runTable(String group_, IgnoreMatcher matcher, List<Case> cases) {
  group(group_, () {
    for (final c in cases) {
      test(c.toString(), () {
        expect(matcher.isIgnored(c.path, isDir: c.isDir), c.ignored);
      });
    }
  });
}

void main() {
  group('line filtering', () {
    test('comments, blank lines and whitespace-only lines are dropped', () {
      final m = IgnoreMatcher(['# a comment', '', '   ', '\t', '*.bak']);
      expect(m.isIgnored('a.bak', isDir: false), isTrue);
      expect(m.isIgnored('# a comment', isDir: false), isFalse);
      expect(m.isIgnored('a comment', isDir: false), isFalse);
    });

    test('negation lines are unsupported and dropped entirely', () {
      final m = IgnoreMatcher(['*.tmp', '!keep.tmp', '!unmatched.txt']);
      // The positive rule still applies despite the attempted negation...
      expect(m.isIgnored('keep.tmp', isDir: false), isTrue);
      // ...and a dropped '!' line does not turn into a literal pattern.
      expect(m.isIgnored('!unmatched.txt', isDir: false), isFalse);
      expect(m.isIgnored('unmatched.txt', isDir: false), isFalse);
    });

    test('empty pattern list ignores nothing', () {
      final m = IgnoreMatcher([]);
      expect(m.isIgnored('anything.txt', isDir: false), isFalse);
      expect(m.isIgnored('.sync', isDir: true), isFalse);
    });
  });

  runTable('defaults', IgnoreMatcher(IgnoreMatcher.defaults), const [
    // .sync/ : dir-only, any level; subtree pruning.
    Case('.sync', true, isDir: true, reason: '.sync/ matches the dir'),
    Case('.sync', false, reason: 'trailing / never matches a plain file'),
    Case('.sync/repo/objects/ab', true, reason: 'inside ignored dir'),
    Case('.sync/index.db', true, reason: 'inside ignored dir'),
    Case('sub/.sync', true, isDir: true, reason: 'basename rule, any level'),
    Case('sub/.sync/lock', true, reason: 'inside nested ignored dir'),
    Case('.sync-trash', true, isDir: true),
    Case('.sync-trash/2026/file.txt', true),
    Case('.syncignore', false, reason: 'no rule matches the ignore file'),
    // .git/ : dir-only.
    Case('.git', true, isDir: true),
    Case('.git/config', true),
    Case('vendor/.git', true, isDir: true),
    Case('vendor/.git/HEAD', true),
    Case('.gitignore', false),
    // ~$* : Office owner files, any level.
    Case('~\$report.docx', true),
    Case('docs/~\$budget.xlsx', true),
    Case('a/b/~\$x.pptx', true),
    Case('report.docx', false),
    // *.tmp at arbitrary depth.
    Case('x.tmp', true),
    Case('a/b/c/x.tmp', true),
    Case('x.tmp2', false, reason: 'suffix must match exactly'),
    Case('x.TMP', false, reason: 'case sensitive'),
    // *.swp / *.lock
    Case('.main.dart.swp', true),
    Case('deep/dir/.f.swp', true),
    Case('pubspec.lock', true),
    Case('a/yarn.lock', true),
    Case('lock', false),
    // Exact basenames, any level.
    Case('Thumbs.db', true),
    Case('photos/2026/Thumbs.db', true),
    Case('thumbs.db', false, reason: 'case sensitive'),
    Case('.DS_Store', true),
    Case('a/.DS_Store', true),
    Case('desktop.ini', true),
    Case('cfg/desktop.ini', true),
    Case('desktop.ini.bak', false),
    // Normal user content survives.
    Case('notes.txt', false),
    Case('src/main.dart', false),
    Case('docs', false, isDir: true),
  ]);

  runTable(
      'anchored vs basename',
      IgnoreMatcher(['docs/build', 'bin', '/top.txt']),
      const [
        // 'docs/build' contains a non-trailing '/': anchored to the root.
        Case('docs/build', true, isDir: true),
        Case('docs/build', true, reason: 'no trailing /, files match too'),
        Case('docs/build/out.js', true, reason: 'subtree of anchored dir'),
        Case('x/docs/build', false, isDir: true, reason: 'anchored: not root'),
        Case('docs/builds', false),
        Case('build', false, reason: 'anchored rule needs the full path'),
        // 'bin' has no '/': basename match at any level.
        Case('bin', true, isDir: true),
        Case('bin', true),
        Case('a/b/bin', true),
        Case('a/bin/artifact.o', true, reason: 'under ignored dir'),
        Case('binder', false),
        // Leading '/' anchors without being part of the path.
        Case('top.txt', true),
        Case('sub/top.txt', false, reason: '/top.txt is root-anchored'),
      ]);

  runTable('trailing slash is directory-only', IgnoreMatcher(['logs/']),
      const [
        Case('logs', true, isDir: true),
        Case('logs', false, reason: 'file named logs is kept'),
        Case('logs/today.log', true, reason: 'inside ignored dir'),
        Case('app/logs', true, isDir: true, reason: 'basename, any level'),
        Case('app/logs/x', true),
        Case('logstash', false, isDir: true),
      ]);

  runTable(
      'star does not cross slashes',
      IgnoreMatcher(['a/*.txt', 'cache-*/']),
      const [
        Case('a/b.txt', true),
        Case('a/.txt', true, reason: '* may match empty'),
        Case('a/c/d.txt', false, reason: '* must not cross /'),
        Case('b.txt', false, reason: 'anchored under a/'),
        Case('cache-v1', true, isDir: true),
        Case('cache-v1', false),
        Case('x/cache-tmp/blob', true),
      ]);

  runTable('question mark is one non-slash char', IgnoreMatcher(['file?.txt']),
      const [
        Case('file1.txt', true),
        Case('fileA.txt', true),
        Case('file.txt', false, reason: '? requires exactly one char'),
        Case('file10.txt', false),
        Case('sub/file2.txt', true, reason: 'basename rule, any level'),
      ]);

  runTable(
      'double star crosses levels',
      IgnoreMatcher(['**/dist/main.js', 'a/**/b.txt', 'generated/**']),
      const [
        // Leading **/ : any depth, including root.
        Case('dist/main.js', true),
        Case('x/dist/main.js', true),
        Case('x/y/dist/main.js', true),
        Case('dist/other.js', false),
        // Middle /**/ : zero or more directories.
        Case('a/b.txt', true, reason: '** may match zero directories'),
        Case('a/x/b.txt', true),
        Case('a/x/y/b.txt', true),
        Case('z/a/b.txt', false, reason: 'pattern with / is root-anchored'),
        Case('a/xb.txt', false),
        // Trailing /** : everything below, not the dir itself.
        Case('generated/one.dart', true),
        Case('generated/deep/two.dart', true),
        Case('generated', false, isDir: true,
            reason: 'trailing /** matches contents only'),
        Case('other/generated/x', false, reason: 'root-anchored'),
      ]);

  runTable('case sensitivity', IgnoreMatcher(['*.TMP', 'Build/']), const [
    Case('a.TMP', true),
    Case('a.tmp', false),
    Case('Build', true, isDir: true),
    Case('build', false, isDir: true),
  ]);

  runTable(
      'path normalization is defensive',
      IgnoreMatcher(IgnoreMatcher.defaults),
      const [
        Case('./x.tmp', true, reason: 'leading ./ stripped'),
        Case('/x.tmp', true, reason: 'leading / stripped'),
        Case('', false, reason: 'empty path is never ignored'),
      ]);

  group('fromSharedDir', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ignore_test_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('missing ignore file yields defaults only', () async {
      final m = await IgnoreMatcher.fromSharedDir(tmp.path, '.syncignore');
      expect(m.isIgnored('.sync', isDir: true), isTrue);
      expect(m.isIgnored('a/b.tmp', isDir: false), isTrue);
      expect(m.isIgnored('notes.txt', isDir: false), isFalse);
    });

    test('file content is appended to defaults', () async {
      await File(p.join(tmp.path, '.syncignore')).writeAsString([
        '# project specific',
        '',
        'node_modules/',
        '*.bak',
        'secret/plan.md',
      ].join('\n'));

      final m = await IgnoreMatcher.fromSharedDir(tmp.path, '.syncignore');
      // Custom rules active.
      expect(m.isIgnored('node_modules', isDir: true), isTrue);
      expect(m.isIgnored('app/node_modules/pkg/i.js', isDir: false), isTrue);
      expect(m.isIgnored('old.bak', isDir: false), isTrue);
      expect(m.isIgnored('secret/plan.md', isDir: false), isTrue);
      expect(m.isIgnored('x/secret/plan.md', isDir: false), isFalse);
      // Defaults still active.
      expect(m.isIgnored('.git/config', isDir: false), isTrue);
      expect(m.isIgnored('~\$doc.docx', isDir: false), isTrue);
      // Everything else kept.
      expect(m.isIgnored('src/app.dart', isDir: false), isFalse);
    });

    test('respects a custom ignore file name', () async {
      await File(p.join(tmp.path, 'my-ignores')).writeAsString('*.iso\n');
      final m = await IgnoreMatcher.fromSharedDir(tmp.path, 'my-ignores');
      expect(m.isIgnored('disk.iso', isDir: false), isTrue);
    });
  });
}
