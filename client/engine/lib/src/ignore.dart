/// Ignore rules for the sync engine (DESIGN.md §4.4, requirements §12).
///
/// Implements a strict subset of gitignore semantics:
///
/// * `#` starts a comment line; blank lines are skipped.
/// * A trailing `/` makes the pattern match directories only.
/// * A pattern containing a non-trailing `/` is anchored to the shared root;
///   otherwise it matches the basename at any depth.
/// * `*` matches any run of characters except `/`; `?` matches exactly one
///   character except `/`; a `**` segment crosses directory levels.
/// * An ignored directory ignores everything beneath it.
/// * Matching is case sensitive.
/// * `!` negation is **not** supported; lines starting with `!` are dropped.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Matches relative paths against a list of `.syncignore`-style patterns.
class IgnoreMatcher {
  /// Built-in rules that are always sensible for a synced shared directory
  /// (engine metadata, VCS internals, OS droppings and editor temp files).
  static const List<String> defaults = [
    '.sync/',
    '.sync-trash/',
    '.git/',
    '~\$*',
    '*.tmp',
    '*.swp',
    '*.lock',
    'Thumbs.db',
    '.DS_Store',
    'desktop.ini',
  ];

  final List<_Rule> _rules;

  /// Builds a matcher from raw `.syncignore` lines.
  ///
  /// Comments, blank lines and unsupported `!`-negation lines are filtered
  /// out here, so callers may pass file content verbatim. [defaults] are NOT
  /// added implicitly — use [fromSharedDir] for that.
  IgnoreMatcher(List<String> patterns)
      : _rules = patterns.map(_Rule.tryParse).whereType<_Rule>().toList();

  /// Builds a matcher from [defaults] plus the content of
  /// `<sharedDir>/<ignoreFileName>`. A missing file yields defaults only.
  static Future<IgnoreMatcher> fromSharedDir(
      String sharedDir, String ignoreFileName) async {
    final file = File(p.join(sharedDir, ignoreFileName));
    var lines = const <String>[];
    if (await file.exists()) {
      lines = await file.readAsLines();
    }
    return IgnoreMatcher([...defaults, ...lines]);
  }

  /// Whether [relativePath] (forward slashes, relative to the shared root)
  /// is ignored. [isDir] must be true when the path denotes a directory —
  /// directory-only rules (trailing `/`) match only then.
  ///
  /// An ignored ancestor directory ignores the whole subtree, so callers
  /// pruning a tree walk only need to ask once per directory.
  bool isIgnored(String relativePath, {required bool isDir}) {
    final path = _normalize(relativePath);
    if (path.isEmpty) return false;

    final segments = path.split('/');
    // Ancestor directories first: ignored dir => entire subtree ignored.
    for (var i = 1; i < segments.length; i++) {
      if (_matchesAny(segments.sublist(0, i).join('/'), isDir: true)) {
        return true;
      }
    }
    return _matchesAny(path, isDir: isDir);
  }

  bool _matchesAny(String path, {required bool isDir}) =>
      _rules.any((r) => r.matches(path, isDir: isDir));

  static String _normalize(String path) {
    var s = path.trim();
    if (s.startsWith('./')) s = s.substring(2);
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// One parsed ignore pattern.
class _Rule {
  /// Trailing `/` in the source pattern: matches directories only.
  final bool dirOnly;

  /// Pattern had a non-trailing `/`: matched against the full relative path
  /// from the shared root; otherwise matched against the basename.
  final bool anchored;

  final RegExp _regex;

  _Rule._(this.dirOnly, this.anchored, this._regex);

  /// Returns null for comments, blank lines and unsupported `!` negation.
  static _Rule? tryParse(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    // Negation is out of contract; dropping the line keeps the positive
    // rules in effect instead of accidentally matching a literal '!'.
    if (trimmed.startsWith('!')) return null;

    var pat = trimmed;
    final dirOnly = pat.endsWith('/');
    if (dirOnly) pat = pat.substring(0, pat.length - 1);
    var anchored = pat.contains('/');
    if (pat.startsWith('/')) {
      pat = pat.substring(1);
      anchored = true;
    }
    if (pat.isEmpty) return null;

    return _Rule._(dirOnly, anchored, RegExp('^${_globToRegex(pat)}\$'));
  }

  bool matches(String path, {required bool isDir}) {
    if (dirOnly && !isDir) return false;
    final candidate = anchored ? path : path.split('/').last;
    return _regex.hasMatch(candidate);
  }

  /// Translates the glob subset to a regex body. A `**` occupying a whole
  /// segment crosses levels (`**/`, `/**/`, trailing `/**`); any other run
  /// of `*` stays within one segment.
  static String _globToRegex(String pat) {
    final sb = StringBuffer();
    var i = 0;
    while (i < pat.length) {
      final c = pat[i];
      if (c == '*') {
        var j = i;
        while (j < pat.length && pat[j] == '*') {
          j++;
        }
        final wholeSegment = (i == 0 || pat[i - 1] == '/') &&
            (j == pat.length || pat[j] == '/') &&
            j - i >= 2;
        if (wholeSegment) {
          if (j == pat.length) {
            sb.write('.*'); // trailing '/**': everything below the prefix
            i = j;
          } else {
            sb.write('(?:[^/]+/)*'); // '**/': zero or more directories
            i = j + 1; // consume the segment's trailing '/'
          }
        } else {
          sb.write('[^/]*');
          i = j;
        }
      } else if (c == '?') {
        sb.write('[^/]');
        i++;
      } else {
        sb.write(RegExp.escape(c));
        i++;
      }
    }
    return sb.toString();
  }
}
