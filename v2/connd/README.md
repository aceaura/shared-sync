# connd —— shared-sync v2 连接管理 sidecar

`connd` 是 shared-sync v2 的核心新增组件(DESIGN_v2.md §3)。每个节点跑一个,
作为 sidecar 进程负责:

1. **管理 nebula 子进程生命周期**:启动 / 停止 / 重启,传 `-config`。
2. **三层独立健康探测**(DESIGN_v2 §5):查 nebula 控制 sshd `list-hostmap -json`
   判 direct(T0)/relay(T1),叠加 overlay 心跳确认;T2(TCP 兜底)对后端探活。
   产出「各层健康向量」喂状态机。
3. **N 层优先级阶梯状态机**(DESIGN_v2 §4):始终运行在「当前健康的最高优先层」;
   升级需更高层稳定 ≥ `T_up`(滞后防抖);降级则当前层失败 `N` 次后落到下方仍健康
   的最高层;全挂进重连。泛化支持任意层数。
4. **固定本地端点代理**(DESIGN_v2 §2.1):在 `127.0.0.1:8418` 起 TCP 代理,把连接
   转发到「当前激活层」的数据中心后端。切层 = **原子切换上游目标**;引擎只连这个
   固定端点,对走哪层零感知。
5. **暴露状态**:本地 HTTP `GET /status` 返回 JSON;`connd status` 子命令打印。

> 关键设计(DESIGN_v2 §2.1):shared-sync 引擎 `server_url=http://127.0.0.1:8418/shared.git`
> **永不变**。connd 切层只换本地端点上游;切换瞬间最多一次 TCP 重置,引擎每周期幂等+
> 重试,不丢数据,**v1 同步内核一行不改**。

## 目录结构

```
v2/connd/
├── go.mod                       module github.com/aceaura/shared-sync/v2/connd
├── connd.example.yaml           示例配置(Phase2)
├── cmd/connd/main.go            CLI:run / status / version + 三层 wire
├── integration/                 真机集成验证(Linux 容器跑 connd+真 nebula→真 lighthouse)
└── internal/
    ├── ladder/                  N 层优先级阶梯状态机(纯逻辑,完整可测)—— 核心
    ├── tierprobe/               三层探测器(hostmap 判定 + 心跳 + T2 探活)+ Classify 纯逻辑
    ├── nebula/                  nebula 子进程监督 + 控制 sshd 客户端 + hostmap 解析
    ├── proxy/                   固定本地端点 TCP 代理(原子切上游)
    ├── config/                  YAML 配置加载与校验
    ├── controller/              控制循环:探测 → 状态机 → 切代理上游 → 状态快照
    └── statussrv/               本地状态 HTTP 端点
```

## 架构与数据流

```
              ┌──────────── controller(控制循环,每 heartbeat 一拍)─────────────┐
              │                                                                  │
 tierprobe.ProbeTiers ─► []TierState(各层健康向量)─► ladder.Machine.Tick ─► Transition
   │  hostmap+心跳+T2                                       │                 │     │
   ▼                                                        ▼                 ▼     │
 nebula 控制 sshd                                       Snapshot       Switched→切代理上游
 (list-hostmap -json)                                      │                       │
              │                                            ▼                       │
 nebula.Manager(子进程)        proxy.SetUpstream(当前层后端)  ◄───────────────────┘
              │                       │
              │            proxy 127.0.0.1:8418 ──► 当前层数据中心后端(T0/T1 overlay / T2 frpc)
              │                       ▲
              └──────► controller.Status ──► statussrv(GET /status)◄── connd status(CLI)
```

- **状态机(ladder)是纯逻辑**:不读时钟、不起协程、不碰网络;健康向量与时间都由
  controller 注入。故可确定性单测(`internal/ladder/ladder_test.go`)。
- **探测判定核心(tierprobe.Classify)也是纯逻辑**:由 hostmap 判定 + 心跳 + T2 探活
  推出健康向量,无网络,完全可测。取数据(ssh/拨号)经接口注入。

