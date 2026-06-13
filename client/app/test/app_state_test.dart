/// AppState 逻辑测试:真实 SyncEngine + 临时共享目录 + `file://` bare 远端。
///
/// 注意:所有真实 IO(git 子进程、文件读写、sqlite)必须包在
/// `tester.runAsync` 中执行,否则会卡死在 FakeAsync 区。
library;

import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_engine/sync_engine.dart';

import 'package:shared_sync_app/src/app_state.dart';

import 'test_helpers.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shared_sync_appstate_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// dispose 内部 unawaited 调用引擎 stop():给它一点真实时间释放锁、关闭 db,
  /// 避免 tearDown 删除临时目录时与之竞争。
  Future<void> disposeState(WidgetTester tester, AppState state) async {
    await tester.runAsync(() async {
      state.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
  }

  testWidgets('未配置时各操作返回守卫文案而不是崩溃', (tester) async {
    final state = AppState(prefsPath: p.join(tmp.path, 'app.json'));
    await tester.runAsync(state.load);

    expect(state.initialized, isTrue);
    expect(state.isConfigured, isFalse);
    expect(state.config, isNull);
    expect(state.startupError, isNull);
    expect(state.phase, SyncPhase.idle);
    expect(state.isSyncing, isFalse);

    expect(await state.syncNow(), '尚未完成配置');
    expect(await state.setAutoSync(true), '尚未完成配置');
    expect(await state.revealInFileManager('a.txt'), '尚未完成配置');
    expect(await state.recentConflicts(), isEmpty);
    expect(await state.tailLogs(10), isEmpty);

    state.dispose();
  });

  testWidgets('界面风格:默认跟随系统,设置后持久化,新实例 load 恢复', (tester) async {
    final prefsPath = p.join(tmp.path, 'app.json');
    final state = AppState(prefsPath: prefsPath);
    await tester.runAsync(state.load);
    expect(state.themeMode, ThemeMode.system); // 缺省

    await tester.runAsync(() => state.setThemeMode(ThemeMode.dark));
    expect(state.themeMode, ThemeMode.dark);
    // 未配置(无 sharedDir)也能写入偏好文件。
    expect(File(prefsPath).readAsStringSync(), contains('dark'));
    state.dispose();

    final state2 = AppState(prefsPath: prefsPath);
    await tester.runAsync(state2.load);
    expect(state2.themeMode, ThemeMode.dark); // 恢复
    state2.dispose();
  });

  testWidgets('applyConfig 持久化配置并初始化引擎;新实例 load 可恢复', (tester) async {
    final prefsPath = p.join(tmp.path, 'app.json');
    final sharedDir = p.join(tmp.path, 'shared');
    final serverDir = p.join(tmp.path, 'server.git');

    final state = AppState(prefsPath: prefsPath);
    await tester.runAsync(() async {
      await Directory(sharedDir).create();
      await createBareRemote(serverDir);
      await state.load();
      expect(await state.applyConfig(makeConfig(sharedDir, serverDir)), isNull);
    });

    expect(state.isConfigured, isTrue);
    expect(state.startupError, isNull);
    expect(state.config?.sharedDir, sharedDir);
    // 配置本体落在 <sharedDir>/.sync/config.json(引擎契约),
    // 偏好文件只记上次使用的共享目录。
    expect(
        File(p.join(sharedDir, '.sync', 'config.json')).existsSync(), isTrue);
    expect(File(prefsPath).readAsStringSync(), contains(sharedDir));
    await disposeState(tester, state);

    // 全新 AppState 仅凭偏好文件即可恢复完整配置并重建引擎。
    final state2 = AppState(prefsPath: prefsPath);
    await tester.runAsync(state2.load);
    expect(state2.initialized, isTrue);
    expect(state2.isConfigured, isTrue);
    expect(state2.startupError, isNull);
    expect(state2.config?.serverUrl, 'file://$serverDir');
    expect(state2.config?.clientId, 'TEST-PC');
    await disposeState(tester, state2);
  });

  testWidgets('syncNow 推送本地文件:phase 流转、报告与事件列表', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final serverDir = p.join(tmp.path, 'server.git');
    final state = AppState(prefsPath: p.join(tmp.path, 'app.json'));

    // 通过 notifyListeners 抓取 phase 流转(引擎在每个阶段都会发事件)。
    final phases = <SyncPhase>[];
    state.addListener(() => phases.add(state.phase));

    await tester.runAsync(() async {
      await Directory(sharedDir).create();
      await createBareRemote(serverDir);
      expect(await state.applyConfig(makeConfig(sharedDir, serverDir)), isNull);
      await File(p.join(sharedDir, 'hello.txt'))
          .writeAsString('hi\n', flush: true);

      final future = state.syncNow();
      // _busy 在首个 await 之前同步置位,UI 按钮立刻禁用。
      expect(state.isSyncing, isTrue);
      expect(await future, isNull);
    });

    expect(state.isSyncing, isFalse);
    expect(state.phase, SyncPhase.idle);
    expect(
        phases,
        containsAll([
          SyncPhase.fetching,
          SyncPhase.scanning,
          SyncPhase.planning,
          SyncPhase.pushing,
        ]));

    final report = state.lastReport;
    expect(report, isNotNull);
    expect(report!.error, isNull);
    expect(report.uploaded, 1);
    expect(report.pushedCommit, isNotNull);
    expect(report.conflicts, isEmpty);
    expect(state.lastSyncAt, isNotNull);

    // 事件列表:非空、新事件在前、包含推送成功事件。
    expect(state.events, isNotEmpty);
    for (var i = 0; i + 1 < state.events.length; i++) {
      expect(state.events[i].time.isBefore(state.events[i + 1].time), isFalse,
          reason: '事件列表必须新事件在前');
    }
    expect(state.events.map((e) => e.message),
        anyElement(startsWith('push result: ok')));

    // 无变化的第二轮:报告为 noop,不报错。
    await tester.runAsync(() async {
      expect(await state.syncNow(), isNull);
    });
    expect(state.lastReport!.isNoop, isTrue);
    expect(state.phase, SyncPhase.idle);

    await disposeState(tester, state);
  });

  testWidgets('远端不可达时 syncNow 返回错误文案并进入 error phase', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    // 故意不创建该路径:fetch 必须失败(且不能被误判为空远端)。
    final missingRemote = p.join(tmp.path, 'missing.git');
    final state = AppState(prefsPath: p.join(tmp.path, 'app.json'));

    String? syncError;
    await tester.runAsync(() async {
      await Directory(sharedDir).create();
      // initialize 只建本地 bare 仓库、不联远端,applyConfig 应当成功。
      expect(
          await state.applyConfig(makeConfig(sharedDir, missingRemote)), isNull);
      syncError = await state.syncNow();
    });

    expect(syncError, isNotNull);
    expect(syncError, startsWith('同步失败:'));
    expect(state.isSyncing, isFalse);
    expect(state.phase, SyncPhase.error);
    expect(state.lastReport?.hasError, isTrue);

    await disposeState(tester, state);
  });
}
