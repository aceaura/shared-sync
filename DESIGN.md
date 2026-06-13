# shared-sync 工程设计契约

> 本文档是实现的**唯一权威契约**。所有模块必须严格遵守这里定义的 API 签名、数据结构与语义。
> 需求来源:《共享目录客户端需求说明:Git 当前快照分支方案》(见 docs/requirements.md)。

## 0. 工程布局

```text
shared-sync/
  DESIGN.md                  本文档
  README.md                  总览 + 快速开始(中文)
  docs/requirements.md       原始需求文档副本
  server/                    服务端(Docker)
    Dockerfile
    docker-compose.yml
    nginx.conf.template
    entrypoint.sh
    hooks/pre-receive        推送限制钩子
    scripts/compress.sh      历史压缩(手动触发)
    scripts/gc.sh            垃圾回收
    README.md
  client/
    engine/                  纯 Dart 同步引擎 package(name: sync_engine)
      pubspec.yaml
      lib/sync_engine.dart   导出入口
      lib/src/models.dart
      lib/src/config.dart
      lib/src/logger.dart
      lib/src/ignore.dart
      lib/src/index_db.dart
      lib/src/git.dart
      lib/src/scanner.dart
      lib/src/merge.dart
      lib/src/engine.dart
      bin/sync_cli.dart      CLI 入口(阶段一原型 + e2e 测试用)
      test/ignore_test.dart
      test/merge_test.dart
      test/index_db_test.dart
      test/git_test.dart
    app/                     Flutter 桌面应用(name: shared_sync_app, 依赖 engine)
  test/e2e.sh                端到端验收脚本(对照需求 §19)
```

## 1. 核心架构决策

1. **隐藏仓库为 bare repo**(`<sharedDir>/.sync/repo`),git 永远不直接接触用户工作目录。
   所有 git 操作走 plumbing:`hash-object -w` / `update-index`(临时 index 文件)/ `write-tree` / `commit-tree` / `fetch` / `push` / `ls-tree` / `cat-file` / `merge-base`。
2. **不使用 `git merge` 做内容合并**。三方判断(B/L/R)和冲突副本逻辑完全由 `merge.dart` 纯函数实现 —— 需求 §10.1 规定 hash 不同即生成冲突副本,不做文本行级合并。
3. **B(base)来自 index.db,不依赖 git 祖先关系** —— 因此服务端历史压缩(分支重写)后,三方判断天然继续有效;客户端只需检测压缩事件(merge-base 祖先检查失败)并记录日志、走保护性流程。
4. **冲突时远端赢路径,本地内容存为冲突副本**(与 Syncthing/Dropbox 一致,且与需求 §10.2「本地修改,远端删除」规则的方向一致)。冲突副本是普通新文件,参与下一轮同步上传。
5. **index.db 只在整个同步周期成功结束后更新** —— 任何一步崩溃,下个周期以旧 base 重新三方判断即可收敛(幂等)。
6. 客户端依赖系统 `git` CLI(>= 2.30)。文档中说明此前置条件。

## 2. 同步周期算法(engine.dart 的 syncOnce)

