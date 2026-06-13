/// Unit tests for the three-way planner (DESIGN.md §3 / §4.8).
library;

import 'package:sync_engine/src/merge.dart';
import 'package:sync_engine/src/models.dart';
import 'package:test/test.dart';

// --- helpers ---------------------------------------------------------------

const h1 = 'a000000000000000000000000000000000000001';
const h2 = 'a000000000000000000000000000000000000002';
const h3 = 'a000000000000000000000000000000000000003';
const h4 = 'a000000000000000000000000000000000000004';

FileEntry fe(String path, String hash, [EntryMode mode = EntryMode.regular]) =>
    FileEntry(path: path, hash: hash, mode: mode);

TreeState tree(Iterable<FileEntry> entries) =>
    {for (final e in entries) e.path: e};

/// Test namer implementing the §3 numbering rule on a fixed marker:
/// `name (conflict).ext`, then ` -2`, ` -3`… while `exists` says taken.
String testNamer(String original, bool Function(String) exists) {
  final slash = original.lastIndexOf('/');
  final dir = slash < 0 ? '' : original.substring(0, slash + 1);
  final base = slash < 0 ? original : original.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  final stem = dot <= 0 ? base : base.substring(0, dot);
  final ext = dot <= 0 ? '' : base.substring(dot);
  var candidate = '$dir$stem (conflict)$ext';
  var n = 2;
  while (exists(candidate)) {
    candidate = '$dir$stem (conflict -$n)$ext';
    n++;
  }
  return candidate;
}

SyncPlan plan({
  TreeState base = const {},
  TreeState local = const {},
  TreeState remote = const {},
  Set<String> frozen = const {},
  String Function(String, bool Function(String))? namer,
}) =>
    planSync(
      base: base,
      local: local,
      remote: remote,
      frozenPaths: frozen,
      conflictNamer: namer ?? testNamer,
    );

void expectNoActions(SyncPlan p) {
  expect(p.downloads, isEmpty);
  expect(p.localDeletes, isEmpty);
  expect(p.conflictCopies, isEmpty);
  expect(p.deleteConflicts, isEmpty);
}

List<String> downloadPaths(SyncPlan p) =>
    p.downloads.map((d) => d.path).toList();

// --- table-driven cases for the seven §3 rows -------------------------------

class _Row {
  final String name;
  final FileEntry? b, l, r;
  final Map<String, String> mergedHashes; // path -> hash expected in merged
  final List<String> downloads;
  final List<String> localDeletes;
  final List<String> conflictCopyTargets; // expected copyPath values
  final List<String> deleteConflicts;
  final bool hasRemoteChanges;

  const _Row(
    this.name, {
    this.b,
    this.l,
    this.r,
    required this.mergedHashes,
    this.downloads = const [],
    this.localDeletes = const [],
    this.conflictCopyTargets = const [],
    this.deleteConflicts = const [],
    required this.hasRemoteChanges,
  });
}

