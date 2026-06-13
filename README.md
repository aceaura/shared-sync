# shared-sync — 基于 Git 快照分支的共享目录同步系统

个人/小团队用的共享目录同步:每台 PC 装一个客户端,用户只看到一个普通文件夹;客户端把变化自动同步到中心 Git 服务器。Git 只是底层一致性与冲突判断工具,服务端只维护一个 `current` 快照分支,历史可周期性压缩,不会无限膨胀。

需求文档见 [docs/requirements.md](docs/requirements.md),设计契约见 [DESIGN.md](DESIGN.md)。

## 架构总览

```text
+--------------------+         +---------------------------+
| PC-A  Flutter 客户端 | <-----> |  Git Server (Docker)       |
|  普通文件夹 + .sync   |  HTTP   |  shared.git                |
+--------------------+         |  refs/heads/current        |
                               |  pre-receive: 仅快进/仅该分支 |
+--------------------+         |  compress.sh / gc.sh       |
| PC-B  Flutter 客户端 | <-----> |                           |
+--------------------+         +---------------------------+
```

- **服务端**(`server/`):alpine + nginx + git-http-backend 的极简 Git Smart HTTP 服务,bare 仓库,只暴露 `refs/heads/current`;`pre-receive` 钩子禁止其他分支、禁止删除,配置层禁止非快进推送;附历史压缩与 GC 脚本。
- **同步引擎**(`client/engine/`):纯 Dart package。隐藏 bare 仓库放在 `<共享目录>/.sync/repo`,git 从不直接接触用户文件;所有操作走 plumbing(`hash-object` / `commit-tree` / `push` / `cat-file`)。三方判断(B 基线 / L 本地 / R 远端)与冲突副本逻辑由引擎自己实现,**不做文本合并**——内容 hash 不同即生成冲突副本,绝不静默覆盖。
- **桌面应用**(`client/app/`):Flutter(macOS / Windows / Linux),状态、冲突列表、设置向导、日志四个页面;同一引擎也提供 CLI(`sync_cli`),供脚本化使用与端到端验收。

## 下载安装包

