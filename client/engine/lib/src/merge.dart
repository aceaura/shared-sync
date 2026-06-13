/// Three-way sync planner (DESIGN.md §3 / §4.8).
///
/// Pure function, zero IO. Given the base / local / remote tree snapshots it
/// decides the next authoritative tree to push and every action the engine
/// must apply to the working directory.
library;

import 'models.dart';

/// Plans one sync cycle from the three tree snapshots.
///
/// [base] is the last synced tree (index.db), [local] the current scan and
/// [remote] the fetched remote tree. Two entries are "equal" when both hash
/// and mode match ([FileEntry.sameContent]); a mode-only change
/// (100644 ↔ 100755) therefore follows the modification rules.
///
/// Decision table for every path `p` in `union(base, local, remote)`
/// (`b`/`l`/`r` are the entries at `p`, `null` means absent):
///
/// | condition                          | result                                                |
/// |------------------------------------|-------------------------------------------------------|
/// | l==b && r==b                       | unchanged: merged[p]=r                                |
/// | l!=b && r==b                       | local wins: merged[p]=l (l==null → uploaded delete)   |
/// | l==b && r!=b                       | remote wins: merged[p]=r + download, or localDelete   |
/// | l!=b && r!=b && l==r               | same change on both sides: merged[p]=l, no action     |
/// | l!=b && r!=b && l==null            | delete/modify conflict: merged[p]=r + download +      |
/// |                                    | [DeleteConflict] record                               |
/// | l!=b && r!=b && r==null            | modify/delete conflict: p leaves merged, local content|
/// |                                    | survives as conflict copy + localDelete of p          |
/// | l!=b && r!=b, both non-null, l!=r  | modify conflict: merged[p]=r + download, local content|
/// |                                    | survives as conflict copy                             |
///
/// An empty [base] needs no special casing: first-sync behaviour (upload,
/// download, identical create, create conflict per requirements §10.3) falls
/// out of the table.
///
/// Frozen paths ([frozenPaths] — locally unstable files): the caller has
/// already substituted `l := b` before calling. Independently of that, the
/// planner guarantees that a frozen path produces **no** download /
/// localDelete / conflictCopy / deleteConflict action and that
/// `merged[p] == r` (absent when `r` is absent) — the remote state is never
/// rolled back and the local file is left untouched for this cycle. The
/// engine must not advance base for a frozen path whose remote side changed:
/// it persists the merged tree with frozen paths reverted to `b`, so the next
/// cycle re-evaluates them with an unchanged base.
///
/// Conflict copy names come from [conflictNamer]. The `exists` predicate the
/// planner passes to it reports a candidate as taken when it is already on
/// disk (present in [local]), present in [remote] (it will be on disk after
/// apply), or already occupied in the merged tree — which includes copy paths
/// assigned earlier in the same plan.
///
/// Non-obvious output contract: for the modify/delete conflict row the
/// original path is also added to [SyncPlan.localDeletes]. The apply phase
/// writes conflict copies before any destructive action (DESIGN §2 step 7),
/// so the copy-then-delete pair implements the "rename to conflict copy"
/// semantics of §3.
SyncPlan planSync({
  required TreeState base,
  required TreeState local,
  required TreeState remote,
  required Set<String> frozenPaths,
  required String Function(String originalPath, bool Function(String) exists)
      conflictNamer,
}) {
  final merged = <String, FileEntry>{};
  final downloads = <DownloadAction>[];
  final localDeletes = <String>[];
  final conflictCopies = <ConflictCopy>[];
  final deleteConflicts = <DeleteConflict>[];

  // A conflict copy may not land on a path that is on disk now (local), will
  // be on disk after apply (remote) or is already claimed in merged (incl.
  // copy paths assigned earlier in this very plan).
  bool taken(String p) =>
      merged.containsKey(p) || local.containsKey(p) || remote.containsKey(p);

  FileEntry copyEntryOf(FileEntry l, String copyPath) =>
      FileEntry(path: copyPath, hash: l.hash, mode: l.mode);

  // Sorted iteration keeps the plan deterministic for identical inputs.
  final paths = <String>{...base.keys, ...local.keys, ...remote.keys}.toList()
    ..sort();

  for (final p in paths) {
    final b = base[p];
    final l = local[p];
    final r = remote[p];

    if (frozenPaths.contains(p)) {
      // Frozen: keep the remote state as-is and touch nothing locally; the
      // path is re-evaluated next cycle against an un-advanced base.
      if (r != null) merged[p] = r;
      continue;
    }

    final localChanged = !_same(l, b);
    final remoteChanged = !_same(r, b);

    if (!localChanged && !remoteChanged) {
      // Unchanged everywhere (b==l==r, all non-null when present in union).
      if (r != null) merged[p] = r;
      continue;
    }

    if (!remoteChanged) {
      // Local wins. l == null uploads the deletion (p leaves merged).
      if (l != null) merged[p] = l;
      continue;
    }

    if (!localChanged) {
      // Remote wins.
      if (r != null) {
        merged[p] = r;
        downloads.add(DownloadAction(path: p, hash: r.hash, mode: r.mode));
      } else {
        localDeletes.add(p);
      }
      continue;
    }

    // Both sides changed relative to base.
    if (_same(l, r)) {
      // Identical change (or deleted on both sides): only base advances.
      if (l != null) merged[p] = l;
      continue;
    }

    if (l == null) {
      // Local delete vs remote modify: remote wins, file is written back.
      merged[p] = r!;
      downloads.add(DownloadAction(path: p, hash: r.hash, mode: r.mode));
      deleteConflicts.add(DeleteConflict(path: p));
      continue;
    }

    if (r == null) {
      // Local modify vs remote delete: accept the delete; local content is
      // preserved as a conflict copy (copied first, original deleted after).
      final copyPath = conflictNamer(p, taken);
      merged[copyPath] = copyEntryOf(l, copyPath);
      conflictCopies.add(ConflictCopy(
        originalPath: p,
        copyPath: copyPath,
        localHash: l.hash,
        mode: l.mode,
      ));
      localDeletes.add(p);
      continue;
    }

    // Divergent modification (or create/create with different content):
    // remote wins the path, local content survives as a conflict copy that
    // is uploaded with the merged tree.
    final copyPath = conflictNamer(p, taken);
    merged[copyPath] = copyEntryOf(l, copyPath);
    conflictCopies.add(ConflictCopy(
      originalPath: p,
      copyPath: copyPath,
      localHash: l.hash,
      mode: l.mode,
    ));
    merged[p] = r;
    downloads.add(DownloadAction(path: p, hash: r.hash, mode: r.mode));
  }

  return SyncPlan(
    mergedTree: merged,
    downloads: downloads,
    localDeletes: localDeletes,
    conflictCopies: conflictCopies,
    deleteConflicts: deleteConflicts,
    hasRemoteChanges: !treesEqual(merged, remote),
  );
}