```text
1. 获取 .sync/lock(文件锁,防多实例)。
2. git fetch 远端 current(+refspec 强制更新本地镜像 ref)。远端分支不存在 → R = ∅。
3. 历史压缩检测:db.lastSyncedCommit 非空 且 不是远端 head 的祖先(merge-base --is-ancestor 失败)
   → 记录 compressionDetected 事件日志,后续 apply 阶段对所有被覆盖/删除文件强制做 staging 备份(平时也做,此时必做)。
4. 全量扫描本地 → L(TreeState)+ unstable 集合(mtime 距今 < fileStableDelaySeconds 或 scan 期间变化的路径)。
   unstable 路径视为冻结:规划时按 l=b 处理,且不对其执行任何下载/删除动作。
5. B = db.baseTree()。
6. ignoredReconcile = union(B, R) 中命中当前 ignore 规则(isIgnored(p, isDir:false))的路径集合(需求 §12:
   规则新增后已同步文件从 L 消失绝不能被当作本地删除传播;远端新增的本地命中 ignore 的文件也不下载)。
   该集合并入 frozen 集合,经 §3 的 frozen 机制处理:远端原样保留、本地不动、base 不动(见步骤 11)。
   记一条 info 日志(数量 + 示例路径)。L 中不会出现 ignored 路径(scanner 已剪枝)。
7. plan = planSync(base: B, local: L, remote: R, frozen: unstable ∪ ignoredReconcile, namer: conflictNamer)。
8. 写冲突副本到磁盘(从本地文件复制到 copyPath;先于一切覆盖动作)。
9. 若 plan.mergedTree != R:
   a. 对需上传的条目执行 git hash-object -w 写入 blob(写前重新 stat,若文件已变化 → 整轮放弃重来,计入重试)。
   b. 临时 index 构建 mergedTree → write-tree → commit-tree(parent = 远端 head,若远端为空则无 parent;message 含 clientId 与时间)。
   c. push 到 refs/heads/current。被拒(非快进)→ 回到第 2 步整轮重做,最多 maxPushRetries(默认 3)次。
   d. 本阶段抛 GitException 时,先删除本轮已写盘的冲突副本再向上抛(副本内容来自本地文件,无数据损失;下轮重建,避免目录残留重复副本)。
10. Apply 阶段(对工作目录的所有写动作):
   a. 将即将被覆盖或删除的本地文件备份到 .sync/staging/backup-<UTC时间戳>/(保持相对路径)。
   b. 下载:git cat-file blob → 写到 .sync/staging/tmp 下临时文件 → 原子 rename 到目标路径(自动建父目录,按 mode 设置可执行位)。
   c. 覆盖/删除前安全复查:目标路径当前 stat(size+mtime)与扫描时不一致(含「扫描时不存在但现在存在」)→ 跳过该路径、计入 skippedPaths 并记日志「文件在同步期间被修改,顺延到下一轮」(语义:同步点之后的新编辑,下一轮作为新的本地变更处理)。
      下载路径在 cat-file 完成后、rename 之前**再复查一次**(大 blob 写出耗时长,把竞态窗口压缩到 rename 前的微秒级);复查失败删除临时文件、跳过、同样计入 skippedPaths。
      大小写不敏感文件系统上,下载目标与既有路径(扫描所见 ∪ 本轮已下载)仅大小写不同时,该复查必然命中;引擎据 lowercase 映射改记专门告警「大小写不敏感文件系统路径碰撞,文件未同步到本地」。
   d. 删除本地文件;随后自底向上清理因此变空的目录(不越过共享根目录)。
   e. 删除冲突(本地删,远端改)→ 保留远端文件,写一条冲突记录。
11. 冲突记录追加写 .sync/conflicts.jsonl:{"time":ISO8601,"kind":"modify|delete|create","path":...,"copyPath":...|null,"clientId":...}。
12. db.replaceBase(computeBaseToStore(mergedTree(或 R,若无推送), B, unstable ∪ skippedPaths ∪ ignoredReconcile), commit, statCache) + db.setLastSyncedCommit(...)。
    computeBaseToStore(merge.dart 纯函数)把回退集合中的路径还原为 base 原值(b 存在则 b,否则不落库)——
    base 只允许越过本地磁盘实际呈现过的状态,否则下轮会把从未落盘的远端版本误判为「已见过」,造成幻影删除/无副本覆盖。
13. 清理 .sync/staging 中超过 7 天的 backup-*。释放锁,返回 SyncReport。
```

首次运行(B=∅、远端可能为空)无需特判,三方规则自然覆盖:本地有远端无 → 上传;远端有本地无 → 下载;两边同路径不同内容 → 新建冲突(§10.3)。

## 3. 三方判断规则(merge.dart,纯函数,必须按此实现)

对 union(B,L,R) 中每个路径 p,b/l/r 为对应 blob hash(不存在为 null;hash 相等含 mode 相等):

| 条件 | 动作 |
|---|---|
| l==b && r==b | 无变化 |
| l!=b && r==b | 本地赢:merged[p]=l(l 为 null → 从 merged 删除,即上传删除) |
| l==b && r!=b | 远端赢:merged[p]=r;r 非 null → download;r 为 null → localDelete |
| l!=b && r!=b && l==r | 双方一致:merged[p]=l,无动作(仅更新 base) |
| l!=b && r!=b,l==null(本地删,远端改) | merged[p]=r + download(本地不存在,直接写回)+ deleteConflict 记录 |
| l!=b && r!=b,r==null(本地改,远端删) | merged 中无 p(接受删除)+ 本地文件改名为冲突副本 copyPath,merged[copyPath]=l |
| l!=b && r!=b,均非 null 且不同 | merged[p]=r + download(覆盖)+ 冲突副本:merged[copyPath]=l |