void main() {
  group('§3 decision table (single path f.txt)', () {
    const p = 'f.txt';
    const copy = 'f (conflict).txt';
    final rows = [
      // Row 1: l==b && r==b → no change.
      _Row('1 unchanged',
          b: fe(p, h1),
          l: fe(p, h1),
          r: fe(p, h1),
          mergedHashes: {p: h1},
          hasRemoteChanges: false),
      // Row 2: l!=b && r==b → local wins.
      _Row('2 local modify',
          b: fe(p, h1),
          l: fe(p, h2),
          r: fe(p, h1),
          mergedHashes: {p: h2},
          hasRemoteChanges: true),
      _Row('2 local create',
          l: fe(p, h2), mergedHashes: {p: h2}, hasRemoteChanges: true),
      _Row('2 local delete (uploaded delete)',
          b: fe(p, h1),
          r: fe(p, h1),
          mergedHashes: {},
          hasRemoteChanges: true),
      // Row 3: l==b && r!=b → remote wins.
      _Row('3 remote modify → download',
          b: fe(p, h1),
          l: fe(p, h1),
          r: fe(p, h2),
          mergedHashes: {p: h2},
          downloads: [p],
          hasRemoteChanges: false),
      _Row('3 remote create → download',
          r: fe(p, h2),
          mergedHashes: {p: h2},
          downloads: [p],
          hasRemoteChanges: false),
      _Row('3 remote delete → localDelete',
          b: fe(p, h1),
          l: fe(p, h1),
          mergedHashes: {},
          localDeletes: [p],
          hasRemoteChanges: false),
      // Row 4: l!=b && r!=b && l==r → same change, base-only update.
      _Row('4 identical modification on both sides',
          b: fe(p, h1),
          l: fe(p, h2),
          r: fe(p, h2),
          mergedHashes: {p: h2},
          hasRemoteChanges: false),
      _Row('4 deleted on both sides',
          b: fe(p, h1), mergedHashes: {}, hasRemoteChanges: false),
      // Row 5: local delete vs remote modify → remote kept + record.
      _Row('5 local delete vs remote modify',
          b: fe(p, h1),
          r: fe(p, h2),
          mergedHashes: {p: h2},
          downloads: [p],
          deleteConflicts: [p],
          hasRemoteChanges: false),
      // Row 6: local modify vs remote delete → conflict copy survives.
      _Row('6 local modify vs remote delete',
          b: fe(p, h1),
          l: fe(p, h2),
          mergedHashes: {copy: h2},
          localDeletes: [p],
          conflictCopyTargets: [copy],
          hasRemoteChanges: true),
      // Row 7: divergent modification → remote wins + conflict copy.
      _Row('7 divergent modification',
          b: fe(p, h1),
          l: fe(p, h2),
          r: fe(p, h3),
          mergedHashes: {p: h3, copy: h2},
          downloads: [p],
          conflictCopyTargets: [copy],
          hasRemoteChanges: true),
    ];

    for (final row in rows) {
      test(row.name, () {
        final result = plan(
          base: tree([if (row.b != null) row.b!]),
          local: tree([if (row.l != null) row.l!]),
          remote: tree([if (row.r != null) row.r!]),
        );
        expect(result.mergedTree.map((k, v) => MapEntry(k, v.hash)),
            equals(row.mergedHashes));
        expect(downloadPaths(result), equals(row.downloads));
        expect(result.localDeletes, equals(row.localDeletes));
        expect(result.conflictCopies.map((c) => c.copyPath).toList(),
            equals(row.conflictCopyTargets));
        expect(result.deleteConflicts.map((c) => c.path).toList(),
            equals(row.deleteConflicts));
        expect(result.hasRemoteChanges, row.hasRemoteChanges);
      });
    }

    test('merged entries carry path matching their merged key', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h2)]),
        remote: tree([fe(p, h3)]),
      );
      result.mergedTree.forEach((key, entry) => expect(entry.path, key));
    });

    test('row 6 conflict copy preserves local hash and mode', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h2, EntryMode.executable)]),
        remote: const {},
      );
      final c = result.conflictCopies.single;
      expect(c.originalPath, p);
      expect(c.localHash, h2);
      expect(c.mode, EntryMode.executable);
      expect(result.mergedTree[c.copyPath]!.mode, EntryMode.executable);
      // The original local file is removed only after the copy exists.
      expect(result.localDeletes, [p]);
      expect(result.mergedTree.containsKey(p), isFalse);
    });

    test('row 7 download carries remote hash and mode', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h2)]),
        remote: tree([fe(p, h3, EntryMode.executable)]),
      );
      final d = result.downloads.single;
      expect(d.path, p);
      expect(d.hash, h3);
      expect(d.mode, EntryMode.executable);
      // No localDelete: the download overwrites the path in place.
      expect(result.localDeletes, isEmpty);
    });
  });

  group('first sync (base empty)', () {
    test('local-only file is uploaded, remote-only file is downloaded', () {
      final result = plan(
        local: tree([fe('mine.txt', h1)]),
        remote: tree([fe('theirs.txt', h2)]),
      );
      expect(result.mergedTree.keys, containsAll(['mine.txt', 'theirs.txt']));
      expect(result.mergedTree['mine.txt']!.hash, h1);
      expect(result.mergedTree['theirs.txt']!.hash, h2);
      expect(downloadPaths(result), ['theirs.txt']);
      expect(result.localDeletes, isEmpty);
      expect(result.conflictCopies, isEmpty);
      expect(result.deleteConflicts, isEmpty);
      expect(result.hasRemoteChanges, isTrue); // mine.txt must be pushed
    });

    test('same path, same content on both sides → no conflict, no action', () {
      final result = plan(
        local: tree([fe('a.txt', h1)]),
        remote: tree([fe('a.txt', h1)]),
      );
      expect(result.mergedTree['a.txt']!.hash, h1);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
      expect(result.isNoop, isTrue);
    });

    test('same path, different content → create conflict (§10.3)', () {
      final result = plan(
        local: tree([fe('a.txt', h1)]),
        remote: tree([fe('a.txt', h2)]),
      );
      // Remote wins the path; local content survives as a conflict copy.
      expect(result.mergedTree['a.txt']!.hash, h2);
      expect(downloadPaths(result), ['a.txt']);
      final c = result.conflictCopies.single;
      expect(c.originalPath, 'a.txt');
      expect(c.copyPath, 'a (conflict).txt');
      expect(c.localHash, h1);
      expect(result.mergedTree['a (conflict).txt']!.hash, h1);
      expect(result.deleteConflicts, isEmpty);
      expect(result.hasRemoteChanges, isTrue); // copy must be pushed
    });
  });

  group('mode-only change (100644 → 100755)', () {
    const p = 'tool.sh';

    test('local mode flip with unchanged remote follows "local wins"', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h1, EntryMode.executable)]),
        remote: tree([fe(p, h1)]),
      );
      expect(result.mergedTree[p]!.mode, EntryMode.executable);
      expect(result.mergedTree[p]!.hash, h1);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isTrue); // mode change must be pushed
    });

    test('remote mode flip with unchanged local triggers a download', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h1)]),
        remote: tree([fe(p, h1, EntryMode.executable)]),
      );
      final d = result.downloads.single;
      expect(d.path, p);
      expect(d.hash, h1);
      expect(d.mode, EntryMode.executable);
      expect(result.mergedTree[p]!.mode, EntryMode.executable);
      expect(result.hasRemoteChanges, isFalse);
    });

    test('divergent mode/content change is a modify conflict', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h1, EntryMode.executable)]),
        remote: tree([fe(p, h2)]),
      );
      expect(result.mergedTree[p]!.hash, h2);
      expect(result.conflictCopies.single.localHash, h1);
      expect(result.conflictCopies.single.mode, EntryMode.executable);
    });
  });

  group('delete conflicts, both directions', () {
    test('local delete vs remote modify keeps the remote file (§10.2)', () {
      final result = plan(
        base: tree([fe('doc.txt', h1)]),
        local: const {},
        remote: tree([fe('doc.txt', h2)]),
      );
      expect(result.mergedTree['doc.txt']!.hash, h2);
      expect(downloadPaths(result), ['doc.txt']);
      expect(result.deleteConflicts.single.path, 'doc.txt');
      expect(result.conflictCopies, isEmpty);
      expect(result.localDeletes, isEmpty);
      expect(result.hasRemoteChanges, isFalse);
    });

    test('local modify vs remote delete keeps local content as copy (§10.2)',
        () {
      final result = plan(
        base: tree([fe('doc.txt', h1)]),
        local: tree([fe('doc.txt', h2)]),
        remote: const {},
      );
      expect(result.mergedTree.containsKey('doc.txt'), isFalse);
      final c = result.conflictCopies.single;
      expect(c.copyPath, 'doc (conflict).txt');
      expect(result.mergedTree[c.copyPath]!.hash, h2);
      expect(result.localDeletes, ['doc.txt']);
      expect(result.deleteConflicts, isEmpty);
      expect(result.downloads, isEmpty);
      expect(result.hasRemoteChanges, isTrue);
    });
  });

  group('conflict copy naming via exists()', () {
    test('candidate already on disk (local tree) → " -2" suffix', () {
      // Row 6 conflict on doc.txt while "doc (conflict).txt" already exists
      // locally (unchanged everywhere, so it stays put).
      final blocker = fe('doc (conflict).txt', h4);
      final result = plan(
        base: tree([fe('doc.txt', h1), blocker]),
        local: tree([fe('doc.txt', h2), blocker]),
        remote: tree([blocker]),
      );
      expect(result.conflictCopies.single.copyPath, 'doc (conflict -2).txt');
      expect(result.mergedTree['doc (conflict -2).txt']!.hash, h2);
      expect(result.mergedTree['doc (conflict).txt']!.hash, h4);
    });

    test('candidate occupied by an incoming remote file → " -2" suffix', () {
      // The blocker exists only on the remote: it is not on disk yet, but it
      // will be after apply and it occupies the merged tree.
      final result = plan(
        base: tree([fe('doc.txt', h1)]),
        local: tree([fe('doc.txt', h2)]),
        remote: tree([fe('doc.txt', h3), fe('doc (conflict).txt', h4)]),
      );
      expect(result.conflictCopies.single.copyPath, 'doc (conflict -2).txt');
      expect(result.mergedTree['doc (conflict).txt']!.hash, h4);
      expect(result.mergedTree['doc (conflict -2).txt']!.hash, h2);
    });

    test('copy path assigned earlier in the same plan blocks reuse', () {
      // Degenerate namer proposing the same first candidate for every file:
      // the second conflict must see the first copy in merged and step to -2.
      String fixedNamer(String original, bool Function(String) exists) {
        var candidate = 'CONFLICT.txt';
        var n = 2;
        while (exists(candidate)) {
          candidate = 'CONFLICT -$n.txt';
          n++;
        }
        return candidate;
      }

      final result = plan(
        base: tree([fe('a.txt', h1), fe('b.txt', h1)]),
        local: tree([fe('a.txt', h2), fe('b.txt', h2)]),
        remote: tree([fe('a.txt', h3), fe('b.txt', h3)]),
        namer: fixedNamer,
      );
      expect(result.conflictCopies.map((c) => c.copyPath).toSet(),
          {'CONFLICT.txt', 'CONFLICT -2.txt'});
      expect(result.mergedTree['CONFLICT.txt']!.hash, h2);
      expect(result.mergedTree['CONFLICT -2.txt']!.hash, h2);
    });

    test('namer receives the original path', () {
      String? seen;
      final result = plan(
        base: tree([fe('dir/x.txt', h1)]),
        local: tree([fe('dir/x.txt', h2)]),
        remote: tree([fe('dir/x.txt', h3)]),
        namer: (original, exists) {
          seen = original;
          return testNamer(original, exists);
        },
      );
      expect(seen, 'dir/x.txt');
      expect(result.conflictCopies.single.copyPath, 'dir/x (conflict).txt');
    });
  });

  group('frozen paths', () {
    const p = 'busy.txt';

    test('remote modified: merged[p]=r, no download, base must not advance',
        () {
      // Caller contract: l := b before calling.
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h1)]),
        remote: tree([fe(p, h2)]),
        frozen: {p},
      );
      // Remote state preserved verbatim in the pushed tree...
      expect(result.mergedTree[p]!.hash, h2);
      // ...but nothing touches the local file this cycle.
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
      // The engine reverts frozen paths to b before persisting base, so the
      // next cycle re-evaluates l(actual) vs b vs r=h2 normally.
    });

    test('remote deleted: p absent from merged, local file not deleted', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h1)]),
        remote: const {},
        frozen: {p},
      );
      expect(result.mergedTree.containsKey(p), isFalse);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
    });

    test('remote added a file that is locally unstable: no download', () {
      // b absent, caller set l := b (absent), remote created the path.
      final result = plan(
        remote: tree([fe(p, h2)]),
        frozen: {p},
      );
      expect(result.mergedTree[p]!.hash, h2);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
    });

    test('remote unchanged: merged keeps b, plan is a noop', () {
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h1)]),
        remote: tree([fe(p, h1)]),
        frozen: {p},
      );
      expect(result.mergedTree[p]!.hash, h1);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
      expect(result.isNoop, isTrue);
    });

    test('defensive: even if caller forgot l := b, no action is produced', () {
      // l differs from b here; the planner must still keep its guarantee of
      // zero actions and merged[p] == r for frozen paths.
      final result = plan(
        base: tree([fe(p, h1)]),
        local: tree([fe(p, h3)]),
        remote: tree([fe(p, h2)]),
        frozen: {p},
      );
      expect(result.mergedTree[p]!.hash, h2);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
    });

    test('frozen path never appears in any action list of a mixed plan', () {
      final result = plan(
        base: tree([fe('busy.txt', h1), fe('calm.txt', h1)]),
        local: tree([fe('busy.txt', h1), fe('calm.txt', h1)]),
        remote: tree([fe('busy.txt', h2)]), // busy modified, calm deleted
        frozen: {'busy.txt'},
      );
      // Non-frozen path proceeds normally.
      expect(result.localDeletes, ['calm.txt']);
      // Frozen path produced nothing.
      expect(downloadPaths(result), isNot(contains('busy.txt')));
      expect(result.conflictCopies, isEmpty);
      expect(result.deleteConflicts, isEmpty);
      expect(result.mergedTree['busy.txt']!.hash, h2);
    });

    test('frozen local-only change is not pushed (merged tracks remote)', () {
      // Local created an unstable file; caller set l := b = absent.
      final result = plan(
        local: const {}, // l := b
        remote: tree([fe('other.txt', h3)]),
        frozen: {'new.txt'},
      );
      expect(result.mergedTree.containsKey('new.txt'), isFalse);
      expect(result.hasRemoteChanges, isFalse);
    });
  });

  group('frozen paths sourced from §12 ignored reconcile', () {
    // The engine freezes every base/remote path matching the ignore rules.
    // Unlike unstable paths, these never appear in `local` (the scanner
    // prunes them), so both "base has it, remote lost it" and "remote has
    // it, base never did" boundaries must hold without l := b substitution.
    const ignored = 'build/x.txt';

    test('in base, absent from remote and local: zero actions, no push', () {
      final result = plan(
        base: tree([fe(ignored, h1), fe('keep.txt', h2)]),
        local: tree([fe('keep.txt', h2)]), // ignored path pruned from scan
        remote: tree([fe('keep.txt', h2)]),
        frozen: {ignored},
      );
      // Not resurrected, not deleted anywhere — simply out of the cycle.
      expect(result.mergedTree.containsKey(ignored), isFalse);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
      expect(result.isNoop, isTrue);
    });

    test('in remote, absent from base and local: kept remotely, no download',
        () {
      final result = plan(
        base: tree([fe('keep.txt', h2)]),
        local: tree([fe('keep.txt', h2)]),
        remote: tree([fe(ignored, h1), fe('keep.txt', h2)]),
        frozen: {ignored},
      );
      // The remote copy stays in the pushed tree but the local disk is
      // never touched (no download → no phantom delete next cycle).
      expect(result.mergedTree[ignored]!.hash, h1);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
    });

    test('in base and remote with diverged hash, pruned locally: '
        'remote preserved verbatim, zero actions', () {
      final result = plan(
        base: tree([fe(ignored, h1)]),
        local: const {},
        remote: tree([fe(ignored, h3)]),
        frozen: {ignored},
      );
      expect(result.mergedTree[ignored]!.hash, h3);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
    });
  });

  group('computeBaseToStore', () {
    test('empty revert set: result equals merged', () {
      final merged = tree([fe('a.txt', h1), fe('b.txt', h2)]);
      final result = computeBaseToStore(merged, tree([fe('a.txt', h3)]), {});
      expect(result, equals(merged));
    });

    test('revert path present in base: base value restored over merged', () {
      final result = computeBaseToStore(
        tree([fe('skip.txt', h2), fe('ok.txt', h3)]), // merged holds r
        tree([fe('skip.txt', h1), fe('ok.txt', h1)]),
        {'skip.txt'},
      );
      expect(result['skip.txt']!.hash, h1); // not advanced to h2
      expect(result['ok.txt']!.hash, h3); // untouched path advances
    });

    test('revert path absent from base: dropped from the stored tree', () {
      // E.g. a skipped download of a remote-new file: the local disk never
      // saw it, so the base must not claim it exists.
      final result = computeBaseToStore(
        tree([fe('new-remote.txt', h2)]),
        const {},
        {'new-remote.txt'},
      );
      expect(result.containsKey('new-remote.txt'), isFalse);
    });

    test('revert path absent from merged but present in base: restored', () {
      // E.g. a skipped localDelete (remote deleted, local file was edited
      // during sync): merged lacks p, but the base must keep b so the next
      // cycle sees "both sides changed" instead of "local recreated".
      final result = computeBaseToStore(
        const {},
        tree([fe('gone-remote.txt', h1)]),
        {'gone-remote.txt'},
      );
      expect(result['gone-remote.txt']!.hash, h1);
    });

    test('mode-only difference is also reverted', () {
      final result = computeBaseToStore(
        tree([fe('tool.sh', h1, EntryMode.executable)]),
        tree([fe('tool.sh', h1)]),
        {'tool.sh'},
      );
      expect(result['tool.sh']!.mode, EntryMode.regular);
    });

    test('mixed frozen + skipped + ignored revert in one call', () {
      final merged = tree([
        fe('frozen.txt', h2),
        fe('skipped.txt', h2),
        fe('ignored.txt', h2),
        fe('normal.txt', h2),
      ]);
      final base = tree([
        fe('frozen.txt', h1),
        fe('ignored.txt', h1),
        fe('normal.txt', h1),
      ]);
      final result = computeBaseToStore(
          merged, base, {'frozen.txt', 'skipped.txt', 'ignored.txt'});
      expect(result['frozen.txt']!.hash, h1);
      expect(result.containsKey('skipped.txt'), isFalse); // no base entry
      expect(result['ignored.txt']!.hash, h1);
      expect(result['normal.txt']!.hash, h2);
    });

    test('does not mutate its inputs', () {
      final merged = tree([fe('a.txt', h2)]);
      final base = tree([fe('a.txt', h1), fe('b.txt', h1)]);
      computeBaseToStore(merged, base, {'a.txt', 'b.txt'});
      expect(merged['a.txt']!.hash, h2);
      expect(base.length, 2);
    });
  });

  group('hasRemoteChanges', () {
    test('false when only local-facing actions exist (pure download)', () {
      final result = plan(
        base: tree([fe('a.txt', h1)]),
        local: tree([fe('a.txt', h1)]),
        remote: tree([fe('a.txt', h2), fe('b.txt', h3)]),
      );
      expect(result.hasRemoteChanges, isFalse);
      expect(downloadPaths(result), ['a.txt', 'b.txt']);
    });

    test('true when the merged tree differs from remote (pure upload)', () {
      final result = plan(
        base: tree([fe('a.txt', h1)]),
        local: tree([fe('a.txt', h2)]),
        remote: tree([fe('a.txt', h1)]),
      );
      expect(result.hasRemoteChanges, isTrue);
      expectNoActions(result);
    });

    test('true on mode-only difference between merged and remote', () {
      final result = plan(
        base: tree([fe('a.sh', h1)]),
        local: tree([fe('a.sh', h1, EntryMode.executable)]),
        remote: tree([fe('a.sh', h1)]),
      );
      expect(result.hasRemoteChanges, isTrue);
    });
  });

  group('edge cases', () {
    test('all trees empty → empty noop plan', () {
      final result = plan();
      expect(result.mergedTree, isEmpty);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
      expect(result.isNoop, isTrue);
    });

    test('base-only path (deleted on both sides) leaves no trace', () {
      final result = plan(base: tree([fe('gone.txt', h1)]));
      expect(result.mergedTree, isEmpty);
      expectNoActions(result);
      expect(result.hasRemoteChanges, isFalse);
    });

    test('multi-path plan combines independent rows deterministically', () {
      final result = plan(
        base: tree([fe('keep.txt', h1), fe('up.txt', h1), fe('down.txt', h1)]),
        local:
            tree([fe('keep.txt', h1), fe('up.txt', h2), fe('down.txt', h1)]),
        remote:
            tree([fe('keep.txt', h1), fe('up.txt', h1), fe('down.txt', h3)]),
      );
      expect(result.mergedTree['keep.txt']!.hash, h1);
      expect(result.mergedTree['up.txt']!.hash, h2);
      expect(result.mergedTree['down.txt']!.hash, h3);
      expect(downloadPaths(result), ['down.txt']);
      expect(result.hasRemoteChanges, isTrue);
    });
  });
}
