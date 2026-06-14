/// 连接页(v2 自适应连接可视化,DESIGN_v2.md §4/§5)。
///
/// 周期轮询 connd 的本地状态端点 `GET http://127.0.0.1:4243/status`,
/// 把三层阶梯状态机的当前层 / 是否经 VPS / 对端 / underlay / RTT / 切层时间 /
/// nebula 运行态 / 三层健康向量,渲染成中文可读的连接面板。
///
/// 设计约束(沿用 client/app 既有风格):
/// - 纯 Dart `dart:io` HttpClient,不引新依赖;
/// - 「取 status」抽成可注入的 [ConnStatusFetcher],测试注入假数据,绝不真连网络;
/// - connd 不可达 → 友好提示,不报错不崩(任何异常都吞成 unreachable)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// connd `/status` 端点默认地址(仅回环)。见 v2/connd README「status API 格式」。
const String kConndStatusUrl = 'http://127.0.0.1:4243/status';

/// connd 上报的连接层。`RECONNECTING` 表示全层不健康、正在重连。
enum ConnTier { t0, t1, t2, reconnecting, unknown }

/// 把 connd 的 `tier` 字符串(T0/T1/T2/RECONNECTING)解析为枚举。
ConnTier parseConnTier(Object? raw) {
  final s = (raw is String) ? raw.trim().toUpperCase() : '';
  return switch (s) {
    'T0' => ConnTier.t0,
    'T1' => ConnTier.t1,
    'T2' => ConnTier.t2,
    'RECONNECTING' => ConnTier.reconnecting,
    _ => ConnTier.unknown,
  };
}

/// connd `/status` 的解析结果(只取页面要用的字段;多余字段忽略)。
///
/// 字段对应 connd `controller.Status`(json tag 见
/// v2/connd/internal/controller/controller.go)。
class ConnStatus {
  const ConnStatus({
    required this.tier,
    required this.viaVps,
    required this.peer,
    required this.upstream,
    required this.currentRemote,
    required this.rttMs,
    required this.since,
    required this.lastSwitch,
    required this.tiersHealth,
    required this.reconnecting,
    required this.nebula,
  });

  final ConnTier tier;
  final bool viaVps;
  final String peer;
  final String upstream;

  /// 当前 underlay(nebula hostmap 的 currentRemote);T1/T2 时通常为空。
  final String currentRemote;

  /// overlay 心跳 RTT(毫秒);null 表示无数据。
  final double? rttMs;
  final DateTime? since;
  final DateTime? lastSwitch;

  /// 三层健康向量:键 T0/T1/T2,值 "UP"/"DOWN"。
  final Map<String, String> tiersHealth;
  final bool reconnecting;

  /// nebula 子进程运行态(如 RUNNING / STOPPED)。
  final String nebula;

  /// 从 connd `/status` 的 JSON map 宽松解析;缺字段取安全默认,绝不抛。
  factory ConnStatus.fromJson(Map<String, dynamic> j) {
    double? rtt;
    final r = j['rttMs'];
    if (r is num) rtt = r.toDouble();

    final health = <String, String>{};
    final th = j['tiersHealth'];
    if (th is Map) {
      th.forEach((k, v) {
        if (k is String && v != null) health[k] = v.toString();
      });
    }

    return ConnStatus(
      tier: parseConnTier(j['tier']),
      viaVps: j['viaVps'] == true,
      peer: _str(j['peer']),
      upstream: _str(j['upstream']),
      currentRemote: _str(j['currentRemote']),
      rttMs: rtt,
      since: _dt(j['since']),
      lastSwitch: _dt(j['lastSwitch']),
      tiersHealth: health,
      reconnecting: j['reconnecting'] == true,
      nebula: _str(j['nebula']),
    );
  }

  static String _str(Object? v) => v is String ? v : '';

  static DateTime? _dt(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }
}

/// 「取 status」接口:返回解析好的 [ConnStatus];connd 不可达/解析失败返回 null。
///
/// 抽成接口是为了测试可注入假数据(见 test/connection_page_test.dart),
/// 生产用 [HttpConnStatusFetcher] 真打本地端点。
typedef ConnStatusFetcher = Future<ConnStatus?> Function();

/// 生产实现:`dart:io` HttpClient 打 connd 本地端点,任何异常/非 200 → null。
class HttpConnStatusFetcher {
  HttpConnStatusFetcher({String url = kConndStatusUrl, Duration? timeout})
      : _uri = Uri.parse(url),
        _timeout = timeout ?? const Duration(seconds: 2);

  final Uri _uri;
  final Duration _timeout;