frozen 路径:调用方传入前已令 l:=b;planner 还必须保证不对 frozen 路径产生 download/localDelete/conflictCopy 动作。

ignored 路径(需求 §12)同样经 frozen 机制处理:engine 把 union(B,R) 中命中 ignore 规则的路径并入 frozen 集合
(这些路径不在 L 中,scanner 已剪枝,因此无 l:=b 替换;planner 的 frozen 行为对 l 不敏感)。
frozen 语义(merged[p]=r、零动作)+ 步骤 12 的 base 回退恰好实现「被忽略文件不参与同步、冲突判断和删除传播」:
远端原样保留、本地不动、base 不动;规则移除后以未推进的 base 恢复正常三方判断。

冲突副本命名(config.dart 提供 namer):模板 `{name} (conflict from {client} {time}){ext}`,time 格式 `yyyy-MM-dd HH-mm`(本地时区);若目标已存在(磁盘或 merged 中)追加 ` -2`、` -3`…。示例:`report (conflict from PC-A 2026-06-12 15-30).docx`。

## 4. 模块 API 契约(签名必须一致)

### 4.1 models.dart

```dart
enum EntryMode { regular, executable }            // 100644 / 100755

class FileEntry {
  final String path;        // 共享根的相对路径,正斜杠分隔,不以 / 开头
  final String hash;        // git blob sha1(40 hex)
  final EntryMode mode;
  const FileEntry({required this.path, required this.hash, this.mode = EntryMode.regular});
}

typedef TreeState = Map<String, FileEntry>;       // key == FileEntry.path

class CachedStat {                                 // 扫描加速缓存
  final int size; final int mtimeMs; final String hash; final EntryMode mode;
  const CachedStat({required this.size, required this.mtimeMs, required this.hash, required this.mode});
}

class LocalScanResult {
  final TreeState files;
  final Set<String> unstablePaths;
  final Map<String, CachedStat> stats;             // 本次扫描得到的 stat+hash
  const LocalScanResult({required this.files, required this.unstablePaths, required this.stats});
}

class DownloadAction { final String path; final String hash; final EntryMode mode; ... }
class ConflictCopy   { final String originalPath; final String copyPath; final String localHash; final EntryMode mode; ... }
class DeleteConflict { final String path; ... }    // 本地删、远端改 → 保留远端

class SyncPlan {
  final TreeState mergedTree;
  final List<DownloadAction> downloads;
  final List<String> localDeletes;
  final List<ConflictCopy> conflictCopies;
  final List<DeleteConflict> deleteConflicts;
  bool get hasRemoteChanges;                       // mergedTree 是否不同于 remote(需要 push)
  ...
}

class ConflictRecord {                              // conflicts.jsonl 一行
  final DateTime time; final String kind; final String path; final String? copyPath; final String clientId;
  Map<String, dynamic> toJson(); factory ConflictRecord.fromJson(...);
}

enum SyncPhase { idle, scanning, fetching, planning, pushing, applying, error }

class SyncReport {
  final DateTime startedAt; final Duration duration;
  final int uploaded; final int downloaded; final int deletedLocal; final int deletedRemote;
  final List<ConflictRecord> conflicts;
  final bool compressionDetected; final String? pushedCommit; final String? error;
  bool get hasError;
  ...
}
```

### 4.2 config.dart

