/// 设置向导校验逻辑测试:逐个非法输入应弹出对应 SnackBar 文案,且不触发保存。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:shared_sync_app/src/app_state.dart';
import 'package:shared_sync_app/src/settings_page.dart';

void main() {
  late Directory tmp;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shared_sync_settings_');
  });

  tearDown(() {
    state.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpFreshPage(WidgetTester tester) async {
    // UniqueKey 打在 MaterialApp 上:连 ScaffoldMessenger 一起重建,
    // 否则上一轮的 SnackBar 还在展示/排队,下一轮断言会命中旧文案。
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      home: Scaffold(body: SettingsPage(state: state)),
    ));
  }

  Finder fieldWithLabel(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextField));

  Future<void> tapSaveExpecting(WidgetTester tester, String message) async {
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(message), findsOneWidget,
        reason: '应弹出 SnackBar:$message');
  }

  testWidgets('向导必填项校验:目录/服务器/客户端 ID', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    state = AppState(prefsPath: p.join(tmp.path, 'app.json'));
    await tester.runAsync(state.load);
    expect(state.config, isNull, reason: '首次启动应进入向导');

    // 1. 共享目录为空(向导默认值)。
    await pumpFreshPage(tester);
    expect(find.text('欢迎使用 Shared Sync'), findsOneWidget);
    await tapSaveExpecting(tester, '请选择共享目录(绝对路径)');

    // 2. 共享目录是相对路径。
    await pumpFreshPage(tester);
    await tester.enterText(fieldWithLabel('共享目录'), 'relative/dir');
    await tapSaveExpecting(tester, '请选择共享目录(绝对路径)');

    // 3. 共享目录不存在。
    final missing = p.join(tmp.path, 'no-such-dir');
    await pumpFreshPage(tester);
    await tester.enterText(fieldWithLabel('共享目录'), missing);
    await tapSaveExpecting(tester, '共享目录不存在:$missing');

    // 4. 目录合法但服务器地址为空。
    await pumpFreshPage(tester);
    await tester.enterText(fieldWithLabel('共享目录'), tmp.path);
    await tapSaveExpecting(tester, '请填写服务器地址');

    // 5. 清空默认主机名后,客户端 ID 为空。
    await pumpFreshPage(tester);
    await tester.enterText(fieldWithLabel('共享目录'), tmp.path);
    await tester.enterText(
        fieldWithLabel('服务器地址'), 'http://127.0.0.1:8418/shared.git');
    await tester.enterText(fieldWithLabel('客户端 ID'), '   ');
    await tapSaveExpecting(tester, '请填写客户端 ID');

    // 校验失败时不得写入任何配置。
    expect(state.config, isNull);
    expect(File(p.join(tmp.path, 'app.json')).existsSync(), isFalse);

    // 让最后一个 SnackBar 超时退场,避免残留 pending timer。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('高级选项数值校验:间隔/稳定延迟/重试次数', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    state = AppState(prefsPath: p.join(tmp.path, 'app.json'));
    await tester.runAsync(state.load);

    Future<void> prepare(WidgetTester tester) async {
      await pumpFreshPage(tester);
      await tester.enterText(fieldWithLabel('共享目录'), tmp.path);
      await tester.enterText(
          fieldWithLabel('服务器地址'), 'http://127.0.0.1:8418/shared.git');
      await tester.tap(find.text('高级选项'));
      await tester.pumpAndSettle();
    }

    // 同步间隔必须是正整数。
    await prepare(tester);
    await tester.enterText(fieldWithLabel('自动同步间隔(秒)'), '0');
    await tapSaveExpecting(tester, '同步间隔必须是正整数(秒)');

    // 稳定延迟必须是非负整数。
    await prepare(tester);
    await tester.enterText(fieldWithLabel('文件稳定延迟(秒)'), '-1');
    await tapSaveExpecting(tester, '稳定延迟必须是非负整数(秒)');

    // 重试次数必须是非负整数。
    await prepare(tester);
    await tester.enterText(fieldWithLabel('推送重试次数'), 'abc');
    await tapSaveExpecting(tester, '推送重试次数必须是非负整数');

    expect(state.config, isNull);

    // 让最后一个 SnackBar 超时退场,避免残留 pending timer。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
