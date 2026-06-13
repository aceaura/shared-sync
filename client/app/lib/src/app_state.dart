/// 应用全局状态:持有 [SyncConfig] / [SyncEngine] 与最近事件环形列表。
///
/// 设计约束(DESIGN.md §6):单个 [ChangeNotifier],不引入额外状态管理框架;
/// 引擎的一切异常都在这一层捕获并转成返回值/文案,绝不让 UI 崩溃。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sync_engine/sync_engine.dart';

/// [SyncPhase] 的中文显示文案。
String phaseLabel(SyncPhase phase) => switch (phase) {
      SyncPhase.idle => '空闲',
      SyncPhase.scanning => '扫描中',
      SyncPhase.fetching => '拉取中',
      SyncPhase.planning => '规划中',
      SyncPhase.pushing => '推送中',
      SyncPhase.applying => '应用中',
      SyncPhase.error => '错误',
    };

/// `yyyy-MM-dd HH:mm:ss`(本地时区)。
String formatDateTime(DateTime t) {
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}'
      ' ${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

/// `HH:mm:ss`(本地时区)。
String formatTime(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// 应用全局状态。
///
/// 生命周期:启动后调用一次 [load];设置页保存配置时调用 [applyConfig]
/// (重建引擎);窗口关闭时由框架 dispose。
class AppState extends ChangeNotifier {
  /// [prefsPath] 仅测试注入用,默认放平台惯例的应用支持目录。
  AppState({String? prefsPath}) : prefsPath = prefsPath ?? _defaultPrefsPath();

  /// 应用级偏好文件,只记「上次使用的共享目录」;
  /// 同步配置本体始终存 `<sharedDir>/.sync/config.json`(引擎契约)。
  final String prefsPath;

  /// 事件环形列表上限。
  static const int maxEvents = 200;

  SyncConfig? _config;
  SyncEngine? _engine;
  SyncLogger? _logger;
  StreamSubscription<SyncReport>? _reportsSub;
  Timer? _phaseTimer;
  SyncPhase _lastSeenPhase = SyncPhase.idle;

  bool _initialized = false;
  bool _busy = false;
  bool _autoSync = false;
  bool _disposed = false;
  ThemeMode _themeMode = ThemeMode.system;
  SyncReport? _lastReport;
  DateTime? _lastSyncAt;
  String? _startupError;

  /// 最近事件,新事件在前,最多 [maxEvents] 条。
  final List<SyncEvent> events = [];

  /// 当前配置;为 null 表示首次启动(进设置向导)。
  SyncConfig? get config => _config;

  /// [load] 是否已结束(决定 UI 显示加载圈还是页面)。
  bool get initialized => _initialized;

  /// 引擎是否已创建并成功 initialize。
  bool get isConfigured => _engine != null;

  bool get autoSync => _autoSync;

  /// 界面风格:跟随系统 / 明亮 / 黑暗。应用级偏好,与共享目录无关。
  ThemeMode get themeMode => _themeMode;

  /// 启动阶段读取配置/初始化引擎的错误(显示为横幅)。
  String? get startupError => _startupError;

  SyncReport? get lastReport => _lastReport ?? _engine?.lastReport;

  /// 上次同步结束时刻。
  DateTime? get lastSyncAt => _lastSyncAt;

  SyncPhase get phase => _engine?.phase ?? SyncPhase.idle;

  /// 手动同步进行中,或引擎正处于某个同步阶段。
  bool get isSyncing =>
      _busy || (phase != SyncPhase.idle && phase != SyncPhase.error);

  /// 启动流程:读偏好 → 读 config.json → 创建并初始化引擎。
  /// 任何失败都只记入 [startupError],UI 落到设置向导。
  Future<void> load() async {
    try {
      // 界面风格独立于配置:即使未配置(首启向导)也要先恢复,确保深浅色正确。
      _themeMode = await _readSavedThemeMode();
      final dir = await _readSavedSharedDir();
      if (dir != null) {
        final cfg = await SyncConfig.load(dir);
        if (cfg != null) {
          // 启动前恢复上次的自动同步选择(缺省为开),令 _startEngine 自动续上。
          _autoSync = await _readSavedAutoSync();
          await _startEngine(cfg);
        }
      }
    } catch (e) {
      _startupError = '加载配置失败:$e';
    }
    _initialized = true;
    _notify();
  }

  /// 保存配置并(重)建引擎。返回 null 表示成功,否则为错误文案。
  Future<String?> applyConfig(SyncConfig cfg) async {
    try {
      await cfg.save();
      await _savePrefs(cfg.sharedDir, _autoSync);
      await _startEngine(cfg);
      _startupError = null;
      _notify();
      return null;
    } catch (e) {
      _notify();
      return '保存配置失败:$e';
    }
  }

  /// 触发一次手动同步。返回 null 表示成功(或正在同步中被忽略)。
  Future<String?> syncNow() async {
    final engine = _engine;
    if (engine == null) return '尚未完成配置';
    if (isSyncing) return null;
    _busy = true;
    _notify();
    try {
      // 契约上 syncOnce 永不抛异常(错误进 report.error),这里仍兜底。
      final report = await engine.syncOnce();
      return report.error == null ? null : '同步失败:${report.error}';
    } catch (e) {
      return '同步失败:$e';
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 设置界面风格(跟随系统 / 明亮 / 黑暗)并持久化。即时生效,无需配置完成。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _notify();
    await _savePrefs(_config?.sharedDir, _autoSync);
  }

  /// 开关自动同步。返回 null 表示成功。
  Future<String?> setAutoSync(bool enabled) async {
    final engine = _engine;
    final cfg = _config;
    if (engine == null || cfg == null) return '尚未完成配置';
    if (_autoSync == enabled) return null;
    _autoSync = enabled;
    _notify();
    try {
      if (enabled) {
        await engine.startAuto();
      } else {
        // 契约中 stop() 会释放锁并关闭 db,因此关闭自动同步后重建引擎,
        // 保证「立即同步」仍然可用。
        await _startEngine(cfg);
      }
      // 记住选择,下次启动自动续上。
      await _savePrefs(cfg.sharedDir, enabled);
      return null;
    } catch (e) {
      _autoSync = !enabled;
      _notify();
      return '切换自动同步失败:$e';
    }
  }

  /// 最近冲突记录(交给 FutureBuilder,读失败由页面展示错误)。
  Future<List<ConflictRecord>> recentConflicts({int limit = 100}) async {
    final engine = _engine;
    if (engine == null) return const [];
    return engine.recentConflicts(limit: limit);
  }

  /// 当天日志末尾 [lines] 行;未配置时返回空。
  Future<List<String>> tailLogs(int lines) async {
    final logger = _logger;
    if (logger == null) return const [];
    return logger.tail(lines);
  }

  /// 在系统文件管理器中显示 [relativePath](共享根的正斜杠相对路径)。
  /// 文件已不存在时退而打开其父目录。返回 null 表示成功。
  Future<String?> revealInFileManager(String relativePath) async {
    final cfg = _config;
    if (cfg == null) return '尚未完成配置';
    final abs = p.joinAll([cfg.sharedDir, ...relativePath.split('/')]);
    final exists =
        FileSystemEntity.typeSync(abs) != FileSystemEntityType.notFound;
    try {
      if (Platform.isMacOS) {
        await Process.run(
            'open', exists ? ['-R', abs] : [p.dirname(abs)]);
      } else if (Platform.isWindows) {
        // explorer 的 /select, 与路径之间不能有空格分隔参数。
        await Process.run(
            'explorer', [exists ? '/select,$abs' : p.dirname(abs)]);
      } else {
        await Process.run('xdg-open', [p.dirname(abs)]);
      }
      return null;
    } catch (e) {
      return '无法打开文件管理器:$e';
    }
  }

  Future<void> _startEngine(SyncConfig cfg) async {
    await _teardownEngine();
    _config = cfg;
    _logger = SyncLogger(cfg.logsDir, alsoConsole: false);
    final engine = SyncEngine(cfg, logger: _logger, onEvent: _handleEvent);
    // initialize 失败时保留 config/logger(向导可回填、日志页可用),
    // 但 isConfigured 保持 false。
    await engine.initialize();
    _engine = engine;
    _reportsSub = engine.reports.listen(_handleReport);
    _lastSeenPhase = engine.phase;
    _phaseTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final current = phase;
      if (current != _lastSeenPhase) {
        _lastSeenPhase = current;
        _notify();
      }
    });
    if (_autoSync) {
      await engine.startAuto();
    }
  }

  Future<void> _teardownEngine() async {
    _phaseTimer?.cancel();
    _phaseTimer = null;
    await _reportsSub?.cancel();
    _reportsSub = null;
    final old = _engine;
    _engine = null;
    if (old != null) {
      try {
        await old.stop();
      } catch (_) {
        // 旧引擎已不可用,停止失败不影响重建。
      }
    }
    _logger?.close();
    _logger = null;
  }

  void _handleEvent(SyncEvent event) {
    events.insert(0, event);
    if (events.length > maxEvents) {
      events.removeRange(maxEvents, events.length);
    }
    _notify();
  }

  void _handleReport(SyncReport report) {
    _lastReport = report;
    _lastSyncAt = report.startedAt.add(report.duration);
    _notify();
  }

  // 引擎回调可能在 dispose 之后到达,必须吞掉。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardownEngine());
    super.dispose();
  }

  Future<Map<String, dynamic>> _readPrefs() async {
    final file = File(prefsPath);
    if (!await file.exists()) return const {};
    final json = jsonDecode(await file.readAsString());
    return json is Map<String, dynamic> ? json : const {};
  }

  Future<String?> _readSavedSharedDir() async {
    final dir = (await _readPrefs())['sharedDir'];
    return (dir is String && dir.isNotEmpty) ? dir : null;
  }

  /// 自动同步是同步应用的预期默认:偏好缺省键时返回 true,所以全新配置和
  /// 升级前未记录该键的客户端启动后都会自动持续同步,无需每次手动开启。
  Future<bool> _readSavedAutoSync() async {
    final value = (await _readPrefs())['autoSync'];
    return value is bool ? value : true;
  }

  /// 界面风格偏好;缺省/非法值回退跟随系统。
  Future<ThemeMode> _readSavedThemeMode() async {
    final value = (await _readPrefs())['themeMode'];
    return switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  /// 写偏好文件。[sharedDir] 为 null 时保留已存的目录(改主题不应丢失目录)。
  Future<void> _savePrefs(String? sharedDir, bool autoSync) async {
    final existing = await _readPrefs();
    final dir = sharedDir ?? existing['sharedDir'];
    final file = File(prefsPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
        '${jsonEncode({
              if (dir is String && dir.isNotEmpty) 'sharedDir': dir,
              'autoSync': autoSync,
              'themeMode': _themeMode.name,
            })}\n',
        flush: true);
  }

  static String _defaultPrefsPath() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final base = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
      return p.join(base, 'SharedSync', 'app.json');
    }
    final home = env['HOME'] ?? '.';
    if (Platform.isMacOS) {
      return p.join(
          home, 'Library', 'Application Support', 'SharedSync', 'app.json');
    }
    final xdg = env['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
    return p.join(xdg, 'shared-sync', 'app.json');
  }
}
