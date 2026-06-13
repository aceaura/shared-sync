import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sync_engine/src/config.dart';
import 'package:test/test.dart';

SyncConfig _minimal({String clientId = 'PC-A'}) => SyncConfig(
      sharedDir: '/tmp/shared',
      serverUrl: 'http://localhost:8418/shared.git',
      clientId: clientId,
    );

void main() {
  group('defaults', () {
    test('constructor applies documented defaults', () {
      final c = _minimal();
      expect(c.syncIntervalSeconds, 30);
      expect(c.fileStableDelaySeconds, 2);
      expect(c.maxPushRetries, 3);
      expect(c.conflictNameTemplate,
          '{name} (conflict from {client} {time}){ext}');
      expect(c.ignoreFileName, '.syncignore');
    });

    test('path getters derive from sharedDir', () {
      final c = _minimal();
      expect(c.syncDir, p.join('/tmp/shared', '.sync'));
      expect(c.repoDir, p.join(c.syncDir, 'repo'));
      expect(c.dbPath, p.join(c.syncDir, 'index.db'));
      expect(c.stagingDir, p.join(c.syncDir, 'staging'));
      expect(c.logsDir, p.join(c.syncDir, 'logs'));
      expect(c.conflictsPath, p.join(c.syncDir, 'conflicts.jsonl'));
    });

    test('fromJson fills defaults for missing optional fields', () {
      final c = SyncConfig.fromJson({
        'sharedDir': '/x',
        'serverUrl': 'file:///srv/git/shared.git',
        'clientId': 'PC-B',
      });
      expect(c.syncIntervalSeconds, 30);
      expect(c.fileStableDelaySeconds, 2);
      expect(c.maxPushRetries, 3);
      expect(c.conflictNameTemplate,
          '{name} (conflict from {client} {time}){ext}');
      expect(c.ignoreFileName, '.syncignore');
    });
  });

  group('json round-trip', () {
    test('all fields survive toJson/fromJson', () {
      const original = SyncConfig(
        sharedDir: '/Users/me/Shared',
        serverUrl: 'https://host/shared.git',
        clientId: 'laptop-1',
        syncIntervalSeconds: 7,
        fileStableDelaySeconds: 9,
        maxPushRetries: 5,
        conflictNameTemplate: '{name}~{client}~{time}{ext}',
        ignoreFileName: '.myignore',
      );
      final restored = SyncConfig.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.sharedDir, original.sharedDir);
      expect(restored.serverUrl, original.serverUrl);
      expect(restored.clientId, original.clientId);
      expect(restored.syncIntervalSeconds, original.syncIntervalSeconds);
      expect(restored.fileStableDelaySeconds, original.fileStableDelaySeconds);
      expect(restored.maxPushRetries, original.maxPushRetries);
      expect(restored.conflictNameTemplate, original.conflictNameTemplate);
      expect(restored.ignoreFileName, original.ignoreFileName);
    });

    test('toJson contains exactly the nine contract fields', () {
      final json = _minimal().toJson();
      expect(
          json.keys.toSet(),
          {
            'sharedDir',
            'serverUrl',
            'clientId',
            'syncIntervalSeconds',
            'fileStableDelaySeconds',
            'maxPushRetries',
            'conflictNameTemplate',
            'ignoreFileName',
            'logRetentionDays',
          });
    });

    test('logRetentionDays survives round-trip and defaults when absent', () {
      const original = SyncConfig(
        sharedDir: '/x',
        serverUrl: 'file:///srv/git/shared.git',
        clientId: 'PC-C',
        logRetentionDays: 30,
      );
      final restored = SyncConfig.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(restored.logRetentionDays, 30);

      // Backward compatibility: an old config.json without the field loads
      // with the default and does not throw.
      final legacy = SyncConfig.fromJson({
        'sharedDir': '/x',
        'serverUrl': 'file:///srv/git/shared.git',
        'clientId': 'PC-D',
      });
      expect(legacy.logRetentionDays, SyncConfig.defaultLogRetentionDays);
    });
  });

  group('load/save', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sync_config_test_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('load returns null when config.json does not exist', () async {
      expect(await SyncConfig.load(tmp.path), isNull);
    });

    test('save creates .sync dir, writes atomically, load round-trips',
        () async {
      final c = SyncConfig(
        sharedDir: tmp.path,
        serverUrl: 'http://h/shared.git',
        clientId: 'PC-A',
        syncIntervalSeconds: 11,
      );
      await c.save();

      final configFile = File(p.join(tmp.path, '.sync', 'config.json'));
      expect(await configFile.exists(), isTrue);
      // No temp file left behind by the atomic write.
      expect(await File('${configFile.path}.tmp').exists(), isFalse);

      final loaded = await SyncConfig.load(tmp.path);
      expect(loaded, isNotNull);
      expect(loaded!.sharedDir, c.sharedDir);
      expect(loaded.serverUrl, c.serverUrl);
      expect(loaded.clientId, c.clientId);
      expect(loaded.syncIntervalSeconds, 11);
    });

    test('save overwrites an existing config', () async {
      final c1 = SyncConfig(
          sharedDir: tmp.path, serverUrl: 'http://h/a.git', clientId: 'A');
      await c1.save();
      final c2 = SyncConfig(
          sharedDir: tmp.path, serverUrl: 'http://h/b.git', clientId: 'B');
      await c2.save();
      final loaded = await SyncConfig.load(tmp.path);
      expect(loaded!.serverUrl, 'http://h/b.git');
      expect(loaded.clientId, 'B');
    });
  });

  group('conflictCopyPath', () {
    final when = DateTime(2026, 6, 12, 15, 30);
    bool never(String _) => false;

    test('matches the DESIGN.md example', () {
      final c = _minimal();
      expect(
        c.conflictCopyPath('report.docx', when, never),
        'report (conflict from PC-A 2026-06-12 15-30).docx',
      );
    });

    test('keeps the original directory', () {
      final c = _minimal();
      expect(
        c.conflictCopyPath('docs/deep/report.docx', when, never),
        'docs/deep/report (conflict from PC-A 2026-06-12 15-30).docx',
      );
    });

    test('file without extension gets empty {ext}', () {
      final c = _minimal();
      expect(
        c.conflictCopyPath('Makefile', when, never),
        'Makefile (conflict from PC-A 2026-06-12 15-30)',
      );
    });

    test('dotfile is treated as extensionless', () {
      final c = _minimal();
      expect(
        c.conflictCopyPath('.gitattributes', when, never),
        '.gitattributes (conflict from PC-A 2026-06-12 15-30)',
      );
    });

    test('only the last extension is split off', () {
      final c = _minimal();
      expect(
        c.conflictCopyPath('archive.tar.gz', when, never),
        'archive.tar (conflict from PC-A 2026-06-12 15-30).gz',
      );
    });

    test('time components are zero-padded', () {
      final c = _minimal();
      expect(
        c.conflictCopyPath('a.txt', DateTime(2026, 1, 2, 3, 4), never),
        'a (conflict from PC-A 2026-01-02 03-04).txt',
      );
    });

    test('collision appends " -2" after time, before ext', () {
      final c = _minimal();
      final taken = {'report (conflict from PC-A 2026-06-12 15-30).docx'};
      expect(
        c.conflictCopyPath('report.docx', when, taken.contains),
        'report (conflict from PC-A 2026-06-12 15-30 -2).docx',
      );
    });

    test('consecutive collisions advance to " -3"', () {
      final c = _minimal();
      final taken = {
        'report (conflict from PC-A 2026-06-12 15-30).docx',
        'report (conflict from PC-A 2026-06-12 15-30 -2).docx',
      };
      expect(
        c.conflictCopyPath('report.docx', when, taken.contains),
        'report (conflict from PC-A 2026-06-12 15-30 -3).docx',
      );
    });

    test('collision check also applies inside subdirectories', () {
      final c = _minimal();
      final taken = {'docs/report (conflict from PC-A 2026-06-12 15-30).docx'};
      expect(
        c.conflictCopyPath('docs/report.docx', when, taken.contains),
        'docs/report (conflict from PC-A 2026-06-12 15-30 -2).docx',
      );
    });

    test('custom template substitutes all variables', () {
      final c = SyncConfig(
        sharedDir: '/s',
        serverUrl: 'u',
        clientId: 'PC-B',
        conflictNameTemplate: '{name}.{client}.{time}{ext}',
      );
      expect(
        c.conflictCopyPath('notes.md', when, never),
        'notes.PC-B.2026-06-12 15-30.md',
      );
    });

    test('custom template collisions still suffix after time', () {
      final c = SyncConfig(
        sharedDir: '/s',
        serverUrl: 'u',
        clientId: 'PC-B',
        conflictNameTemplate: '{name}.{client}.{time}{ext}',
      );
      final taken = {'notes.PC-B.2026-06-12 15-30.md'};
      expect(
        c.conflictCopyPath('notes.md', when, taken.contains),
        'notes.PC-B.2026-06-12 15-30 -2.md',
      );
    });
  });
}
