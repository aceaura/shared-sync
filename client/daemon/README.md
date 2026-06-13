# client/daemon — 客户端进程保活

把同步客户端 `sync_cli watch` 注册为系统级常驻服务,实现:

- **登录自启**:开机/登录后自动拉起,无需人工启动。
- **崩溃自愈**:进程崩溃、被 `kill`、异常退出后自动重启(带节流,防崩溃风暴)。

> 适用对象:**无人值守 / 纯后台机器**(例如一台常开的同步中转机)。
> 桌面交互场景请直接用 GUI 应用(`client/app/`),它由用户自己开,无需保活。

## ⚠️ 与 GUI 应用互斥(关键)

同一个共享目录**绝不能同时被 GUI 应用和守护进程管理**。

引擎初始化时会独占 `<共享目录>/.sync/lock`。GUI 与守护进程会争抢同一把锁,
**后启动的一方拿不到锁会直接失败**。请二选一:

| 场景 | 用什么 |
| --- | --- |
| 有人登录、看得到桌面 | GUI 应用(`client/app/`) |
| 无人值守 / 纯后台机器 | 本目录的 launchd 守护进程 |

## macOS:launchd LaunchAgent

### 前置

1. 该目录已初始化(存在 `<dir>/.sync/config.json`):

   ```bash
   sync_cli init --dir ~/SharedWork --server http://<服务器IP>:8418/shared.git --client-id PC-A
   ```

2. 已编译 `sync_cli`(脚本优先在 `client/engine/build/sync_cli` 查找,
   其次在 `PATH` 中查找):

   ```bash
   cd client/engine
   dart compile exe bin/sync_cli.dart -o build/sync_cli
   ```

### 安装

```bash
cd client/daemon
./install-macos.sh ~/SharedWork
```

脚本会:校验目录已 init → 定位 `sync_cli` → 由目录路径生成稳定 `Label`
（`com.sharedsync.client.<目录名slug>-<路径hash8>`,支持多目录各装一份）→
渲染模板写入 `~/Library/LaunchAgents/<Label>.plist` → `launchctl load -w` 加载。

日志默认写到 `<共享目录>/.sync/logs/launchd.out.log` 与 `launchd.err.log`。

### 查看状态 / 日志

```bash
launchctl list | grep com.sharedsync.client
tail -f ~/SharedWork/.sync/logs/launchd.out.log
```

### 卸载

```bash
cd client/daemon
./uninstall-macos.sh ~/SharedWork
```

幂等:目录或 plist 已不存在也会正常退出。

### 多目录

对每个共享目录各跑一次 `install-macos.sh <dir>`;不同目录生成不同 `Label`,
互不影响,各自独立保活。

## Windows:用任务计划程序 / NSSM 自启

本仓库未提供 Windows 脚本,推荐以下两种方式之一把 `sync_cli.exe watch` 注册为开机自启。
注意同样的**互斥原则**:不要让该服务和 GUI 应用管同一个目录。

### 方式 A:任务计划程序(Task Scheduler,系统自带)

1. 编译出 `sync_cli.exe`(在 Windows 上 `dart compile exe bin\sync_cli.dart -o build\sync_cli.exe`)。
2. 打开「任务计划程序」→「创建任务」(不是「基本任务」,以便配置重启)。
3. 常规:勾选「不管用户是否登录都要运行」「使用最高权限运行」。
4. 触发器:新建,「开始任务:登录时」或「计算机启动时」。
5. 操作:新建,程序填 `sync_cli.exe` 绝对路径,参数填
   `watch --dir "C:\Path\To\SharedWork"`,起始位置填该目录或 exe 所在目录。
6. 设置:勾选「如果任务失败,按以下频率重新启动」(例如每 1 分钟、最多 3 次),
   并取消「如果任务运行时间超过…则停止」,实现近似保活。

### 方式 B:NSSM(把进程包成 Windows 服务,保活更可靠)

NSSM(the Non-Sucking Service Manager)能在进程退出时自动重启,更接近 launchd 的语义。

```powershell
# 下载 nssm.exe 后(https://nssm.cc):
nssm install SharedSyncClient "C:\Path\To\sync_cli.exe" watch --dir "C:\Path\To\SharedWork"
nssm set SharedSyncClient AppStdout "C:\Path\To\SharedWork\.sync\logs\service.out.log"
nssm set SharedSyncClient AppStderr "C:\Path\To\SharedWork\.sync\logs\service.err.log"
nssm set SharedSyncClient Start SERVICE_AUTO_START      # 开机自启
nssm start SharedSyncClient
# 卸载: nssm stop SharedSyncClient && nssm remove SharedSyncClient confirm
```

NSSM 默认在服务退出后自动重启(可用 `nssm set ... AppRestartDelay <ms>` 调节节流),
等价于本目录 macOS 方案里的 `KeepAlive` + `ThrottleInterval`。

## Linux

可参照 systemd user/system service 自行编写(`ExecStart=<sync_cli> watch --dir <dir>`,
`Restart=always` + `RestartSec=10`)。本仓库暂未附脚本。
