/// Daily-file logger for the sync engine. See DESIGN.md §4.3.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Severity of a log line, ordered from least to most severe.
enum LogLevel { debug, info, warn, error }

/// Appends log lines to `<logsDir>/sync-YYYYMMDD.log` (one file per local
/// day) and optionally mirrors them to stdout.
///
/// Writes are synchronous (`RandomAccessFile.writeStringSync`) so a line is
/// fully on disk before [log] returns — [tail] can simply read the file back.
/// Logging failures are swallowed: the logger must never break a sync cycle.
class SyncLogger {
  /// Creates a logger writing into [logsDir] (created lazily on first write).
  SyncLogger(this._logsDir, {this.minLevel = LogLevel.info, this.alsoConsole = true});

  final String _logsDir;

  /// Lines below this level are dropped.
  final LogLevel minLevel;

  /// Mirror every line to stdout as well.
  final bool alsoConsole;

  RandomAccessFile? _file;
  String? _openDay;
  bool _closed = false;

  /// Writes one entry; [error] / [st] are appended to the message when given.
  void log(LogLevel level, String message, [Object? error, StackTrace? st]) {
    if (level.index < minLevel.index) return;
    final now = DateTime.now();
    final buf = StringBuffer()
      ..write(_timestamp(now))
      ..write(' [')
      ..write(level.name.toUpperCase())
      ..write('] ')
      ..write(message);
    if (error != null) {
      buf
        ..write(': ')
        ..write(error);
    }
    if (st != null) {
      buf
        ..writeln()
        ..write(st);
    }
    final line = buf.toString();
    if (alsoConsole) stdout.writeln(line);
    if (_closed) return;
    try {
      _fileFor(now).writeStringSync('$line\n');
    } on FileSystemException {
      // Never let logging break a sync cycle.
    }
  }

  void debug(String m) => log(LogLevel.debug, m);

  void info(String m) => log(LogLevel.info, m);

  void warn(String m) => log(LogLevel.warn, m);

  void error(String m, [Object? e, StackTrace? st]) => log(LogLevel.error, m, e, st);

  /// Returns the last [lines] lines of today's log file (empty list when the
  /// file does not exist yet). Intended for the UI log view.
  ///
  /// Reads only the file tail rather than the whole day's log: a
  /// [RandomAccessFile] is walked backwards from EOF in [_tailChunk]-byte
  /// chunks until at least [lines] newlines (or the file head) are seen, so a
  /// multi-megabyte daily file never lands in memory just to refresh the UI.
  Future<List<String>> tail(int lines) async {
    if (lines <= 0) return const [];
    final file = File(_pathForDay(DateTime.now()));
    if (!await file.exists()) return const [];

    final raf = await file.open();
    try {
      var pos = await raf.length();
      if (pos == 0) return const [];
      // Bytes accumulated from the tail, prepended chunk by chunk so the final
      // buffer is in forward order.
      final chunks = <List<int>>[];
      var newlines = 0;
      var reachedHead = false;

      while (pos > 0) {
        final size = pos < _tailChunk ? pos : _tailChunk;
        pos -= size;
        await raf.setPosition(pos);
        final chunk = await raf.read(size);
        chunks.insert(0, chunk);
        for (final b in chunk) {
          if (b == 0x0a) newlines++; // '\n'
        }
        if (pos == 0) reachedHead = true;
        // One newline per N lines is the separator count; an extra newline is
        // the trailing one when the file ends with '\n'. Read one more than
        // needed so the first (possibly partial) line can be dropped safely.
        if (newlines > lines) break;
      }

      final bytes = chunks.length == 1
          ? chunks.first
          : <int>[for (final c in chunks) ...c];
      // Decode the tail as a whole. allowMalformed guards the chunk boundary:
      // when we stopped before the file head the buffer may start mid-line
      // (and possibly mid-multibyte-character); that first segment is dropped
      // below, so any replacement chars it contains are discarded anyway.
      var text = utf8.decode(bytes, allowMalformed: true);
      // Drop a single trailing newline so a file ending in '\n' yields no empty
      // final element.
      if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
      final all = text.split('\n');
      // If we stopped before the head, the first element is a line fragment;
      // drop it (we deliberately read one extra newline to afford this).
      final usable = reachedHead ? all : all.sublist(1);
      return usable.length <= lines
          ? usable
          : usable.sublist(usable.length - lines);
    } finally {
      await raf.close();
    }
  }