/// Three-way equality: both absent, or same hash + mode.
bool _same(FileEntry? a, FileEntry? b) =>
    a == null ? b == null : a.sameContent(b);

/// The base tree to persist after a sync cycle (DESIGN.md §2 step 11).
///
/// Starts from [merged] and reverts every path in [revertPaths] to its old
/// [base] value: the entry is restored when `base` holds one, removed from
/// the result otherwise. Pure function, zero IO.
///
/// [revertPaths] must contain every path whose local working-directory state
/// was **not** brought in line with [merged] this cycle:
///
/// * frozen paths (locally unstable files, planner kept `merged[p] == r`),
/// * paths whose download / localDelete was skipped by the apply-phase
///   safety recheck ("modified during sync"),
/// * ignored paths reconciled via the frozen mechanism (requirements §12).
///
/// Reverting keeps the invariant "base only advances past states the local
/// disk has actually seen": the next cycle re-runs the three-way decision
/// with an un-advanced base, falling into the conflict-copy rows instead of
/// the data-losing "local delete wins" row.
TreeState computeBaseToStore(
  TreeState merged,
  TreeState base,
  Set<String> revertPaths,
) {
  final result = Map.of(merged);
  for (final path in revertPaths) {
    final b = base[path];
    if (b != null) {
      result[path] = b;
    } else {
      result.remove(path);
    }
  }
  return result;
}
