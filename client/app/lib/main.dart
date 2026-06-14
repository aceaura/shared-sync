/// Shared Sync 桌面客户端入口(DESIGN.md §6)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'src/app_state.dart';
import 'src/conflicts_page.dart';
import 'src/connection_page.dart';
import 'src/files_page.dart';
import 'src/home_page.dart';
import 'src/logs_page.dart';
import 'src/settings_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  // 配置加载/引擎初始化异步进行,期间 UI 显示加载圈。
  unawaited(state.load());
  runApp(SharedSyncApp(state: state));
}

/// 应用根 widget:Material 3,深浅色跟随系统。
class SharedSyncApp extends StatelessWidget {
  const SharedSyncApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: 'Shared Sync',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
        ),
        themeMode: state.themeMode,
        home: MainShell(state: state),
      ),
    );
  }
}

/// 主框架:NavigationRail(状态/文件/冲突/连接/设置/日志)+ IndexedStack 保活页面。
class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.state});

  final AppState state;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  // 目的地顺序:状态(0)/文件(1)/冲突(2)/连接(3)/设置(4)/日志(5)。
  // 在「冲突」之后插入「连接」目的地后,设置目的地下移到索引 4。
  static const int _settingsIndex = 4;

  // null = 还没手动选过:已配置默认状态页,未配置落到设置向导。
  int? _index;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        if (!state.initialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final index = _index ?? (state.isConfigured ? 0 : _settingsIndex);
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.sync),
                    label: Text('状态'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.folder),
                    label: Text('文件'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.warning_amber),
                    label: Text('冲突'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.hub),
                    label: Text('连接'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings),
                    label: Text('设置'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.article_outlined),
                    label: Text('日志'),
                  ),
                ],
              ),
              const VerticalDivider(thickness: 1, width: 1),
              Expanded(
                child: IndexedStack(
                  index: index,
                  children: [
                    HomePage(
                      state: state,
                      onGoToSettings: () =>
                          setState(() => _index = _settingsIndex),
                    ),
                    // 未配置时显示占位提示;配置好后才挂载真正的文件浏览页。
                    state.isConfigured
                        ? FilesPage(state: state)
                        : const _FilesPlaceholder(),
                    ConflictsPage(state: state),
                    const ConnectionPage(),
                    SettingsPage(state: state),
                    LogsPage(state: state),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 未配置时「文件」页的占位提示。
class _FilesPlaceholder extends StatelessWidget {
  const _FilesPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off, size: 48),
          SizedBox(height: 12),
          Text('请先在设置中完成配置'),
        ],
      ),
    );
  }
}
