# connd —— shared-sync v2 连接管理 sidecar

`connd` 是 shared-sync v2 的核心新增组件(DESIGN_v2.md §3)。每个节点跑一个,
作为 sidecar 进程负责:

1. **管理 nebula 子进程生命周期**:启动 / 停止 / 重启,传 `-config`。
2. **健康探测**:周期性探测当前到 peer 的连接路径,归类为 `DIRECT`(打洞直连)/
   `RELAY`(中继兜底)/ `DOWN`(不通)。
3. **跑状态机**:实现 DESIGN_v2.md §4 的 `FALLBACK ⇄ DIRECT`,带升级滞后窗口
   `T_up`、降级阈值 `N`、打洞重试周期 `P`(均可配),做防抖(anti-flapping)。
4. **暴露状态**:本地 HTTP 端点 `GET /status` 返回 JSON;`connd status` 子命令打印。

> 关键设计(DESIGN_v2.md §2.1):主备两条路径**共用同一 overlay 虚拟 IP**,
> "切换"只是底层 endpoint 变化,对 shared-sync 同步内核完全透明。connd 不改 v1 任何代码。

## 目录结构

```
v2/connd/
├── go.mod                       module github.com/aceaura/shared-sync/v2/connd
├── connd.example.yaml           示例配置
├── cmd/connd/main.go            CLI:run / status / version
└── internal/
    ├── fsm/                     状态机(纯逻辑,完整可测)—— connd 核心
    ├── prober/                  探测器接口 + Phase0 nebula 占位实现 + Fake(测试/dry-run)
    ├── nebula/                  nebula 子进程监督(Start/Stop/Restart,DryRun)
    ├── config/                  YAML 配置加载与校验
    ├── controller/              控制循环:探测 → 状态机 → 副作用 → 状态快照
    └── statussrv/               本地状态 HTTP 端点
```

## 架构与数据流

```
                ┌────────────── controller(控制循环,每 heartbeat 一拍)──────────────┐
                │                                                                      │
  Prober.Probe ─┼─► Result(DIRECT/RELAY/DOWN, RTT)──► fsm.Machine.Tick ──► Transition │
                │                                          │                  │         │
                │                                          ▼                  ▼         │
   nebula.Manager(子进程监督)                          Snapshot      Switched / 打洞重试 │
                │                                          │                            │
                └──────────────────► controller.Status ◄──┘                            │
                                            │                                          │
                            statussrv(GET /status, JSON)  ◄── connd status(CLI)         │
                └──────────────────────────────────────────────────────────────────────┘
```

- 状态机被刻意做成**纯逻辑**:不读时钟、不起协程、不碰网络;探测结果与时间都由
  controller 注入。因此可被确定性单测(`internal/fsm/fsm_test.go`)。
- controller 用注入的 `now func() time.Time`,测试时换假时钟,无需 sleep。

## 状态机(DESIGN_v2.md §4)

```
              启动
               │  先起备用(中继)保证可达
               ▼
          ┌─────────┐  后台打洞 + 探测(每 P 秒重试)   ┌──────────┐
          │ FALLBACK │ ──── 直连连续健康 ≥ T_up ─────►  │  DIRECT  │
          │ (中继)   │ ◄─── 直连连续失败 N 次 ────────  │ (打洞直连)│
          └─────────┘                                   └──────────┘
```

- **初始状态恒为 `FALLBACK`**:兜底优先(DESIGN_v2.md §2.2),先用中继保证立刻可达,
  后台再尝试打洞。
- **FALLBACK → DIRECT(升级/切回)**:直连健康**连续稳定 ≥ `T_up`**(滞后窗口)才切。
  任何一次不健康都会把连续健康段归零 —— 这是**防抖核心**,避免网络抖动导致频繁来回切。
- **DIRECT → FALLBACK(降级)**:直连心跳**连续失败 `N` 次**立即切回中继(兜底优先于
  性能)。中途任一次健康都会把失败计数清零。
- **FALLBACK 期间每 `P` 秒**触发一次后台打洞重试(`Transition.ShouldRetryPunch`);
  进入/重入 FALLBACK 的第一拍立即重试一次。

切换只换底层 endpoint(由 nebula 的 hostmap 自动选路),**overlay IP 不变**,不需要
重启 nebula,上层最多感知一次瞬断。

## 配置项