  Future<ConnStatus?> call() async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(_uri).timeout(_timeout);
      final resp = await req.close().timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      return ConnStatus.fromJson(decoded);
    } catch (_) {
      // connd 未运行 / 拒连 / 超时 / 坏 JSON:统一当作不可达,页面给友好提示。
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// 连接页:每 [pollInterval] 拉一次 connd `/status` 并渲染。
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    ConnStatusFetcher? fetcher,
    this.pollInterval = const Duration(seconds: 2),
    this.autoStart = true,
  }) : fetcher = fetcher ?? _defaultFetcher;

  /// 状态获取函数(可注入;默认打 connd 本地端点)。
  final ConnStatusFetcher fetcher;

  /// 轮询周期。
  final Duration pollInterval;

  /// 是否启动周期定时器(测试中置 false,纯手动 pump 控制)。
  final bool autoStart;

  static Future<ConnStatus?> _defaultFetcher() => HttpConnStatusFetcher()();

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  Timer? _timer;
  ConnStatus? _status;

  /// 首拉是否已完成(完成前显示加载圈,而非「未检测到 connd」误报)。
  bool _loaded = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // 进页面立即拉一次,再按周期续。
    unawaited(_poll());
    if (widget.autoStart) {
      _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_refreshing) return;
    _refreshing = true;
    ConnStatus? next;
    try {
      next = await widget.fetcher();
    } catch (_) {
      // fetcher 契约上不抛,这里再兜一层:异常一律视为不可达。
      next = null;
    } finally {
      _refreshing = false;
    }
    if (!mounted) return;
    setState(() {
      _status = next;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('连接状态', style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              Text(
                kConndStatusUrl,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(_poll()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final status = _status;
    if (status == null) {
      return const _ConndUnreachable();
    }
    return _ConnStatusView(status: status);
  }
}

/// connd 不可达时的友好占位。
class _ConndUnreachable extends StatelessWidget {
  const _ConndUnreachable();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lan_outlined, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          const Text('未检测到 connd(连接管理器未运行)'),
          const SizedBox(height: 6),
          Text(
            '将周期重试 $kConndStatusUrl',
            style: TextStyle(color: scheme.outline, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 某一层的展示元信息:中文名、说明、配色。
class _TierMeta {
  const _TierMeta(this.label, this.desc, this.color);
  final String label;
  final String desc;
  final Color color;
}

_TierMeta _tierMeta(ConnTier tier) => switch (tier) {
      ConnTier.t0 => const _TierMeta(
          'T0 直连', '直连 P2P,未过中转中心', Colors.green),
      ConnTier.t1 => const _TierMeta(
          'T1 UDP中继', '经 VPS UDP 中继', Colors.amber),
      ConnTier.t2 => const _TierMeta(
          'T2 TCP兜底', '经 VPS TCP 隧道兜底', Colors.orange),
      ConnTier.reconnecting =>
        const _TierMeta('RECONNECTING', '重连中', Colors.red),
      ConnTier.unknown => const _TierMeta('未知', '层状态未知', Colors.grey),
    };

/// 有 status 时的主体:层徽标 + 明细行 + 三层健康。
class _ConnStatusView extends StatelessWidget {
  const _ConnStatusView({required this.status});

  final ConnStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        _TierBadge(tier: status.tier),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _InfoRow(
                  icon: Icons.alt_route,
                  label: '经 VPS 中转',
                  value: status.viaVps ? '是' : '否',
                ),
                _InfoRow(
                  icon: Icons.devices,
                  label: '对端 peer',
                  value: _orDash(status.peer),
                ),
                _InfoRow(
                  icon: Icons.cable,
                  label: '当前 underlay',
                  value: _orDash(status.currentRemote),
                ),
                _InfoRow(
                  icon: Icons.swap_horiz,
                  label: '上游 upstream',
                  value: _orDash(status.upstream),
                ),
                _InfoRow(
                  icon: Icons.speed,
                  label: 'RTT',
                  value: status.rttMs == null
                      ? '—'
                      : '${status.rttMs!.toStringAsFixed(2)} ms',
                ),
                _InfoRow(
                  icon: Icons.schedule,
                  label: '上次切层',
                  value: status.lastSwitch == null
                      ? '—'
                      : _fmt(status.lastSwitch!),
                ),
                _InfoRow(
                  icon: Icons.hub,
                  label: 'nebula 运行态',
                  value: _orDash(status.nebula),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('三层健康', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final t in const ['T0', 'T1', 'T2'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _HealthChip(
                  tier: t,
                  // 缺键时视为 DOWN(保守)。
                  up: (status.tiersHealth[t] ?? 'DOWN').toUpperCase() == 'UP',
                ),
              ),
          ],
        ),
      ],
    );
  }

  static String _orDash(String s) => s.isEmpty ? '—' : s;

  static String _fmt(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }
}

/// 当前层大徽标:配色 + 中文名 + 说明。
class _TierBadge extends StatelessWidget {
  const _TierBadge({required this.tier});

  final ConnTier tier;

  @override
  Widget build(BuildContext context) {
    final meta = _tierMeta(tier);
    final color = meta.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 14, color: color),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                meta.label,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                meta.desc,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 明细行:图标 + 标签 + 值。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 12),
          SizedBox(width: 120, child: Text(label)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单层健康小徽标:UP 绿 / DOWN 灰红。
class _HealthChip extends StatelessWidget {
  const _HealthChip({required this.tier, required this.up});

  final String tier;
  final bool up;

  @override
  Widget build(BuildContext context) {
    final color = up ? Colors.green : Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.check_circle : Icons.cancel,
              size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            '$tier ${up ? 'UP' : 'DOWN'}',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
