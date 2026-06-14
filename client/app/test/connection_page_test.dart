/// 连接页渲染测试:注入假 status fetcher(不真连网络),断言各层徽标/文案、
/// 三层健康指示、明细字段,以及 connd 不可达时的友好提示。
///
/// 关键约束:全部用可注入的 [ConnStatusFetcher] 喂假数据,`autoStart: false`
/// 关掉周期定时器,靠手动 pump 驱动首拉完成,避免残留 pending timer。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_sync_app/src/connection_page.dart';

void main() {
  /// 构造一份 status,默认 T0 全绿,可覆盖单字段。
  ConnStatus makeStatus({
    ConnTier tier = ConnTier.t0,
    bool viaVps = false,
    String peer = '10.77.0.1',
    String upstream = '10.77.0.1:8418',
    String currentRemote = '54.198.93.78:4242',
    double? rttMs = 0.45,
    DateTime? lastSwitch,
    Map<String, String>? tiersHealth,
    bool reconnecting = false,
    String nebula = 'RUNNING',
  }) {
    return ConnStatus(
      tier: tier,
      viaVps: viaVps,
      peer: peer,
      upstream: upstream,
      currentRemote: currentRemote,
      rttMs: rttMs,
      since: DateTime(2026, 6, 14, 12, 0, 0),
      lastSwitch: lastSwitch ?? DateTime(2026, 6, 14, 12, 0, 0),
      tiersHealth: tiersHealth ?? const {'T0': 'UP', 'T1': 'UP', 'T2': 'DOWN'},
      reconnecting: reconnecting,
      nebula: nebula,
    );
  }

  /// 用给定 fetcher 挂载页面并完成首拉(autoStart=false → 无周期定时器)。
  Future<void> pumpWith(
    WidgetTester tester,
    ConnStatusFetcher fetcher,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConnectionPage(fetcher: fetcher, autoStart: false),
      ),
    ));
    // initState 的首拉是 microtask:pump 一次冲掉,setState 后再 pump 出 UI。
    await tester.pump();
    await tester.pump();
  }

  testWidgets('T0:直连徽标 + 文案 + 经VPS否', (tester) async {
    final s = makeStatus(tier: ConnTier.t0, viaVps: false);
    await pumpWith(tester, () async => s);

    expect(find.text('T0 直连'), findsOneWidget);
    expect(find.text('直连 P2P,未过中转中心'), findsOneWidget);
    // 明细:经 VPS 否、peer、underlay、RTT、nebula。
    expect(find.text('否'), findsOneWidget);
    expect(find.text('10.77.0.1'), findsOneWidget);
    expect(find.text('54.198.93.78:4242'), findsOneWidget);
    expect(find.text('0.45 ms'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);
    // 三层健康:T0/T1 UP、T2 DOWN。
    expect(find.text('T0 UP'), findsOneWidget);
    expect(find.text('T1 UP'), findsOneWidget);
    expect(find.text('T2 DOWN'), findsOneWidget);
    expect(find.text('未检测到 connd(连接管理器未运行)'), findsNothing);
  });

  testWidgets('T1:UDP中继徽标 + 文案 + 经VPS是', (tester) async {
    final s = makeStatus(
      tier: ConnTier.t1,
      viaVps: true,
      currentRemote: '',
      tiersHealth: const {'T0': 'DOWN', 'T1': 'UP', 'T2': 'DOWN'},
    );
    await pumpWith(tester, () async => s);

    expect(find.text('T1 UDP中继'), findsOneWidget);
    expect(find.text('经 VPS UDP 中继'), findsOneWidget);
    expect(find.text('是'), findsOneWidget);
    // T1 时 underlay 空 → 破折号占位。
    expect(find.text('T0 DOWN'), findsOneWidget);
    expect(find.text('T1 UP'), findsOneWidget);
  });

  testWidgets('T2:TCP兜底徽标 + 文案', (tester) async {
    final s = makeStatus(
      tier: ConnTier.t2,
      viaVps: true,
      tiersHealth: const {'T0': 'DOWN', 'T1': 'DOWN', 'T2': 'UP'},
    );
    await pumpWith(tester, () async => s);

    expect(find.text('T2 TCP兜底'), findsOneWidget);
    expect(find.text('经 VPS TCP 隧道兜底'), findsOneWidget);
    expect(find.text('T2 UP'), findsOneWidget);
  });

  testWidgets('RECONNECTING:重连徽标 + 文案', (tester) async {
    final s = makeStatus(
      tier: ConnTier.reconnecting,
      reconnecting: true,
      tiersHealth: const {'T0': 'DOWN', 'T1': 'DOWN', 'T2': 'DOWN'},
    );
    await pumpWith(tester, () async => s);

    expect(find.text('RECONNECTING'), findsOneWidget);
    expect(find.text('重连中'), findsOneWidget);
    // 全层 DOWN。
    expect(find.text('T0 DOWN'), findsOneWidget);
    expect(find.text('T1 DOWN'), findsOneWidget);
    expect(find.text('T2 DOWN'), findsOneWidget);
  });

  testWidgets('connd 不可达:友好提示,不报错不崩', (tester) async {
    await pumpWith(tester, () async => null);

    expect(find.text('未检测到 connd(连接管理器未运行)'), findsOneWidget);
    // 不应渲染任何层徽标。
    expect(find.text('T0 直连'), findsNothing);
    expect(find.text('RECONNECTING'), findsNothing);
  });

  testWidgets('首拉完成前显示加载圈(fetcher 未返回时)', (tester) async {
    // fetcher 永不完成 → 页面停在加载态,既不误报不可达也不崩。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConnectionPage(
          fetcher: () => Completer<ConnStatus?>().future,
          autoStart: false,
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('未检测到 connd(连接管理器未运行)'), findsNothing);
  });

  test('ConnStatus.fromJson:宽松解析 connd /status 真实样例', () {
    final s = ConnStatus.fromJson(const {
      'tier': 'T0',
      'viaVps': false,
      'peer': '10.77.0.1',
      'upstream': '10.77.0.1:8418',
      'localEndpoint': '127.0.0.1:8418',
      'rttMs': 0.45,
      'currentRemote': '54.198.93.78:4242',
      'since': '2026-06-14T04:59:15Z',
      'lastSwitch': '2026-06-14T04:59:15Z',
      'tiersHealth': {'T0': 'UP', 'T1': 'UP', 'T2': 'DOWN'},
      'reconnecting': false,
      'nebula': 'RUNNING',
      'updatedAt': '2026-06-14T04:59:15Z',
      'path': 'DIRECT',
      'state': 'T0',
    });
    expect(s.tier, ConnTier.t0);
    expect(s.viaVps, isFalse);
    expect(s.peer, '10.77.0.1');
    expect(s.rttMs, 0.45);
    expect(s.tiersHealth['T2'], 'DOWN');
    expect(s.nebula, 'RUNNING');
    expect(s.lastSwitch, isNotNull);
  });

  test('parseConnTier:大小写/未知值兜底', () {
    expect(parseConnTier('T0'), ConnTier.t0);
    expect(parseConnTier('t1'), ConnTier.t1);
    expect(parseConnTier('RECONNECTING'), ConnTier.reconnecting);
    expect(parseConnTier('garbage'), ConnTier.unknown);
    expect(parseConnTier(null), ConnTier.unknown);
  });
}
