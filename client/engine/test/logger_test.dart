/// Tests for [SyncLogger]: tail-from-EOF reading and daily-log retention.
@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_engine/src/logger.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_logger_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // Today's log path, matching SyncLogger's `sync-YYYYMMDD.log` naming.
  String todayLogPath(String logsDir) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final day = '${now.year.toString().padLeft(4, '0')}'
        '${two(now.month)}${two(now.day)}';
    return p.join(logsDir, 'sync-$day.log');
  }

  // Writes [content] verbatim as today's log file (no trailing newline added).
  Future<void> writeTodayLog(String logsDir, String content) async {
    await Directory(logsDir).create(recursive: true);
    await File(todayLogPath(logsDir)).writeAsString(content);
  }

  group('tail', () {
    test('returns empty list when the file does not exist', () async {
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(10), isEmpty);
      logger.close();
    });

    test('returns all lines when file has fewer lines than requested',
        () async {
      await writeTodayLog(tmp.path, 'a\nb\nc\n');
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(10), ['a', 'b', 'c']);
      logger.close();
    });

    test('returns all lines when file has exactly N lines', () async {
      await writeTodayLog(tmp.path, 'a\nb\nc\n');
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(3), ['a', 'b', 'c']);
      logger.close();
    });

    test('returns only the last N lines when file has more than N', () async {
      await writeTodayLog(tmp.path, 'a\nb\nc\nd\ne\n');
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(2), ['d', 'e']);
      logger.close();
    });

    test('file ending in newline yields no trailing empty line', () async {
      await writeTodayLog(tmp.path, 'x\ny\n');
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(10), ['x', 'y']);
      logger.close();
    });

    test('file with no trailing newline keeps its last line', () async {
      await writeTodayLog(tmp.path, 'x\ny\nz');
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(10), ['x', 'y', 'z']);
      expect(await logger.tail(1), ['z']);
      logger.close();
    });

    test('handles multibyte UTF-8 (Chinese) lines correctly', () async {
      await writeTodayLog(
          tmp.path, '第一行\n第二行包含更多中文字符\n第三行\n');
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(2), ['第二行包含更多中文字符', '第三行']);
      expect(await logger.tail(10), ['第一行', '第二行包含更多中文字符', '第三行']);
      logger.close();
    });

    test('tail(0) returns empty', () async {
      await writeTodayLog(tmp.path, 'a\nb\n');
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(0), isEmpty);
      logger.close();
    });

    test('large file: tail(10) returns the last 10 lines without reading all',
        () async {
      // 5000 lines, each long enough that the last 10 span several 64KiB
      // chunks, exercising the backward chunked read and boundary decode.
      final buf = StringBuffer();
      for (var i = 0; i < 5000; i++) {
        buf.writeln('line-$i padding 中文 ${'.' * 40}');
      }
      await writeTodayLog(tmp.path, buf.toString());

      final logger = SyncLogger(tmp.path, alsoConsole: false);
      final last10 = await logger.tail(10);
      expect(last10, hasLength(10));
      for (var k = 0; k < 10; k++) {
        final idx = 4990 + k;
        expect(last10[k], 'line-$idx padding 中文 ${'.' * 40}');
      }
      logger.close();
    });

    test('tail matches whole-file semantics on a multi-chunk file', () async {
      // Cross-check against the naive "read everything, take the tail" result
      // to prove the optimized reader is equivalent.
      final buf = StringBuffer();
      for (var i = 0; i < 3000; i++) {
        buf.writeln('行 $i — ${'x' * 60}');
      }
      await writeTodayLog(tmp.path, buf.toString());
      final expected = (await File(todayLogPath(tmp.path)).readAsLines());
      final expectedTail = expected.sublist(expected.length - 25);

      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.tail(25), expectedTail);
      logger.close();
    });

    test('round-trips lines written through the logger itself', () async {
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      logger.info('first 消息');
      logger.warn('second');
      logger.error('third');
      final lines = await logger.tail(2);
      expect(lines, hasLength(2));
      expect(lines[0], contains('second'));
      expect(lines[1], contains('third'));
      logger.close();
    });
  });

  group('cleanupOldLogs', () {
    String logName(DateTime d) {
      String two(int v) => v.toString().padLeft(2, '0');
      return 'sync-${d.year.toString().padLeft(4, '0')}'
          '${two(d.month)}${two(d.day)}.log';
    }

    Future<void> touch(String name) async {
      await Directory(tmp.path).create(recursive: true);
      await File(p.join(tmp.path, name)).writeAsString('x\n');
    }

    bool exists(String name) => File(p.join(tmp.path, name)).existsSync();

    test('deletes only files older than the retention window', () async {
      final today = DateTime.now();
      final recent = today.subtract(const Duration(days: 3));
      final boundary = today.subtract(const Duration(days: 14));
      final old = today.subtract(const Duration(days: 30));

      await touch(logName(today));
      await touch(logName(recent));
      await touch(logName(boundary)); // exactly cutoff -> kept (not "before")
      await touch(logName(old));

      final logger = SyncLogger(tmp.path, alsoConsole: false);
      final removed = await logger.cleanupOldLogs(14);
      logger.close();

      expect(removed, 1);
      expect(exists(logName(today)), isTrue);
      expect(exists(logName(recent)), isTrue);
      expect(exists(logName(boundary)), isTrue);
      expect(exists(logName(old)), isFalse);
    });

    test('never deletes non-sync files or unparseable names', () async {
      final old = DateTime.now().subtract(const Duration(days: 60));
      await touch(logName(old)); // genuinely old -> should go
      await touch('notes.txt');
      await touch('sync-latest.log'); // not a date
      await touch('sync-2026131.log'); // 7 digits
      await touch('sync-20260231.log'); // 31 Feb -> invalid date
      await touch('other-20200101.log'); // wrong prefix

      final logger = SyncLogger(tmp.path, alsoConsole: false);
      final removed = await logger.cleanupOldLogs(14);
      logger.close();

      expect(removed, 1);
      expect(exists(logName(old)), isFalse);
      expect(exists('notes.txt'), isTrue);
      expect(exists('sync-latest.log'), isTrue);
      expect(exists('sync-2026131.log'), isTrue);
      expect(exists('sync-20260231.log'), isTrue);
      expect(exists('other-20200101.log'), isTrue);
    });

    test('returns 0 when the logs directory does not exist', () async {
      final logger = SyncLogger(p.join(tmp.path, 'nope'), alsoConsole: false);
      expect(await logger.cleanupOldLogs(14), 0);
      logger.close();
    });

    test('keeps everything when nothing is past the window', () async {
      await touch(logName(DateTime.now()));
      await touch(logName(DateTime.now().subtract(const Duration(days: 5))));
      final logger = SyncLogger(tmp.path, alsoConsole: false);
      expect(await logger.cleanupOldLogs(14), 0);
      logger.close();
    });
  });
}
