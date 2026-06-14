/// 设置页:首次启动向导 + 配置修改(保存即重建引擎)。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sync_engine/sync_engine.dart';

import 'app_state.dart';

/// 设置页。`state.config == null` 时呈现首次配置向导文案。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _dirCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _clientCtrl;
  late final TextEditingController _intervalCtrl;
  late final TextEditingController _stableCtrl;
  late final TextEditingController _retriesCtrl;
  bool _saving = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    final cfg = widget.state.config;
    _dirCtrl = TextEditingController(text: cfg?.sharedDir ?? '');
    _serverCtrl = TextEditingController(text: cfg?.serverUrl ?? '');
    _clientCtrl =
        TextEditingController(text: cfg?.clientId ?? Platform.localHostname);
    _intervalCtrl = TextEditingController(
        text:
            '${cfg?.syncIntervalSeconds ?? SyncConfig.defaultSyncIntervalSeconds}');
    _stableCtrl = TextEditingController(
        text:
            '${cfg?.fileStableDelaySeconds ?? SyncConfig.defaultFileStableDelaySeconds}');
    _retriesCtrl = TextEditingController(
        text: '${cfg?.maxPushRetries ?? SyncConfig.defaultMaxPushRetries}');
  }

  @override
  void dispose() {
    _dirCtrl.dispose();
    _serverCtrl.dispose();
    _clientCtrl.dispose();
    _intervalCtrl.dispose();
    _stableCtrl.dispose();
    _retriesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final dir = await getDirectoryPath();
    if (dir != null) {
      _dirCtrl.text = dir;
    }
  }

  /// 导入接入包(enroll 产出目录):落到本机固定数据目录、改写路径、回填
  /// server_url 并保存。连接层(connd/nebula/frpc)由安装服务接管(DESIGN_v2 §Phase7)。
  /// 目前先支持选【目录】;zip 支持留待后续(见设计文档 TODO)。
  Future<void> _importBundle() async {
    final messenger = ScaffoldMessenger.of(context);
    final dir = await getDirectoryPath();
    if (dir == null) return; // 用户取消。
    setState(() => _importing = true);
    try {
      final result = await widget.state.importBundle(dir);
      if (!mounted) return;
      // 把固定本地端点回填到服务器地址框(已配置时 importBundle 已保存配置)。
      _serverCtrl.text = result.serverUrl;
      final who = result.clientName.isEmpty ? '' : '(${result.clientName})';
      messenger.showSnackBar(SnackBar(
        content: Text('接入包已导入$who → ${result.targetDir};'
            '连接层将由安装服务接管。共享目录设好并保存即可同步。'),
      ));
    } on ImportBundleException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('导入失败:${e.message}')));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('导入失败:$e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 校验输入,返回错误文案;全部合法返回 null。
  String? _validate() {
    final dir = _dirCtrl.text.trim();
    if (dir.isEmpty || !p.isAbsolute(dir)) return '请选择共享目录(绝对路径)';
    if (!Directory(dir).existsSync()) return '共享目录不存在:$dir';
    if (_serverCtrl.text.trim().isEmpty) return '请填写服务器地址';
    if (_clientCtrl.text.trim().isEmpty) return '请填写客户端 ID';
    final interval = int.tryParse(_intervalCtrl.text.trim());
    if (interval == null || interval <= 0) return '同步间隔必须是正整数(秒)';
    final stable = int.tryParse(_stableCtrl.text.trim());
    if (stable == null || stable < 0) return '稳定延迟必须是非负整数(秒)';
    final retries = int.tryParse(_retriesCtrl.text.trim());
    if (retries == null || retries < 0) return '推送重试次数必须是非负整数';
    return null;
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final problem = _validate();
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() => _saving = true);
    final old = widget.state.config;
    final cfg = SyncConfig(
      sharedDir: _dirCtrl.text.trim(),
      serverUrl: _serverCtrl.text.trim(),
      clientId: _clientCtrl.text.trim(),
      syncIntervalSeconds: int.parse(_intervalCtrl.text.trim()),
      fileStableDelaySeconds: int.parse(_stableCtrl.text.trim()),
      maxPushRetries: int.parse(_retriesCtrl.text.trim()),
      // UI 不暴露这两项,沿用既有值。
      conflictNameTemplate:
          old?.conflictNameTemplate ?? SyncConfig.defaultConflictNameTemplate,
      ignoreFileName: old?.ignoreFileName ?? SyncConfig.defaultIgnoreFileName,
    );
    final error = await widget.state.applyConfig(cfg);
    if (!mounted) return;
    setState(() => _saving = false);
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? '配置已保存,同步引擎已就绪')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWizard = widget.state.config == null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWizard) ...[
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('欢迎使用 Shared Sync',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        const Text('首次使用请完成以下配置:选择要同步的共享目录、'
                            '填写服务器地址,保存后即可开始同步。'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (widget.state.startupError != null) ...[
                Text(
                  widget.state.startupError!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 16),
              ],
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('界面风格',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('跟随系统'),
                            icon: Icon(Icons.brightness_auto),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('明亮'),
                            icon: Icon(Icons.light_mode),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('黑暗'),
                            icon: Icon(Icons.dark_mode),
                          ),
                        ],
                        selected: {widget.state.themeMode},
                        onSelectionChanged: (s) =>
                            widget.state.setThemeMode(s.first),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('接入包(v2 自适应连接)',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text('导入管理员下发的接入包(enroll 产出目录),App 会把'
                          '连接配置与证书写入本机固定数据目录,并自动把服务器地址'
                          '设为本地连接端点。连接层(connd/nebula/frpc)由安装服务接管。'),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed:
                            (_saving || _importing) ? null : _importBundle,
                        icon: _importing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download_for_offline),
                        label: const Text('导入接入包…'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (isWizard) ...[
                Text('同步配置',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _dirCtrl,
                      decoration: const InputDecoration(
                        labelText: '共享目录',
                        hintText: '要同步的本地目录(绝对路径)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _pickDir,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('选择…'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _serverCtrl,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'http://192.168.1.10:8418/shared.git',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _clientCtrl,
                decoration: const InputDecoration(
                  labelText: '客户端 ID',
                  hintText: '区分不同电脑,出现在冲突副本文件名中',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              ExpansionTile(
                title: const Text('高级选项'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  TextField(
                    controller: _intervalCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '自动同步间隔(秒)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _stableCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '文件稳定延迟(秒)',
                      helperText: '刚修改不足该时长的文件本轮跳过,避免同步写到一半的文件',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _retriesCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '推送重试次数',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('保存配置'),
              ),
              if (!isWizard) ...[
                const SizedBox(height: 8),
                Text(
                  '保存后将重建同步引擎并立即生效。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
