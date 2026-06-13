/// 文件页测试:真实临时共享目录 + 真实 [AppState](走 applyConfig 流程)。
///
/// 全部真实文件 IO 都包在 [WidgetTester.runAsync] 中执行;FilesPage 的列目录
/// 是真实 IO 的多段 await 链,刷新后需循环「runAsync 给真实事件循环时间 +
/// pump 冲微任务」直到列表稳定。
///
/// UI 已升级为「访达式」文件管理器(四区:工具栏 / 侧栏树 / 主区双视图 / 状态栏)。
/// 默认是「图标网格视图」;详情列表视图带可排序列头。涉及竖直顺序断言的用例切到
/// 详情视图以获得稳定的逐行布局;进入文件夹改为「双击」。
///
/// **纯逻辑测试 moveEntry / importPaths 保持不动。**
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:shared_sync_app/src/app_state.dart';
import 'package:shared_sync_app/src/files_page.dart';

import 'test_helpers.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shared_sync_files_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 建临时共享目录 + bare 远端,跑 applyConfig,返回已配置的 AppState。
  Future<AppState> configuredState(WidgetTester tester, String sharedDir) async {
    final serverDir = p.join(tmp.path, 'server.git');
    final state = AppState(prefsPath: p.join(tmp.path, 'app.json'));
    await tester.runAsync(() async {
      await Directory(sharedDir).create(recursive: true);
      await createBareRemote(serverDir);
      expect(await state.applyConfig(makeConfig(sharedDir, serverDir)), isNull);
    });
    return state;
  }

  Future<void> pumpPage(WidgetTester tester, AppState state) async {
    // 大一点的窗口,确保工具栏(后退/前进/视图切换/搜索/新建/刷新)+ 侧栏 + 主区
    // 都能在一行内布局,避免 RenderFlex 溢出。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FilesPage(state: state)),
    ));
  }

  /// 反复推进直到 [done] 为真或超时(用于等待真实 IO 链完成)。
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 40 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
  }

  Future<void> disposeState(WidgetTester tester, AppState state) async {
    await tester.runAsync(() async {
      state.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
  }

  /// 切到「详情列表视图」(竖直逐行布局,便于顺序断言)。
  Future<void> switchToList(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.view_list));
    await tester.pumpAndSettle();
  }

  /// 切到「图标网格视图」。
  Future<void> switchToGrid(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.pumpAndSettle();
  }

  testWidgets('列出文件夹与文件:文件夹在前,.sync 目录被隐藏(详情视图)',
      (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(() async {
      // .sync 已由 applyConfig 创建;再放一个用户文件夹与一个文件。
      await Directory(p.join(sharedDir, 'docs')).create();
      await File(p.join(sharedDir, 'readme.txt')).writeAsString('hello');
    });

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('docs').evaluate().isNotEmpty);
    await switchToList(tester);

    expect(find.text('docs'), findsOneWidget);
    expect(find.text('readme.txt'), findsOneWidget);
    // .sync 被隐藏(主区与侧栏树都不出现)。
    expect(find.text('.sync'), findsNothing);

    // 文件夹排在文件上方(详情视图逐行竖直)。
    final dyDir = tester.getTopLeft(find.text('docs')).dy;
    final dyFile = tester.getTopLeft(find.text('readme.txt')).dy;
    expect(dyDir, lessThan(dyFile));

    await disposeState(tester, state);
  });

  testWidgets('双击进入子文件夹:面包屑更新并列出子项', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(() async {
      await Directory(p.join(sharedDir, 'docs')).create();
      await File(p.join(sharedDir, 'docs', 'inner.md')).writeAsString('x');
    });

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('docs').evaluate().isNotEmpty);

    // 双击文件夹进入(主区只有一处 docs 文本;侧栏节点单独存在,用 .first 取主区项)。
    await tester.tap(find.text('docs').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('docs').first);
    await settleUntil(tester, () => find.text('inner.md').evaluate().isNotEmpty);

    // 面包屑里出现根「共享目录」,子项可见。
    expect(find.text('共享目录'), findsWidgets);
    expect(find.text('inner.md'), findsOneWidget);

    // 点面包屑根回到根目录:等刷新真正完成(子项消失且根目录的 docs 重新出现)。
    await tester.tap(find.text('共享目录').first);
    await settleUntil(
        tester,
        () =>
            find.text('inner.md').evaluate().isEmpty &&
            find.text('docs').evaluate().isNotEmpty);
    expect(find.text('docs'), findsWidgets);
    expect(find.text('inner.md'), findsNothing);

    await disposeState(tester, state);
  });

  testWidgets('后退/前进:进入后退回上级,再前进回子目录', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(() async {
      await Directory(p.join(sharedDir, 'docs')).create();
      await File(p.join(sharedDir, 'docs', 'inner.md')).writeAsString('x');
    });

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('docs').evaluate().isNotEmpty);

    // 双击进入 docs。
    await tester.tap(find.text('docs').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('docs').first);
    await settleUntil(tester, () => find.text('inner.md').evaluate().isNotEmpty);

    // 后退回根:inner.md 消失,docs 重新出现。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await settleUntil(
        tester,
        () =>
            find.text('inner.md').evaluate().isEmpty &&
            find.text('docs').evaluate().isNotEmpty);
    expect(find.text('inner.md'), findsNothing);

    // 前进回 docs:inner.md 再次出现。
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await settleUntil(tester, () => find.text('inner.md').evaluate().isNotEmpty);
    expect(find.text('inner.md'), findsOneWidget);

    await disposeState(tester, state);
  });

  testWidgets('新建文件夹:输入名称→确定后磁盘创建并出现在列表', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('此文件夹为空').evaluate().isNotEmpty);

    // 工具栏「新建文件夹」现为 IconButton,用 tooltip 定位。
    await tester.tap(find.byTooltip('新建文件夹'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'newdir');
    await tester.tap(find.text('创建'));

    await settleUntil(tester, () => find.text('newdir').evaluate().isNotEmpty);

    // 列表里出现,且磁盘上真的有这个目录。
    expect(find.text('newdir'), findsWidgets);
    expect(Directory(p.join(sharedDir, 'newdir')).existsSync(), isTrue);

    await disposeState(tester, state);
  });

  testWidgets('删除:右键菜单确认后文件真的从磁盘消失', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    final target = File(p.join(sharedDir, 'gone.txt'));
    await tester.runAsync(() => target.writeAsString('bye'));

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('gone.txt').evaluate().isNotEmpty);

    // 右键该项弹出菜单 → 删除。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('gone.txt')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    // 确认对话框,点删除。
    expect(find.text('确认删除'), findsOneWidget);
    expect(find.textContaining('gone.txt'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));

    await settleUntil(tester, () => find.text('gone.txt').evaluate().isEmpty);

    expect(find.text('gone.txt'), findsNothing);
    expect(target.existsSync(), isFalse);

    await disposeState(tester, state);
  });

  testWidgets('右键条目:弹出与三点菜单相同的操作(重命名/删除/在访达中显示)',
      (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(
        () => File(p.join(sharedDir, 'a.txt')).writeAsString('x'));

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('a.txt').evaluate().isNotEmpty);

    // 对该项触发右键(secondary tap)。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('a.txt')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('在访达中显示'), findsOneWidget);

    await disposeState(tester, state);
  });

  testWidgets('视图切换:点详情显示列头,点网格隐藏列头', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(
        () => File(p.join(sharedDir, 'a.txt')).writeAsString('x'));

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('a.txt').evaluate().isNotEmpty);

    // 默认网格视图:没有列头「类型 / 大小 / 修改时间」。
    expect(find.text('修改时间'), findsNothing);

    // 切到详情视图:列头出现。
    await switchToList(tester);
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('修改时间'), findsOneWidget);

    // 切回网格:列头消失。
    await switchToGrid(tester);
    expect(find.text('修改时间'), findsNothing);

    await disposeState(tester, state);
  });

  testWidgets('列头排序:点「名称」切换升降序,行顺序反转', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    // 三个文件,默认按名称升序:a < b < c。
    await tester.runAsync(() async {
      await File(p.join(sharedDir, 'a.txt')).writeAsString('1');
      await File(p.join(sharedDir, 'b.txt')).writeAsString('2');
      await File(p.join(sharedDir, 'c.txt')).writeAsString('3');
    });

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('a.txt').evaluate().isNotEmpty);
    await switchToList(tester);

    // 升序:a 在 c 上方。
    expect(tester.getTopLeft(find.text('a.txt')).dy,
        lessThan(tester.getTopLeft(find.text('c.txt')).dy));

    // 点「名称」列头 → 切到降序:c 在 a 上方。
    await tester.tap(find.text('名称'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('c.txt')).dy,
        lessThan(tester.getTopLeft(find.text('a.txt')).dy));

    await disposeState(tester, state);
  });

  testWidgets('搜索过滤:输入关键字只保留匹配项,不区分大小写', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(() async {
      await File(p.join(sharedDir, 'Apple.txt')).writeAsString('1');
      await File(p.join(sharedDir, 'banana.txt')).writeAsString('2');
    });

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('Apple.txt').evaluate().isNotEmpty);

    // 在搜索框输入 "apple"(小写)。
    await tester.enterText(find.byType(TextField).first, 'apple');
    await tester.pumpAndSettle();

    expect(find.text('Apple.txt'), findsOneWidget);
    expect(find.text('banana.txt'), findsNothing);

    // 清空后两者都回来。
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(find.text('Apple.txt'), findsOneWidget);
    expect(find.text('banana.txt'), findsOneWidget);

    await disposeState(tester, state);
  });

  testWidgets('选择 + 状态栏:单击选中后显示「已选 1 项」', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(
        () => File(p.join(sharedDir, 'a.txt')).writeAsString('xyz'));

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('a.txt').evaluate().isNotEmpty);

    // 初始:状态栏显示「共 1 项」,没有「已选」。
    expect(find.textContaining('共 1 项'), findsOneWidget);

    // 单击选中。
    await tester.tap(find.text('a.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 项'), findsOneWidget);

    await disposeState(tester, state);
  });

  testWidgets('拖动:把 a.txt 拖到文件夹 sub 上 → 移动进 sub', (tester) async {
    final sharedDir = p.join(tmp.path, 'shared');
    final state = await configuredState(tester, sharedDir);

    await tester.runAsync(() async {
      await File(p.join(sharedDir, 'a.txt')).writeAsString('x');
      await Directory(p.join(sharedDir, 'sub')).create();
    });

    await pumpPage(tester, state);
    await settleUntil(tester, () => find.text('sub').evaluate().isNotEmpty);
    // 详情视图逐行,定位更稳。
    await switchToList(tester);

    // 从 a.txt 行拖到 sub 行中心(sub 主区项用 .first,避免命中侧栏树节点)。
    final from = tester.getCenter(find.text('a.txt'));
    final to = tester.getCenter(find.text('sub').first);
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(Offset(from.dx, from.dy - 20));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // 等真实文件 IO + 刷新完成:a.txt 从根消失。
    await settleUntil(tester, () => find.text('a.txt').evaluate().isEmpty);

    expect(File(p.join(sharedDir, 'a.txt')).existsSync(), isFalse);
    expect(File(p.join(sharedDir, 'sub', 'a.txt')).existsSync(), isTrue);

    await disposeState(tester, state);
  });

  // ---- 内部移动(纯逻辑 moveEntry) ----

  group('moveEntry(应用内移动)', () {
    test('把文件移动进子文件夹:源消失、目标出现', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final a = File(p.join(shared.path, 'a.txt'))..writeAsStringSync('hi');
      final sub = Directory(p.join(shared.path, 'sub'))..createSync();

      final r = await moveEntry(
        sharedDir: shared.path,
        sourceAbs: a.path,
        destDirAbs: sub.path,
      );

      expect(r.outcome, MoveOutcome.moved);
      expect(a.existsSync(), isFalse);
      expect(File(p.join(sub.path, 'a.txt')).existsSync(), isTrue);
    });

    test('把文件夹拖进它自己 → 拒绝(intoSelf),不破坏', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final sub = Directory(p.join(shared.path, 'sub'))..createSync();
      File(p.join(sub.path, 'keep.txt')).writeAsStringSync('k');

      final r = await moveEntry(
        sharedDir: shared.path,
        sourceAbs: sub.path,
        destDirAbs: sub.path, // 自身
      );

      expect(r.outcome, MoveOutcome.intoSelf);
      // 内容完好。
      expect(File(p.join(sub.path, 'keep.txt')).existsSync(), isTrue);
    });

    test('把文件夹拖进它的子孙 → 拒绝(intoSelf)', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final sub = Directory(p.join(shared.path, 'sub'))..createSync();
      final child = Directory(p.join(sub.path, 'child'))..createSync();

      final r = await moveEntry(
        sharedDir: shared.path,
        sourceAbs: sub.path,
        destDirAbs: child.path, // 子孙
      );

      expect(r.outcome, MoveOutcome.intoSelf);
      expect(sub.existsSync(), isTrue);
      expect(child.existsSync(), isTrue);
    });

    test('同一目录 → sameDir 无操作', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final a = File(p.join(shared.path, 'a.txt'))..writeAsStringSync('x');

      final r = await moveEntry(
        sharedDir: shared.path,
        sourceAbs: a.path,
        destDirAbs: shared.path,
      );

      expect(r.outcome, MoveOutcome.sameDir);
      expect(a.existsSync(), isTrue);
    });

    test('目标已存在同名 → nameClash 拒绝(不覆盖)', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final a = File(p.join(shared.path, 'a.txt'))..writeAsStringSync('new');
      final sub = Directory(p.join(shared.path, 'sub'))..createSync();
      final existing = File(p.join(sub.path, 'a.txt'))
        ..writeAsStringSync('old');

      final r = await moveEntry(
        sharedDir: shared.path,
        sourceAbs: a.path,
        destDirAbs: sub.path,
      );

      expect(r.outcome, MoveOutcome.nameClash);
      // 双方都未被破坏。
      expect(a.existsSync(), isTrue);
      expect(existing.readAsStringSync(), 'old');
    });

    test('目标越出共享根 → outsideRoot 拒绝', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final a = File(p.join(shared.path, 'a.txt'))..writeAsStringSync('x');
      final outside = Directory(p.join(tmp.path, 'outside'))..createSync();

      final r = await moveEntry(
        sharedDir: shared.path,
        sourceAbs: a.path,
        destDirAbs: outside.path,
      );

      expect(r.outcome, MoveOutcome.outsideRoot);
      expect(a.existsSync(), isTrue);
      expect(File(p.join(outside.path, 'a.txt')).existsSync(), isFalse);
    });
  });

  // ---- 外部导入复制(纯逻辑 importPaths) ----

  group('importPaths(外部导入复制)', () {
    test('复制文件成功:源保留、目标出现', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final src = File(p.join(tmp.path, 'ext.txt'))..writeAsStringSync('data');

      final r = await importPaths(
        sharedDir: shared.path,
        destDirAbs: shared.path,
        sourcePaths: [src.path],
      );

      expect(r.imported, 1);
      expect(r.renamed, 0);
      expect(r.hasError, isFalse);
      // 复制:源仍在。
      expect(src.existsSync(), isTrue);
      expect(
          File(p.join(shared.path, 'ext.txt')).readAsStringSync(), 'data');
    });

    test('名称冲突 → 自动改名 name (2).ext', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      File(p.join(shared.path, 'doc.txt')).writeAsStringSync('orig');
      final src = File(p.join(tmp.path, 'doc.txt'))..writeAsStringSync('incoming');

      final r = await importPaths(
        sharedDir: shared.path,
        destDirAbs: shared.path,
        sourcePaths: [src.path],
      );

      expect(r.imported, 1);
      expect(r.renamed, 1);
      // 原文件未被覆盖,新文件以 (2) 落地。
      expect(File(p.join(shared.path, 'doc.txt')).readAsStringSync(), 'orig');
      expect(File(p.join(shared.path, 'doc (2).txt')).readAsStringSync(),
          'incoming');
    });

    test('递归复制文件夹', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final srcDir = Directory(p.join(tmp.path, 'tree'))..createSync();
      File(p.join(srcDir.path, 'top.txt')).writeAsStringSync('t');
      final nested = Directory(p.join(srcDir.path, 'nested'))..createSync();
      File(p.join(nested.path, 'deep.txt')).writeAsStringSync('d');

      final r = await importPaths(
        sharedDir: shared.path,
        destDirAbs: shared.path,
        sourcePaths: [srcDir.path],
      );

      expect(r.imported, 1);
      expect(File(p.join(shared.path, 'tree', 'top.txt')).existsSync(), isTrue);
      expect(
          File(p.join(shared.path, 'tree', 'nested', 'deep.txt')).existsSync(),
          isTrue);
      // 源目录保留(复制而非移动)。
      expect(srcDir.existsSync(), isTrue);
    });

    test('目标目录越界 → 全部跳过', () async {
      final shared = Directory(p.join(tmp.path, 'shared'))
        ..createSync(recursive: true);
      final outside = Directory(p.join(tmp.path, 'outside'))..createSync();
      final src = File(p.join(tmp.path, 'ext.txt'))..writeAsStringSync('x');

      final r = await importPaths(
        sharedDir: shared.path,
        destDirAbs: outside.path,
        sourcePaths: [src.path],
      );

      expect(r.imported, 0);
      expect(r.skipped, 1);
      expect(r.hasError, isTrue);
      expect(File(p.join(outside.path, 'ext.txt')).existsSync(), isFalse);
    });
  });
}