```dart
class SyncConfig {
  final String sharedDir;                  // 绝对路径
  final String serverUrl;                  // git URL(http(s)://、file:// 或本地路径)
  final String clientId;
  final int syncIntervalSeconds;           // 默认 30
  final int fileStableDelaySeconds;        // 默认 2
  final int maxPushRetries;                // 默认 3
  final String conflictNameTemplate;       // 默认 "{name} (conflict from {client} {time}){ext}"
  final String ignoreFileName;             // 默认 ".syncignore"
  final int logRetentionDays;              // 默认 14;按天日志保留窗口
  const SyncConfig({...});                 // 除 sharedDir/serverUrl/clientId 外均有默认值

  String get syncDir   => p.join(sharedDir, '.sync');
  String get repoDir   => p.join(syncDir, 'repo');
  String get dbPath    => p.join(syncDir, 'index.db');
  String get stagingDir=> p.join(syncDir, 'staging');
  String get logsDir   => p.join(syncDir, 'logs');
  String get conflictsPath => p.join(syncDir, 'conflicts.jsonl');

  Map<String, dynamic> toJson(); factory SyncConfig.fromJson(Map<String, dynamic>);
  static Future<SyncConfig?> load(String sharedDir);   // 读 <sharedDir>/.sync/config.json,无则 null
  Future<void> save();
  String conflictCopyPath(String originalPath, DateTime now, bool Function(String) exists);
      // 实现 §3 命名规则;exists 由调用方提供(检查磁盘+merged)
}
```
`logRetentionDays` 为**可选追加字段**:`fromJson` 缺省回退 14,旧版无该字段的 config.json 可无损加载;`toJson` 现含九个字段。

### 4.3 logger.dart

```dart
enum LogLevel { debug, info, warn, error }
class SyncLogger {
  SyncLogger(String logsDir, {LogLevel minLevel = LogLevel.info, bool alsoConsole = true});
  void log(LogLevel level, String message, [Object? error, StackTrace? st]);
  void debug(String m); void info(String m); void warn(String m); void error(String m, [Object? e, StackTrace? st]);
  Future<List<String>> tail(int lines);          // 读当天日志末尾 N 行(UI 用)
  Future<int> cleanupOldLogs(int retentionDays); // 删除早于 retentionDays 天的 sync-YYYYMMDD.log,返回删除数
  void close();
}
```
按天写 `<logsDir>/sync-YYYYMMDD.log`,行格式 `2026-06-13T10:00:00.000 [INFO] message`。

- **tail 为尾部读取**:用 `RandomAccessFile` 从 EOF 往前按 64KiB 块反向读,累计到 ≥ lines 个换行(多读一行以便丢弃可能被块边界截断的首行)或到文件头为止,再切出最后 N 行——不再 `readAsLines()` 全量入内存,当天日志达几十 MB 时 UI 刷新也无内存尖峰。UTF-8 多字节:拼好的尾部字节整体 `utf8.decode(allowMalformed: true)` 后按 `\n` 切分,未读到文件头时丢弃首段(可能不完整的行);文件以 `\n` 结尾不产末尾空行;行数 ≤ lines 返回全部;文件不存在返回 `const []`。
- **日志保留清理**:`cleanupOldLogs(retentionDays)` 删除 logsDir 下 `sync-YYYYMMDD.log` 中日期早于「今天 − retentionDays 天」的文件(非 `sync-` 前缀、日期解析失败/越界如 `20260231` 的一律跳过,不误删)。引擎每个同步周期末尾(§2 步骤 12,`_cleanupStaging` 之后)调用一次,保留天数取 `SyncConfig.logRetentionDays`(默认 14)。这样长期运行/断网 + 短周期重试不会让按天日志无限累积。

### 4.4 ignore.dart

```dart
class IgnoreMatcher {
  IgnoreMatcher(List<String> patterns);                       // .syncignore 行(含注释/空行,内部过滤)
  static const List<String> defaults = ['.sync/', '.sync-trash/', '.git/', '~\$*', '*.tmp', '*.swp', '*.lock', 'Thumbs.db', '.DS_Store', 'desktop.ini'];
  static Future<IgnoreMatcher> fromSharedDir(String sharedDir, String ignoreFileName); // defaults + 文件内容
  bool isIgnored(String relativePath, {required bool isDir}); // 路径用正斜杠
}
```
gitignore 子集语义:`#` 注释、空行;尾部 `/` 仅匹配目录;含 `/`(非尾部)的模式锚定根;否则匹配任意层级的基名;`*` 不跨 `/`,`?` 单字符,`**` 跨层级;目录被忽略则其下全部忽略。不支持 `!` 取反(文档注明)。

### 4.5 index_db.dart(sqlite3 package)

