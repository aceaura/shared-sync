/// Command-line entry point for the sync engine (DESIGN.md §4.10).
///
/// Usage:
///   sync_cli init   --dir <sharedDir> --server <url> --client-id <id> [--interval N]
///   sync_cli sync   --dir <sharedDir>
///   sync_cli watch  --dir <sharedDir>
///   sync_cli status --dir <sharedDir>
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:sync_engine/sync_engine.dart';

ArgParser _buildParser() {
  ArgParser dirOnly() => ArgParser()
    ..addOption('dir', help: 'Shared directory path', mandatory: true);
  return ArgParser()
    ..addCommand(
        'init',
        ArgParser()
          ..addOption('dir', help: 'Shared directory path', mandatory: true)
          ..addOption('server', help: 'Git server URL', mandatory: true)
          ..addOption('client-id', help: 'Stable client id', mandatory: true)
          ..addOption('interval',
              help: 'Auto sync interval in seconds (default 30)'))
    ..addCommand('sync', dirOnly())
    ..addCommand('watch', dirOnly())
    ..addCommand('status', dirOnly());
}

void _printUsage(ArgParser parser) {
  stderr.writeln('usage:');
  stderr.writeln('  sync_cli init   --dir <sharedDir> --server <url> '
      '--client-id <id> [--interval N]');
  stderr.writeln('  sync_cli sync   --dir <sharedDir>');
  stderr.writeln('  sync_cli watch  --dir <sharedDir>');
  stderr.writeln('  sync_cli status --dir <sharedDir>');
}

Future<void> main(List<String> argv) async {
  final parser = _buildParser();
  ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _printUsage(parser);
    exit(2);
  }
  final command = args.command;
  if (command == null) {
    _printUsage(parser);
    exit(2);
  }
  int code;
  try {
    switch (command.name) {
      case 'init':
        code = await _cmdInit(command);
      case 'sync':
        code = await _cmdSync(command);
      case 'watch':
        code = await _cmdWatch(command);
      case 'status':
        code = await _cmdStatus(command);
      default:
        _printUsage(parser);
        code = 2;
    }
  } catch (e) {
    stderr.writeln('error: $e');
    code = 1;
  }
  // Hard exit: no leftover timers/isolates (sqlite, watcher) may keep the
  // process alive after the command is done.
  exit(code);
}

String _absDir(ArgResults args) => p.canonicalize(args['dir'] as String);

Future<int> _cmdInit(ArgResults args) async {
  final dir = _absDir(args);
  if (!Directory(dir).existsSync()) {
    stderr.writeln('directory does not exist: $dir');
    return 1;
  }
  final intervalRaw = args['interval'] as String?;
  final interval = intervalRaw == null ? null : int.tryParse(intervalRaw);
  if (intervalRaw != null && (interval == null || interval <= 0)) {
    stderr.writeln('--interval must be a positive integer');
    return 2;
  }
  final config = SyncConfig(
    sharedDir: dir,
    serverUrl: args['server'] as String,
    clientId: args['client-id'] as String,
    syncIntervalSeconds: interval ?? SyncConfig.defaultSyncIntervalSeconds,
  );
  await config.save();
  // Bring up the engine once so .sync/{repo,staging,logs} and index.db exist
  // and the server URL is validated early at the git level.
  final engine = SyncEngine(config);
  try {
    await engine.initialize();
  } finally {
    await engine.stop();
  }
  stdout.writeln('initialized $dir (server: ${config.serverUrl}, '
      'client: ${config.clientId})');
  return 0;
}

Future<SyncConfig?> _loadConfig(String dir) async {
  final config = await SyncConfig.load(dir);
  if (config == null) {
    stderr.writeln('no .sync/config.json in $dir — run "sync_cli init" first');
  }
  return config;
}

Future<int> _cmdSync(ArgResults args) async {
  final config = await _loadConfig(_absDir(args));
  if (config == null) return 2;
  final engine = SyncEngine(config);
  try {
    await engine.initialize();
    final report = await engine.syncOnce();
    stdout.writeln(report.summary());
    return report.hasError ? 1 : 0;
  } finally {
    await engine.stop();
  }
}

Future<int> _cmdWatch(ArgResults args) async {
  final config = await _loadConfig(_absDir(args));
  if (config == null) return 2;
  final engine = SyncEngine(config);
  await engine.initialize();

  final reportSub = engine.reports.listen(
      (report) => stdout.writeln('[sync] ${report.summary()}'));

  final done = Completer<int>();
  final signalSubs = <StreamSubscription<ProcessSignal>>[];
  void onSignal(ProcessSignal signal) {
    stdout.writeln('received $signal, shutting down...');
    if (!done.isCompleted) done.complete(0);
  }

  signalSubs.add(ProcessSignal.sigint.watch().listen(onSignal));
  if (!Platform.isWindows) {
    signalSubs.add(ProcessSignal.sigterm.watch().listen(onSignal));
  }

  await engine.startAuto();
  unawaited(engine.syncOnce()); // initial cycle right away

  final code = await done.future;
  for (final sub in signalSubs) {
    await sub.cancel();
  }
  await engine.stop();
  await reportSub.cancel();
  return code;
}

Future<int> _cmdStatus(ArgResults args) async {
  final dir = _absDir(args);
  final config = await _loadConfig(dir);
  if (config == null) return 2;

  stdout.writeln('config:');
  const encoder = JsonEncoder.withIndent('  ');
  stdout.writeln(encoder.convert(config.toJson()));

  // Read the DB directly (no engine, no lock) so status works while a
  // watch process is running.
  String? lastCommit;
  if (File(config.dbPath).existsSync()) {
    final db = await IndexDb.open(config.dbPath);
    lastCommit = db.lastSyncedCommit;
    db.close();
  }
  stdout.writeln('lastSyncedCommit: ${lastCommit ?? '(none)'}');

  stdout.writeln('recent conflicts (last 10):');
  final records = _readConflicts(config.conflictsPath, 10);
  if (records.isEmpty) {
    stdout.writeln('  (none)');
  } else {
    for (final r in records) {
      stdout.writeln('  ${r.time.toIso8601String()} [${r.kind}] ${r.path}'
          '${r.copyPath == null ? '' : ' -> ${r.copyPath}'}');
    }
  }
  return 0;
}

List<ConflictRecord> _readConflicts(String path, int limit) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  final records = <ConflictRecord>[];
  for (final line in file.readAsLinesSync().reversed) {
    if (records.length >= limit) break;
    if (line.trim().isEmpty) continue;
    try {
      records
          .add(ConflictRecord.fromJson(jsonDecode(line) as Map<String, dynamic>));
    } catch (_) {
      // Skip malformed lines.
    }
  }
  return records.reversed.toList();
}
