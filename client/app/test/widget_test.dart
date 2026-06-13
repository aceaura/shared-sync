// 冒烟测试:未配置状态下应用能正常渲染,并落到设置向导。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_sync_app/main.dart';
import 'package:shared_sync_app/src/app_state.dart';

void main() {
  testWidgets('未配置时显示导航栏并落到设置向导', (WidgetTester tester) async {
    final tempDir = Directory.systemTemp.createTempSync('shared_sync_app_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    // 偏好文件不存在 → config == null → 设置向导。
    // load 含真实文件 IO,必须在 runAsync 中执行,否则 FakeAsync 区会挂起。
    final state = AppState(prefsPath: '${tempDir.path}/app.json');
    await tester.runAsync(state.load);
    expect(state.initialized, isTrue);
    expect(state.isConfigured, isFalse);

    await tester.pumpWidget(SharedSyncApp(state: state));
    await tester.pump();
    await tester.pump();

    // 四个导航项齐全。
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('冲突'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);

    // 设置向导可见;状态页(在 IndexedStack 中保活、offstage)展示未配置占位。
    expect(find.text('欢迎使用 Shared Sync'), findsOneWidget);
    expect(find.text('保存配置'), findsOneWidget);
    expect(find.text('前往设置', skipOffstage: false), findsOneWidget);
  });
}