```dart
class IndexDb {
  static Future<IndexDb> open(String dbPath);
  Future<TreeState> baseTree();                               // deleted=0 的所有行
  Future<Map<String, CachedStat>> statCache();
  String? get lastSyncedCommit;
  Future<void> setLastSyncedCommit(String? commit);
  Future<void> replaceBase(TreeState tree, String? commit, Map<String, CachedStat> stats);
      // 事务内整表替换 + 更新 lastSyncedCommit;stats 缺失的路径 size/mtime 存 0(下轮强制重新 hash)
  Future<String?> getMeta(String key); Future<void> setMeta(String key, String value);
  void close();
}
```
表结构:`entries(path TEXT PRIMARY KEY, content_hash TEXT, size INTEGER, mtime_ms INTEGER, mode INTEGER, last_synced_commit TEXT, deleted INTEGER DEFAULT 0, last_seen_at INTEGER)`;`meta(key TEXT PRIMARY KEY, value TEXT)`。需求 §9.2 的 file_id/git_blob_id 由 content_hash(即 git blob sha1)统一承担。

### 4.6 git.dart(Process.run 包装系统 git)

```dart
class GitException implements Exception { final String message; final String? stderr; ... }

class GitRepo {
  GitRepo({required this.gitDir, required this.remoteUrl, SyncLogger? logger});
  Future<void> ensureInitialized();                 // bare init + remote origin 设置(已存在则校正 url)
  Future<String?> fetchCurrent();                   // fetch +current:refs/remotes/origin/current;返回远端 head sha,分支不存在返回 null
  Future<TreeState> readTree(String commit);        // ls-tree -r -z,解析 mode(100644/100755;120000 symlink 跳过并告警)
  Future<String?> blobHashOfFile(String absPath);   // git hash-object(不写库,scanner 备用)
  Future<String> writeBlob(String absPath);         // git hash-object -w,返回 sha
  Future<String> commitTree(TreeState tree, {required List<String> parents, required String message});
      // GIT_INDEX_FILE=临时文件;git update-index --index-info(stdin 喂 "<mode> <sha>\t<path>");write-tree;commit-tree
  Future<bool> pushCurrent(String commit);          // push origin <sha>:refs/heads/current;非快进拒绝返回 false;其他错误抛 GitException
  Future<bool> isAncestor(String a, String b);      // merge-base --is-ancestor
  Future<void> catBlobToFile(String hash, String destAbsPath);
  Future<String?> resolve(String ref);              // rev-parse,失败 null
}
```
所有命令显式传 `--git-dir`;环境加 `GIT_TERMINAL_PROMPT=0`(认证失败立即报错而非挂起)。

### 4.7 scanner.dart

```dart
class Scanner {
  Scanner({required String sharedDir, required IgnoreMatcher ignore, required int stableDelaySeconds, SyncLogger? logger});
  Future<LocalScanResult> scan(Map<String, CachedStat> statCache);
}
```
- 递归遍历(不跟随符号链接;symlink 记日志跳过),忽略规则在目录层级即剪枝。
- size+mtime 与 statCache 完全一致 → 复用缓存 hash;否则流式计算 git blob sha1:`sha1("blob <size>\0" + content)`(crypto package,分块喂入,不整文件读内存)。
- `mtime 距 now < stableDelaySeconds` 或 hash 计算前后 stat 发生变化 → 加入 unstablePaths(同时仍放入 files,由 engine 冻结处理)。
- Unix 可执行位 → EntryMode.executable(Windows 恒为 regular)。

### 4.8 merge.dart

```dart
SyncPlan planSync({
  required TreeState base, required TreeState local, required TreeState remote,
  required Set<String> frozenPaths,
  required String Function(String originalPath, bool Function(String) exists) conflictNamer,
});

TreeState computeBaseToStore(TreeState merged, TreeState base, Set<String> revertPaths);
    // §2 步骤 12 的落库基线:merged 中 revertPaths(unstable ∪ skippedPaths ∪ ignoredReconcile)
    // 回退为 base 原值(b 不存在则从结果移除)。
```
严格实现 §3 表格。纯函数,不碰 IO —— 单元测试核心目标。

### 4.9 engine.dart