YAML(见 `connd.example.yaml`)。时长用 Go duration 字符串(`"25s"`/`"1m"`)。
未提供的字段取内置默认。

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `peerOverlayIP` | (空) | 对端 overlay 虚拟 IP(被探测对象) |
| `relayUnderlayIP` | (空) | relay 公网/underlay IP(Phase1 判定路径是否经中继用) |
| `probePort` | `4242` | overlay 内探测端口(Phase0 占位) |
| `statusAddr` | `127.0.0.1:4243` | 状态 HTTP 端点监听地址(仅回环) |
| `tUp` | `25s` | 升级滞后窗口 `T_up`(建议 20–30s) |
| `n` | `3` | 降级阈值 `N`(连续失败次数,建议 3–5) |
| `p` | `45s` | 打洞重试周期 `P`(建议 30–60s) |
| `heartbeat` | `7s` | 心跳/探测间隔(建议 5–10s) |
| `probeTimeout` | `2s` | 单次探测超时 |
| `nebula.binPath` | `nebula` | nebula 二进制(从 PATH 查找) |
| `nebula.configPath` | (空) | 传给 nebula 的 `-config`(非 DryRun 必填) |
| `nebula.dryRun` | `false` | true 则不真正 exec nebula(无 nebula 环境 / CI 跑通链路) |

非法值(<=0 / 解析失败)在加载与状态机构造时回退到默认。

## status API 格式

`GET http://127.0.0.1:4243/status` → `200`,`Content-Type: application/json`:

```json
{
  "path": "RELAY",
  "state": "FALLBACK",
  "peer": "10.77.0.3",
  "rttMs": 0.45,
  "since": "2026-06-13T17:52:38+08:00",
  "lastSwitch": "2026-06-13T17:52:38+08:00",
  "nebula": "RUNNING",
  "updatedAt": "2026-06-13T17:52:38+08:00"
}
```

| 字段 | 含义 |
| --- | --- |
| `path` | 最近一次探测的路径归类:`DIRECT` / `RELAY` / `DOWN` |
| `state` | 状态机当前状态:`DIRECT` / `FALLBACK` |
| `peer` | 对端 overlay IP |
| `rttMs` | 最近一次探测 RTT(毫秒) |
| `since` | 当前状态自何时起保持(= `lastSwitch`) |
| `lastSwitch` | 上次状态切换时刻 |
| `nebula` | 子进程状态:`RUNNING` / `STOPPED` / `FAILED` / `DISABLED` |
| `updatedAt` | 本快照生成时刻 |

> DESIGN_v2.md 要求的最小字段集 `{path, peer, rttMs, since, lastSwitch}` 全部包含,
> 另附 `state`/`nebula`/`updatedAt` 便于 GUI 连接状态页(DESIGN_v2.md §6)。

另有 `GET /healthz` 返回 `200 ok`。

## CLI 用法

```
connd run    [-config FILE]                  启动控制循环(管 nebula + 状态机 + 状态端点)
connd status [-addr 127.0.0.1:4243] [-json]  查询本地 connd 当前连接状态
connd version                                打印版本
```

- `connd run` 不带 `-config` 时用内置默认 + **nebula DryRun**,可在无 nebula 的机器
  上跑通整条控制链路(用于开发/演示)。
- `connd status` 默认人类可读;`-json` 原样打印 JSON。

构建:

```bash
cd v2/connd
go build -o connd ./cmd/connd
./connd run -config connd.example.yaml
```

## 验证

```bash
cd v2/connd
go build ./...     # 编译全部
go test ./...      # 单测全绿
```

状态机单测(`internal/fsm/fsm_test.go`)用假 Prober + 假时钟驱动,覆盖:
升级需稳定满 `T_up`、边界 `>=`、连续失败 `N` 次降级、失败被健康打断清零、
FALLBACK 每 `P` 秒重试、DIRECT 不重试、完整往返(降级→重试→恢复→切回)、
抖动不触发切换(防抖)、非法配置回退。

## Phase0 现状与 TODO(给 Phase1 集成者)

- **探测器是占位实现**(`internal/prober/nebula.go`):
  - 可达性用 TCP 拨号到 `peerOverlayIP:probePort` 占位;真实应换 overlay 内 ICMP ping
    或 nebula 自带心跳。
  - **direct vs relay 的精确区分尚未实现**:`defaultClassify` 保守地把"可达但未证实
    直连"归为 `RELAY`,避免误升级到 DIRECT。可通过 `NebulaProber.ClassifyHook` 注入
    真实判定。
  - `RelayUp` Phase0 近似为"overlay 可达";Phase1 需独立探测 relay 路径,以区分
    "仅直连断" vs "对端真的下线"(DESIGN_v2.md §5)。
  - TODO 方案:解析 nebula hostmap(向 nebula 进程发 `SIGUSR1` 打印 hostmap / 读 nebula
    stats / 比对 peer underlay endpoint 是否为 relay IP)。
- **路径切换的副作用**(`internal/controller/controller.go` `handleTransition`):
  Phase0 仅记日志。nebula 自身会在 hostmap 中自动选路(direct/relay),overlay IP 不变,
  故无需重启 nebula。Phase1 在 `ShouldRetryPunch` 时可主动促使 nebula 重新 handshake/打洞。
- 状态机本身是**完整可测的纯逻辑**,Phase1 替换探测器实现后无需改动状态机。
```