## 三层阶梯(DESIGN_v2 §4)

```
  层  名称              传输            经 VPS?   判定
  ──────────────────────────────────────────────────────────────────────
  T0  DIRECT           Nebula UDP 直连  否        hostmap currentRemote 非空且非 lighthouse + 心跳通
  T1  UDP_RELAY        Nebula UDP 中继  是        currentRemote 空/=lighthouse,但心跳通
  T2  TCP_RELAY        frp 式 TCP 隧道  是        对 T2 后端(frpc 本地口)TCP 探活(Phase3 接入)
```

- 索引 0 = 最优(T0);启动落在最低优先层(T2;T2 未接入时实际落到首个健康层)。
- **升级**:更高层连续健康 ≥ `T_up` 才切上去(滞后,防抖)。
- **降级**:当前层连续失败 `N` 次 → 落到下方仍健康的最高层(兜底优先于性能)。
- **全挂**:所有层不健康 → `RECONNECTING`,代理拒新连接(让引擎本轮重试,不空切)。
- 切层 = `proxy.SetUpstream(新层后端)`;新连接走新上游,旧连接自然结束。

### direct vs relay 判定(Phase1b handoff,DESIGN_v2 §5)

权威判据是 nebula 控制 sshd `list-hostmap -json` 的 **`currentRemote`**:
- 非空且 ≠ lighthouse underlay → DIRECT(T0)。
- 空(仅 `currentRelaysToMe`)→ RELAY(T1)。

陷阱(已在解析/分类中处理):
- `currentRelaysToMe` 非空 ≠ 走中继(direct 收敛后仍保留备用 relay 登记)——**一律以
  `currentRemote` 为准**(`internal/nebula/hostmap.go`)。
- hostmap 降级有 ~10-15s 滞后 → **叠加 overlay 心跳**作权威健康兜底:心跳不通则 T0/T1
  都判 DOWN,即使 hostmap 仍报 direct(`internal/tierprobe/Classify`)。
- 升级(relay→direct)由包计数驱动 `try_promote`:overlay 心跳本身产生流量驱动 promote。

## 配置项

YAML(见 `connd.example.yaml`)。时长用 Go duration 字符串。未提供取默认。

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `peerOverlayIP` | (空) | 数据中心 overlay IP(被探测/连接对象) |
| `dataCenterPort` | `8418` | 数据中心服务端口(T0/T1 上游 + 心跳目标) |
| `lighthouseUnderlay` | (空) | lighthouse underlay(host[:port]),排除 currentRemote=lighthouse |
| `localProxyAddr` | `127.0.0.1:8418` | 固定本地端点(引擎连它) |
| `t2BackendAddr` | (空) | T2 上游 = 本地 frpc 转发口(Phase3;空=T2 不接入) |
| `control.enabled` | `false` | 是否查 hostmap 判 direct(关则仅靠心跳,保守 T1) |
| `control.host/port/user/keyPath` | `127.0.0.1`/`2222`/`ctl`/(空) | nebula 控制 sshd 连接参数 |
| `statusAddr` | `127.0.0.1:4243` | 状态 HTTP 监听(仅回环) |
| `tUp` | `25s` | 升级滞后窗口 `T_up` |
| `n` | `3` | 降级阈值 `N` |
| `p` | `45s` | 上层探测/重试周期 `P` |
| `heartbeat` | `7s` | 心跳/探测间隔 |
| `probeTimeout` | `2s` | 单次探测超时 |
| `nebula.binPath/configPath/dryRun` | `nebula`/(空)/`false` | nebula 子进程 |

## status API 格式

`GET http://127.0.0.1:4243/status` → `200`,JSON:

```json
{
  "tier": "T0",
  "viaVps": false,
  "peer": "10.77.0.1",
  "upstream": "10.77.0.1:8418",
  "localEndpoint": "127.0.0.1:8418",
  "rttMs": 0.45,
  "currentRemote": "54.198.93.78:4242",
  "since": "2026-06-14T04:59:15Z",
  "lastSwitch": "2026-06-14T04:59:15Z",
  "tiersHealth": { "T0": "UP", "T1": "UP", "T2": "DOWN" },
  "reconnecting": false,
  "nebula": "RUNNING",
  "updatedAt": "2026-06-14T04:59:15Z",
  "path": "DIRECT",
  "state": "T0"
}
```

字段:`tier`(当前层 T0/T1/T2/RECONNECTING)、`viaVps`(是否经 VPS)、`peer`(数据中心
overlay IP)、`upstream`(代理当前上游)、`localEndpoint`(固定端点)、`rttMs`、
`currentRemote`(hostmap underlay 端点)、`since`/`lastSwitch`、`tiersHealth`(各层健康)、
`reconnecting`、`nebula`。`path`/`state` 为兼容旧 GUI 的别名。另有 `GET /healthz`。

## CLI 用法

```
connd run    [-config FILE]                  启动控制循环(管 nebula + 三层状态机 + 代理 + 状态端点)
connd status [-addr 127.0.0.1:4243] [-json]  查询本地 connd 当前连接状态
connd version                                打印版本
```

不带 `-config` 时用内置默认 + nebula DryRun,可在无 nebula 的机器上跑通控制链路。

构建:`cd v2/connd && go build -o connd ./cmd/connd`。

## 验证

```bash
cd v2/connd
go build ./...     # 编译全部
go test ./...      # 单测全绿(61 个测试函数)
```

- `internal/ladder`:三层各健康组合选层、升级滞后、降级落到正确层、抖动防切、全挂重连、
  上层重试节拍、泛化到 2/4 层、非法配置回退。
- `internal/tierprobe`:Classify(direct/relay/unknown/全挂/T2)+ 探测器 wire。
- `internal/nebula`:hostmap 解析(direct/relay/陷阱:stale relay 登记/peer 缺席/坏 JSON)。
- `internal/proxy`:转发、原子切上游、无上游拒连、切上游不影响旧连接。
- `internal/controller`:快照字段、升级到 T0、重连清上游、Run 收尾。

### 真机集成验证(`integration/`)

`integration/run-integration.sh` 在本机用 Docker 跑 Linux 容器(`--cap-add NET_ADMIN
--device /dev/net/tun`),容器里 connd 管理**真 nebula** 连**真 lighthouse**(54.198.93.78),
起本地代理,对数据中心(Phase2 以 lighthouse 节点 `10.77.0.1:8418` 上的 git server 充当)
做实跑。详见 `integration/README.md`。

**2026-06-14 实测(本机 Docker Desktop linux/arm64 → 真 AWS lighthouse)**:

```text
PASS: connd 起的 nebula overlay = 10.77.0.2
PASS: overlay 内 ping 数据中心 10.77.0.1 通
PASS: connd status 当前层为 T0(currentRemote=54.198.93.78:4242, viaVps=false, tiersHealth T0/T1 UP)
PASS: git ls-remote http://127.0.0.1:8418/shared.git 经本地端点成功(HEAD + refs/heads/current)
另:把 lighthouseUnderlay 设为 54.198.93.78 → 同一链路判为 T1(viaVps=true),本地端点 git ls-remote 仍通。
```

## 给 Phase3 的接口(T2 接入点)

- **代理 T2 上游** = `config.T2BackendAddr`(本地 frpc 的 local-forward 端口)。Phase3 把
  数据中心经 VPS frps 反向隧道暴露后,填这个本地端口即可,controller 的 `upstreamOf(TierTCPRelay)`
  自动返回它。
- **T2 健康探测接口** = `tierprobe.Heartbeat`(`Beat(ctx) (reachable, rtt)`)。Phase3 注入
  一个对 `T2BackendAddr` 做 TCP/HTTP 探活的实现(`tierprobe.NewTCPHeartbeat(addr, timeout)`
  已可直接用),`tierprobe.Options.T2Probe` 接上即并入阶梯,T2 即可被升降级调度。