```dart
class SyncEvent { final DateTime time; final String message; final LogLevel level; }

class SyncEngine {
  SyncEngine(SyncConfig config, {SyncLogger? logger, void Function(SyncEvent)? onEvent});
  Future<void> initialize();                  // 建 .sync 结构、repo init、db open、写 lock 检查
  Future<SyncReport> syncOnce();              // §2 算法;永不抛异常,错误进 report.error
  Future<void> startAuto();                   // watcher(debounce 2s)+ 周期 timer;周期内只允许一个 syncOnce,运行中再触发则置 pending
  Future<void> stop();                        // 停 watcher/timer,释放锁,close db
  SyncPhase get phase; SyncReport? get lastReport;
  Stream<SyncReport> get reports;             // 每次 syncOnce 完成后广播(UI 用)
  Future<List<ConflictRecord>> recentConflicts({int limit = 100});   // 读 conflicts.jsonl 末尾
}
```
watcher 用 `watcher` package 的 DirectoryWatcher;事件经 ignore 过滤后才触发 debounce。watcher 仅是触发器,真实变更以扫描为准(需求 §9.1)。锁:`.sync/lock` 写入 pid,启动时若存在且 pid 存活则报错退出,pid 不存活则接管。

### 4.10 bin/sync_cli.dart

```text
用法:
  sync_cli init   --dir <sharedDir> --server <url> --client-id <id> [--interval N]
  sync_cli sync   --dir <sharedDir>           # 单次同步,退出码 0/1;输出 report 摘要
  sync_cli watch  --dir <sharedDir>           # 常驻(watcher+定时),SIGINT 优雅退出
  sync_cli status --dir <sharedDir>           # 打印 config、lastSyncedCommit、最近冲突
```
参数解析用 `args` package。`sync` 模式即 e2e 脚本驱动两个模拟客户端的入口。

### 4.11 pubspec(engine)

```yaml
name: sync_engine
environment: { sdk: ">=3.0.0 <4.0.0" }
dependencies: { path: ^1.9.0, crypto: ^3.0.0, sqlite3: ^2.4.0, watcher: ^1.1.0, args: ^2.4.0 }
dev_dependencies: { test: ^1.25.0, lints: ^4.0.0 }
```

## 5. 服务端契约(server/)

- 镜像:`alpine` + git、nginx、fcgiwrap、spawn-fcgi、git-daemon(提供 http-backend)、apache2-utils。
- 仓库:`/srv/git/shared.git`(volume)。entrypoint 首次初始化:`git init --bare`,`receive.denyNonFastForwards=true`、`receive.denyDeletes=true`、`http.receivepack=true`,安装 pre-receive 钩子。
- pre-receive 钩子:① 存在 `/srv/git/maintenance.lock` → 全部拒绝(维护窗口);② 仅允许 `refs/heads/current`;③ 拒绝删除分支。非快进由 git config 拒绝。
- nginx + fcgiwrap 跑 git-http-backend(GIT_PROJECT_ROOT=/srv/git, GIT_HTTP_EXPORT_ALL=1),容器内 80 端口,compose 映射 `8418:80`。
- 认证:环境变量 `GIT_AUTH_USER`/`GIT_AUTH_PASSWORD` 均非空 → 生成 htpasswd 并开 Basic Auth;否则匿名(局域网模式)。
- `scripts/compress.sh [repo_path]`:创建 maintenance.lock → 记录 old=rev-parse current → `new=$(git commit-tree current^{tree} -m "snapshot <UTC时间>")` → `git update-ref refs/heads/current $new $old`(原子,带旧值校验)→ 把 new 写入 `/srv/git/snapshot-id` → 删 lock → 全程输出日志。压缩后树必须与压缩前一致(脚本内自校验 `git rev-parse new^{tree} == old^{tree}`)。
- `scripts/gc.sh [repo_path] [grace_hours=24]`:`git reflog expire --expire=now --all` + `git -c gc.aggressive*… gc --aggressive --prune="<grace_hours> hours ago"`,输出前后 `du -sh` 仓库体积。
- 服务端日志:钩子和脚本 append 到 `/srv/git/server.log`(push 记录、压缩起止、current 更新、GC 结果、体积变化)。

## 6. Flutter 应用契约(client/app)