  // Tail read block size (64 KiB): a handful of these covers the last N lines
  // of any realistic log without reading the whole file.
  static const int _tailChunk = 64 * 1024;

  /// Deletes `<logsDir>/sync-YYYYMMDD.log` files whose embedded date is older
  /// than [retentionDays] days before today (local time). Files that are not
  /// `sync-*.log` or whose date cannot be parsed are left untouched, so a
  /// stray file is never deleted by mistake.
  ///
  /// Returns the number of files removed. Exposed as a plain method (no engine
  /// state) so it is independently unit-testable.
  Future<int> cleanupOldLogs(int retentionDays) async {
    final dir = Directory(_logsDir);
    if (!await dir.exists()) return 0;
    final today = DateTime.now();
    final cutoff = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: retentionDays));
    var removed = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final day = _dayOfLogFile(p.basename(entity.path));
      if (day == null) continue; // not sync-YYYYMMDD.log / unparseable date
      if (day.isBefore(cutoff)) {
        try {
          await entity.delete();
          removed++;
          log(LogLevel.info,
              'log retention: removed old ${p.basename(entity.path)}');
        } on FileSystemException {
          // Best effort: a file we cannot delete is not worth failing the cycle.
        }
      }
    }
    return removed;
  }

  // Parses the date out of `sync-YYYYMMDD.log`; null for any other name or an
  // out-of-range date.
  static DateTime? _dayOfLogFile(String name) {
    const prefix = 'sync-';
    const suffix = '.log';
    if (!name.startsWith(prefix) || !name.endsWith(suffix)) return null;
    final digits = name.substring(prefix.length, name.length - suffix.length);
    if (digits.length != 8) return null;
    final year = int.tryParse(digits.substring(0, 4));
    final month = int.tryParse(digits.substring(4, 6));
    final day = int.tryParse(digits.substring(6, 8));
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final dt = DateTime(year, month, day);
    // Reject normalized overflow (e.g. 20260231 -> March 3) so a bogus name is
    // never treated as a valid older date.
    if (dt.year != year || dt.month != month || dt.day != day) return null;
    return dt;
  }

  /// Closes the underlying file. Safe to call multiple times; further [log]
  /// calls only go to the console (when [alsoConsole] is set).
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _file?.closeSync();
    } on FileSystemException {
      // Ignore: nothing useful to do at shutdown.
    }
    _file = null;
    _openDay = null;
  }

  // Reopens the sink when the local day rolls over.
  RandomAccessFile _fileFor(DateTime now) {
    final day = _dayKey(now);
    if (_file == null || day != _openDay) {
      try {
        _file?.closeSync();
      } on FileSystemException {
        // Old handle is unusable anyway.
      }
      Directory(_logsDir).createSync(recursive: true);
      _file = File(_pathForDay(now)).openSync(mode: FileMode.append);
      _openDay = day;
    }
    return _file!;
  }

  String _pathForDay(DateTime t) => p.join(_logsDir, 'sync-${_dayKey(t)}.log');

  String _dayKey(DateTime t) =>
      '${_pad(t.year, 4)}${_pad(t.month, 2)}${_pad(t.day, 2)}';

  // `2026-06-13T10:00:00.000` — local time, millisecond precision.
  String _timestamp(DateTime t) => '${_pad(t.year, 4)}-${_pad(t.month, 2)}-${_pad(t.day, 2)}'
      'T${_pad(t.hour, 2)}:${_pad(t.minute, 2)}:${_pad(t.second, 2)}'
      '.${_pad(t.millisecond, 3)}';

  static String _pad(int v, int width) => v.toString().padLeft(width, '0');
}
