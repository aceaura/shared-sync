/// 冲突页渲染测试:空态文案;有数据时的列表/角标/副本行/排序。
///
/// 有数据用例使用真实引擎读取 `.sync/conflicts.jsonl`(真实 IO 包在
/// tester.runAsync 中,FutureBuilder 的完成靠 runAsync 里的真实延时驱动)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_engine/sync_engine.dart';

import 'package:shared_sync_app/src/app_state.dart';
import 'package:shared_sync_app/src/conflicts_page.dart';

import 'test_helpers.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shared_sync_conflicts_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpPage(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ConflictsPage(state: state)),
    ));
  }

  testWidgets('未配置 / 无冲突时显示空态', (tester) async {
    final state = AppState(prefsPath: p.join(tmp.path, 'app.json'));
    await tester.runAsync(state.load);

    await pumpPage(tester, state);
    await tester.pump();
    await tester.pump();

    expect(find.text('冲突记录'), findsOneWidget);
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(find.text('暂无冲突记录'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.textContaining('读取冲突记录失败'), findsNothing);

    state.dispose();
  });

  testWidgets('有冲突记录时渲染列表:角标、副本行、新记录在前', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final serverDir = p.join(tmp.path, 'server.git');
    final state = AppState(prefsPath: p.join(tmp.path, 'app.json'));

    const copyPath = 'docs/a (conflict from PC-B 2026-06-13 10-00).txt';
    await tester.runAsync(() async {
      await Directory(sharedDir).create();
      await createBareRemote(serverDir);
      expect(await state.applyConfig(makeConfig(sharedDir, serverDir)), isNull);

      // 按引擎契约直接写 conflicts.jsonl:文件内时间正序(旧在前)。
      final older = ConflictRecord(
        time: DateTime(2026, 6, 13, 10, 0, 0),
        kind: 'modify',
        path: 'docs/a.txt',
        copyPath: copyPath,
        clientId: 'PC-B',
      );
      final newer = ConflictRecord(
        time: DateTime(2026, 6, 13, 11, 30, 0),
        kind: 'delete',
        path: 'docs/b.txt',
        copyPath: null,
        clientId: 'PC-B',
      );
      await File(p.join(sharedDir, '.sync', 'conflicts.jsonl')).writeAsString(
        '${jsonEncode(older.toJson())}\n${jsonEncode(newer.toJson())}\n',
        flush: true,
      );
      // 引擎确实能读回这两条(页面数据源)。
      expect((await state.recentConflicts()).length, 2);
    });

    await pumpPage(tester, state);
    // FutureBuilder 里是真实文件 IO 的多段 await 链:每段都要先给真实事件循环
    // 时间(runAsync),再回到 fake 区 pump 冲掉微任务,循环直到列表出现。
    for (var i = 0; i < 40 && find.byType(ListTile).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(find.text('暂无冲突记录'), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(2));

    // 两条记录的路径与角标文案。
    expect(find.text('docs/a.txt'), findsOneWidget);
    expect(find.text('docs/b.txt'), findsOneWidget);
    expect(find.text('修改'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    // modify 记录带副本行,delete 记录没有。
    expect(find.textContaining('副本:$copyPath'), findsOneWidget);

    // 展示顺序新记录在前:delete(11:30)应排在 modify(10:00)上方。
    final dyNewer = tester.getTopLeft(find.text('docs/b.txt')).dy;
    final dyOlder = tester.getTopLeft(find.text('docs/a.txt')).dy;
    expect(dyNewer, lessThan(dyOlder));

    await tester.runAsync(() async {
      state.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
  });
}