- package `shared_sync_app`,`flutter create --platforms=macos,windows,linux` 骨架,依赖 `sync_engine`(path: ../engine)+ `file_selector` + `sqlite3_flutter_libs`。
- 页面(NavigationRail 四项):
  1. **状态**:当前 phase、上次同步时间/结果(SyncReport 摘要)、「立即同步」按钮、自动同步开关、最近事件列表。
  2. **冲突**:recentConflicts 列表(时间/类型/路径/副本路径),提供「在 Finder/资源管理器中显示」。
  3. **设置**:首次启动向导(选目录 file_selector、服务器 URL、客户端 ID 默认主机名)+ 修改后保存 config.json 并重启 engine。
  4. **日志**:logger.tail 显示,可刷新。
- 状态管理用 ChangeNotifier + AnimatedBuilder 即可,不引入额外框架。引擎跑在主 isolate(IO 都是异步,UI 不卡);深色浅色跟随系统。

## 7. e2e 验收脚本契约(test/e2e.sh)

- 用 `dart compile exe` 出 CLI 后,在 `/tmp/shared-sync-e2e/` 下建 `pcA/` `pcB/` 两个共享目录,分别 init(clientId=PC-A/PC-B)。
- 服务端两种模式:`--docker`(默认,docker compose 起本工程 server,URL=http://localhost:8418/shared.git)与 `--local`(file:// 本地 bare 仓库,同样装 pre-receive 钩子与 denyNonFastForwards,无 Docker 环境时用)。
- 断言逐条对照需求 §19(每条 PASS/FAIL 输出,最终汇总,任一 FAIL 退出码 1):
  19.1.1 A 建文件 B 可见;19.1.2 A 改 B 可见;19.1.3 A 删 B 删;19.1.4 目录+子文件结构同步;
  19.2.1 双方改同文件不同内容 → 冲突副本(两份内容都在);19.2.2 A 删、B 离线改 → 恢复后 B 的修改不丢;19.2.3 双方新建同路径不同内容 → 路径冲突副本;19.2.4 冲突副本随后同步到对端;
  19.3.1 压缩后树一致(压缩前后 `git rev-parse current^{tree}` 相等);19.3.2/3 压缩后客户端日志含识别记录且能继续同步;19.3.4 压缩期间 PC 本地未同步文件不丢;19.3.5 GC 后 objects 体积下降或松散对象减少;
  19.4.2/3 push/merge 失败不丢本地文件;19.4.4 服务端树中不含 .sync;
  15.1 维护锁:maintenance.lock 存在时 push 被拒(sync 报错、远端树不变、本地文件完好),删锁后恢复同步(docker 模式锁在容器内 /srv/git/,local 模式在 bare 仓库父目录)。
- 辅助:`sync A`=对 pcA 执行 `sync_cli sync`;断言用文件内容 diff;每步失败打印两侧目录树与日志便于排查。

## 8. 编码规范

- Dart:遵循 `lints` 推荐集;公共 API 写 dartdoc;内部注释只写非显然约束。
- Shell:`set -euo pipefail`;脚本可重复执行(幂等)。
- 所有路径处理:引擎内部统一用正斜杠相对路径,落盘时经 `path` package 转平台分隔符。
- 错误哲学:**宁可放弃本轮同步,绝不静默覆盖/丢失用户数据**(需求核心原则 3/4)。

## 9. 已知限制 / 风险

- **大目录内存随文件数线性增长**:每个同步周期都会重建 base/local/remote/merged 四棵 TreeState(及扫描 stat 缓存),内存占用与共享目录**文件总数**成正比,无上限。引擎在扫描后当 `union(base,local,remote)` 文件数超过 `SyncEngine.largeDirectoryWarnThreshold`(常量,默认 50000)时记一条 warn 日志「共享目录文件数较多(N),每轮全量扫描内存占用随之上升,超大目录(十万级以上)建议拆分或评估专用方案」。这是务实告警而非硬限制——不重写三方合并、不改变同步语义;十万级以上目录建议拆分共享根或评估专用增量方案。
- **日志体积**:按天日志由 `cleanupOldLogs`(默认保留 14 天,见 §4.3)在每周期末尾清理,断网 + 短重试周期下不会无限累积;但单个当天文件在高频同步下仍可能增长到数十 MB——`tail` 已改为尾部读取以避免 UI 读取时的内存尖峰,但完整日志检索/导出仍需注意单文件体积。
