/// 共享测试工具:file:// bare 远端与测试用 SyncConfig。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_engine/sync_engine.dart';

/// 在 [dir] 创建一个 bare 仓库作为 `file://` 远端(必须在 runAsync 中调用)。
Future<void> createBareRemote(String dir) async {
  final r = await Process.run('git', ['init', '--bare', '--quiet', dir],
      environment: {'GIT_TERMINAL_PROMPT': '0', 'LC_ALL': 'C'});
  if (r.exitCode != 0) {
    fail('git init --bare failed: ${r.stderr}');
  }
}

/// 测试用配置:0 秒稳定延迟(刚写入的文件不能被冻结为 unstable),
/// 超长自动同步间隔(测试不靠定时器触发)。
SyncConfig makeConfig(String sharedDir, String serverDir) => SyncConfig(
      sharedDir: sharedDir,
      serverUrl: 'file://$serverDir',
      clientId: 'TEST-PC',
      fileStableDelaySeconds: 0,
      syncIntervalSeconds: 3600,
    );
