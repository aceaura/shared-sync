/// Client configuration, persisted as `<sharedDir>/.sync/config.json`.
/// See DESIGN.md §4.2 and the conflict-copy naming contract in §3.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Immutable sync-client configuration.
class SyncConfig {
  /// Absolute path of the shared directory being synced.
  final String sharedDir;

  /// Git URL of the server repo (`http(s)://`, `file://` or a local path).
  final String serverUrl;

  /// Stable identifier of this client (e.g. host name); appears in commit
  /// messages and conflict-copy file names.
  final String clientId;

  final int syncIntervalSeconds;
  final int fileStableDelaySeconds;
  final int maxPushRetries;

  /// Template for conflict-copy file names. Variables: `{name}` (base name
  /// without extension), `{client}`, `{time}` (`yyyy-MM-dd HH-mm`, local),
  /// `{ext}` (extension including the dot, empty when none).
  final String conflictNameTemplate;

  final String ignoreFileName;

  /// Days of daily log files (`sync-YYYYMMDD.log`) to keep; older ones are
  /// pruned at the end of each sync cycle so a long-running / offline client
  /// does not accumulate logs without bound.
  final int logRetentionDays;

  static const int defaultSyncIntervalSeconds = 30;
  static const int defaultFileStableDelaySeconds = 2;
  static const int defaultMaxPushRetries = 3;
  static const String defaultConflictNameTemplate =
      '{name} (conflict from {client} {time}){ext}';
  static const String defaultIgnoreFileName = '.syncignore';
  static const int defaultLogRetentionDays = 14;

  const SyncConfig({
    required this.sharedDir,
    required this.serverUrl,
    required this.clientId,
    this.syncIntervalSeconds = defaultSyncIntervalSeconds,
    this.fileStableDelaySeconds = defaultFileStableDelaySeconds,
    this.maxPushRetries = defaultMaxPushRetries,
    this.conflictNameTemplate = defaultConflictNameTemplate,
    this.ignoreFileName = defaultIgnoreFileName,
    this.logRetentionDays = defaultLogRetentionDays,
  });

  String get syncDir => p.join(sharedDir, '.sync');
  String get repoDir => p.join(syncDir, 'repo');
  String get dbPath => p.join(syncDir, 'index.db');
  String get stagingDir => p.join(syncDir, 'staging');
  String get logsDir => p.join(syncDir, 'logs');
  String get conflictsPath => p.join(syncDir, 'conflicts.jsonl');

  String get _configPath => p.join(syncDir, 'config.json');

  Map<String, dynamic> toJson() => {
        'sharedDir': sharedDir,
        'serverUrl': serverUrl,
        'clientId': clientId,
        'syncIntervalSeconds': syncIntervalSeconds,
        'fileStableDelaySeconds': fileStableDelaySeconds,
        'maxPushRetries': maxPushRetries,
        'conflictNameTemplate': conflictNameTemplate,
        'ignoreFileName': ignoreFileName,
        'logRetentionDays': logRetentionDays,
      };

  factory SyncConfig.fromJson(Map<String, dynamic> json) => SyncConfig(
        sharedDir: json['sharedDir'] as String,
        serverUrl: json['serverUrl'] as String,
        clientId: json['clientId'] as String,
        syncIntervalSeconds: (json['syncIntervalSeconds'] as num?)?.toInt() ??
            defaultSyncIntervalSeconds,
        fileStableDelaySeconds:
            (json['fileStableDelaySeconds'] as num?)?.toInt() ??
                defaultFileStableDelaySeconds,
        maxPushRetries:
            (json['maxPushRetries'] as num?)?.toInt() ?? defaultMaxPushRetries,
        conflictNameTemplate: json['conflictNameTemplate'] as String? ??
            defaultConflictNameTemplate,
        ignoreFileName:
            json['ignoreFileName'] as String? ?? defaultIgnoreFileName,
        logRetentionDays: (json['logRetentionDays'] as num?)?.toInt() ??
            defaultLogRetentionDays,
      );

  /// Reads `<sharedDir>/.sync/config.json`; returns null when the file does
  /// not exist. Malformed content throws (caller decides how to surface it).
  static Future<SyncConfig?> load(String sharedDir) async {
    final file = File(p.join(sharedDir, '.sync', 'config.json'));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return SyncConfig.fromJson(json);
  }

  /// Persists this config, creating `.sync/` when needed. The write is
  /// atomic (tmp file + rename) so a crash never leaves a torn config.
  Future<void> save() async {
    await Directory(syncDir).create(recursive: true);
    final tmp = File('$_configPath.tmp');
    const encoder = JsonEncoder.withIndent('  ');
    await tmp.writeAsString('${encoder.convert(toJson())}\n', flush: true);
    await tmp.rename(_configPath);
  }

  /// Builds the conflict-copy path for [originalPath] (forward-slash relative
  /// path) per DESIGN.md §3.
  ///
  /// The copy stays in the same directory. When [exists] reports the
  /// candidate as taken (on disk or in the merged tree), ` -2`, ` -3`, … is
  /// appended right after the `{time}` value (i.e. before `{ext}` in the
  /// default template) until a free name is found.
  String conflictCopyPath(
      String originalPath, DateTime now, bool Function(String) exists) {
    final dir = p.posix.dirname(originalPath);
    final base = p.posix.basename(originalPath);
    final ext = p.posix.extension(base);
    final name = ext.isEmpty ? base : base.substring(0, base.length - ext.length);
    final time = _conflictTime(now);
    for (var i = 1;; i++) {
      final timeWithSuffix = i == 1 ? time : '$time -$i';
      final fileName = conflictNameTemplate
          .replaceAll('{name}', name)
          .replaceAll('{client}', clientId)
          .replaceAll('{time}', timeWithSuffix)
          .replaceAll('{ext}', ext);
      final candidate = dir == '.' ? fileName : '$dir/$fileName';
      if (!exists(candidate)) return candidate;
    }
  }

  // `yyyy-MM-dd HH-mm`, local time. Hand-rolled to avoid a date-format dep.
  static String _conflictTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
        ' ${two(t.hour)}-${two(t.minute)}';
  }
}
