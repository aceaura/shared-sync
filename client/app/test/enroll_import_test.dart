/// importEnrollBundle 单测:用 v2/deploy/dist/winpc 真实接入包样例为输入,
/// 拷到临时目录后导入到另一临时数据目录,断言:
///   - 文件全部写出(含一对 client-*.crt/.key 与可选 .pub);
///   - node.yml / connd.yaml 里的 /etc/nebula/ 已改写为数据目录(正斜杠);
///   - connd.yaml 的 binPath 指向数据目录下的 nebula(可执行名可配);
///   - server_url 恒为 connd 本地端点;overlay/客户端名/数据中心 overlay 解析正确;
///   - 缺文件报 ImportBundleException。
///
/// 纯文件/字符串逻辑,不起进程、不碰特权、不连网络。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:shared_sync_app/src/app_state.dart';

void main() {
  // 仓库根:本测试文件在 client/app/test/,上溯三级到 shared-sync 根。
  final repoRoot =
      p.normalize(p.join(Directory.current.path, '..', '..'));
  final sampleBundle = p.join(repoRoot, 'v2', 'deploy', 'dist', 'winpc');

  late Directory tmp;
  late String bundleDir; // 样例的可写拷贝
  late String targetDir; // 导入目标数据目录

  setUpAll(() {
    // 样例必须存在,否则测试前提不成立。
    expect(Directory(sampleBundle).existsSync(), isTrue,
        reason: '缺少样例接入包:$sampleBundle');
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shared_sync_enroll_');
    bundleDir = p.join(tmp.path, 'bundle');
    targetDir = p.join(tmp.path, 'data', 'shared-sync');
    _copyDir(sampleBundle, bundleDir);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('导入真实样例:文件写出、路径改写、解析正确', () {
    final result = importEnrollBundle(
      bundleDir: bundleDir,
      targetDir: targetDir,
    );

    // server_url 恒为固定本地端点。
    expect(result.serverUrl, 'http://127.0.0.1:8418/shared.git');
    expect(result.serverUrl, kConndServerUrl);

    // 解析摘要(对照 winpc 样例 MANIFEST/connd.yaml)。
    expect(result.clientName, 'winpc');
    expect(result.overlayIp, '10.77.0.13');
    expect(result.dataCenterOverlay, '10.77.0.2');
    expect(result.targetDir, p.normalize(Directory(targetDir).absolute.path));

    // 必需文件 + 该对客户端证书都写出。
    expect(
      result.writtenFiles,
      containsAll(<String>[
        'node.yml',
        'connd.yaml',
        'frpc-visitor.toml',
        'ca.crt',
        'ctl_key',
        'sshd_hostkey',
        'client-winpc.crt',
        'client-winpc.key',
      ]),
    );
    // 样例带 .pub,应一并存档。
    expect(result.writtenFiles, contains('ctl_key.pub'));
    expect(result.writtenFiles, contains('sshd_hostkey.pub'));
    // 写出的文件确实落盘。
    for (final name in result.writtenFiles) {
      expect(File(p.join(targetDir, name)).existsSync(), isTrue,
          reason: '应写出 $name');
    }

    // 路径改写:数据目录的正斜杠形式。
    final fwd = result.targetDir.replaceAll('\\', '/');

    final nodeYml = File(p.join(targetDir, 'node.yml')).readAsStringSync();
    expect(nodeYml.contains('/etc/nebula/'), isFalse,
        reason: 'node.yml 不应残留 Linux 路径');
    expect(nodeYml, contains('$fwd/ca.crt'));
    expect(nodeYml, contains('$fwd/client-winpc.crt'));
    expect(nodeYml, contains('$fwd/client-winpc.key'));
    expect(nodeYml, contains('$fwd/sshd_hostkey'));

    final conndYaml = File(p.join(targetDir, 'connd.yaml')).readAsStringSync();
    expect(conndYaml.contains('/etc/nebula/'), isFalse,
        reason: 'connd.yaml 不应残留 Linux 路径');
    expect(conndYaml, contains('keyPath: $fwd/ctl_key'));
    expect(conndYaml, contains('configPath: $fwd/node.yml'));
    // 默认 nebula 名。
    expect(conndYaml, contains('binPath: $fwd/nebula'));
  });

  test('nebulaBinName 改写 binPath(Windows 可执行名)', () {
    final result = importEnrollBundle(
      bundleDir: bundleDir,
      targetDir: targetDir,
      nebulaBinName: 'nebula.exe',
    );
    final fwd = result.targetDir.replaceAll('\\', '/');
    final conndYaml = File(p.join(targetDir, 'connd.yaml')).readAsStringSync();
    expect(conndYaml, contains('binPath: $fwd/nebula.exe'));
    // 没有残留裸 nebula(无 .exe)的 binPath 行。
    expect(RegExp(r'binPath:\s*nebula\s*$', multiLine: true).hasMatch(conndYaml),
        isFalse);
  });

  test('目标目录不存在时自动创建并写入', () {
    final deep = p.join(tmp.path, 'a', 'b', 'c', 'data');
    expect(Directory(deep).existsSync(), isFalse);
    final result =
        importEnrollBundle(bundleDir: bundleDir, targetDir: deep);
    expect(Directory(deep).existsSync(), isTrue);
    expect(File(p.join(deep, 'connd.yaml')).existsSync(), isTrue);
    expect(result.writtenFiles, contains('connd.yaml'));
  });

  test('缺少必需文件报 ImportBundleException', () {
    File(p.join(bundleDir, 'connd.yaml')).deleteSync();
    expect(
      () => importEnrollBundle(bundleDir: bundleDir, targetDir: targetDir),
      throwsA(isA<ImportBundleException>()
          .having((e) => e.message, 'message', contains('connd.yaml'))),
    );
  });

  test('缺少 client-*.crt 报错(通配必需文件)', () {
    File(p.join(bundleDir, 'client-winpc.crt')).deleteSync();
    expect(
      () => importEnrollBundle(bundleDir: bundleDir, targetDir: targetDir),
      throwsA(isA<ImportBundleException>()
          .having((e) => e.message, 'message', contains('client-*.crt'))),
    );
  });

  test('接入包目录不存在报错', () {
    expect(
      () => importEnrollBundle(
          bundleDir: p.join(tmp.path, 'nope'), targetDir: targetDir),
      throwsA(isA<ImportBundleException>()),
    );
  });
}

/// 递归复制目录里的普通文件(样例为扁平目录,够用)。
void _copyDir(String src, String dst) {
  Directory(dst).createSync(recursive: true);
  for (final e in Directory(src).listSync()) {
    if (e is File) {
      e.copySync(p.join(dst, p.basename(e.path)));
    }
  }
}