桌面客户端的预编译安装包在 [Releases](https://github.com/aceaura/shared-sync/releases) 页面:

- **macOS**:`shared-sync-macos-<版本>.dmg` —— 打开后把应用拖入 Applications。
- **Windows**:`shared-sync-windows-<版本>-setup.exe` —— 双击安装。

> 安装包**未签名**:macOS 首次打开右键图标 →「打开」;Windows SmartScreen 点「更多信息 →仍要运行」。详见 [installer/README.md](installer/README.md)。

## 快速开始

### 1. 启动服务端(任一台机器,需 Docker)

**一键部署(拉取预构建镜像,推荐):**

```bash
curl -fsSL https://raw.githubusercontent.com/aceaura/shared-sync/main/server/install.sh | bash
# 或带认证:GIT_AUTH_USER=user GIT_AUTH_PASSWORD=pass bash <(curl -fsSL .../server/install.sh)
```

**或用 compose 直接拉镜像:**

```bash
curl -fsSLO https://raw.githubusercontent.com/aceaura/shared-sync/main/server/docker-compose.prod.yml
docker compose -f docker-compose.prod.yml up -d
```

**或从源码本地构建:**

```bash
cd server
docker compose up -d --build
# 仓库地址: http://<服务器IP>:8418/shared.git
# 可选认证: 在 docker-compose.yml 里设置 GIT_AUTH_USER / GIT_AUTH_PASSWORD
```

### 2. 客户端(每台 PC)

前置:系统安装 `git`(>= 2.30);桌面应用或 CLI 二选一。

**桌面应用**:

```bash
cd client/app
flutter run -d macos      # 或 windows / linux;打包: flutter build macos
```

首次启动按向导选择共享目录、填服务器地址即可;之后保持应用运行,文件变化自动同步。

**CLI**:

```bash
cd client/engine
dart compile exe bin/sync_cli.dart -o build/sync_cli
./build/sync_cli init  --dir ~/SharedWork --server http://<服务器IP>:8418/shared.git --client-id PC-A
./build/sync_cli sync  --dir ~/SharedWork     # 单次同步
./build/sync_cli watch --dir ~/SharedWork     # 常驻(watcher + 定时)
./build/sync_cli status --dir ~/SharedWork
```

### 3. 历史压缩(服务端维护,手动触发)

```bash
docker compose exec shared-sync-server compress.sh   # 同树新根提交,原子替换 current
docker compose exec shared-sync-server gc.sh         # 宽限期后清理不可达对象(默认 24h)
```

压缩后客户端无需任何操作:下次同步自动识别(日志记录"检测到服务端历史压缩"),基于本地 `index.db` 基线安全重建,本地未同步修改不会丢失。

## 同步与冲突语义(对照需求 §9/§10)

- 三方判断基于 `.sync/index.db` 记录的上次同步基线,`mtime` 只作快速过滤,最终以内容 hash 为准。
- 双方修改同一文件且内容不同 → 远端内容保留在原路径,本地内容存为
  `report (conflict from PC-A 2026-06-12 15-30).docx` 样式的冲突副本,随下一轮同步上传到所有端。
- 本地删 / 远端改 → 保留远端文件,记一条删除冲突;本地改 / 远端删 → 接受删除,本地内容存为冲突副本。
- 删除会传播;被覆盖或删除的本地文件先备份到 `.sync/staging/backup-*/`(保留 7 天)再动手。
- `.syncignore`(gitignore 子集)+ 默认忽略(`.sync/`、`~$*`、`*.tmp`、`.DS_Store` 等)。
- 写入未稳定(默认 2 秒内仍在变化)的文件本轮冻结,下一轮处理,避免同步半写入状态。

## 端到端验收

```bash
test/e2e.sh             # 自动选择: 有 Docker 用 Docker 服务端,否则本地 bare 仓库
test/e2e.sh --docker
test/e2e.sh --local
```

脚本模拟 PC-A / PC-B 双客户端,逐条断言需求 §19 验收标准(基础同步、各类冲突、历史压缩、安全性)。

## 已知限制(对照需求非目标与 MVP 范围)

1. 空目录不同步(Git 树不能表示空目录);目录随其中文件出现。
2. 重命名按"删除 + 新增"处理(需求 §10.4 第一阶段方案)。
3. 不支持 `.syncignore` 的 `!` 取反规则。
4. 符号链接跳过不同步(记日志)。
5. 大文件可同步但无分块/增量传输;频繁修改大型二进制会使仓库增长加快(靠历史压缩 + GC 控制)。
6. 单用户/可信小团队定位,认证仅 HTTP Basic(可选),无细粒度权限。
7. macOS 打包 `.app` 需要完整 Xcode;Windows/Linux 打包需在对应平台执行 `flutter build`。
8. 大小写不敏感文件系统(macOS/Windows 默认)上,远端若同时存在仅大小写不同的两个文件(如 `A.txt` 与 `a.txt`),本地只会落盘其中一个;另一个保留在服务端不丢失,客户端每轮同步记一条「大小写不敏感文件系统路径碰撞,文件未同步到本地」告警,绝不会因此删除任何一侧的文件。

## 开机自启与保活

进程级保活分两端,目标是崩溃/重启电脑后无需人工干预即可恢复同步。

- **服务端**:`server/docker-compose.yml` 已配置 `restart: unless-stopped`,容器崩溃或 Docker 重启后自动拉起(`unless-stopped` 而非 `always`,尊重用户手动 `docker compose stop`)。开机自启还需在 **Docker Desktop 设置里开启「登录时启动(Start Docker Desktop when you log in)」**,否则宿主机重启后 Docker 本身不会起。
- **客户端 GUI**:`client/app/` 桌面应用由用户自己打开,无需额外保活;保持应用运行即可。
- **无人值守客户端**:纯后台/常开机器用 `client/daemon/install-macos.sh <共享目录>` 把 `sync_cli watch` 注册为 macOS launchd 守护进程(登录自启 + 崩溃自动重启)。Windows/Linux 做法见 [client/daemon/README.md](client/daemon/README.md)。

```bash
cd client/daemon
./install-macos.sh ~/SharedWork      # 安装并启动
./uninstall-macos.sh ~/SharedWork    # 卸载(幂等)
```

> ⚠️ **GUI 与守护进程不可管理同一目录**:二者会争抢同一把 `<共享目录>/.sync/lock`,后启动者拿不到锁会失败。同一目录请二选一——有人值守用 GUI,无人值守用 daemon。

## 发布流程

一行触发,GitHub Actions 自动构建并发布(详见 [installer/README.md](installer/README.md)):

```bash
scripts/release.sh 1.0.1
```

推送 `v1.0.1` tag 后,CI 并行产出 macOS `.dmg`、Windows 安装器(附到 Release)、服务端镜像(推 `ghcr.io/aceaura/shared-sync-server`)。push/PR 另有 [CI 工作流](.github/workflows/ci.yml) 跑引擎与应用的 analyze + test。

## 工程结构

```text
server/            Docker 服务端(nginx + git-http-backend + 压缩/GC 脚本)
                   docker-compose.prod.yml + install.sh 为生产一键部署
client/engine/     纯 Dart 同步引擎 + sync_cli(单元/集成测试在 test/)
client/app/        Flutter 桌面应用
client/daemon/     客户端进程保活(macOS launchd 脚本 + 跨平台说明)
installer/         桌面安装器打包(macOS make-dmg.sh / Windows installer.iss)
scripts/release.sh 发布触发脚本(打 tag → CI 自动发布)
.github/workflows/ CI(analyze+test)与 Release(安装器+镜像)流水线
test/e2e.sh        端到端验收脚本(需求 §19)
DESIGN.md          设计契约(模块 API 与算法的权威定义)
docs/requirements.md   原始需求
```
