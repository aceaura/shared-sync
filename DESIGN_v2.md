# shared-sync v2.0 设计:自适应连接层(打洞优先 / 虚拟组网兜底)

> v1.0.0 已发布(github.com/aceaura/shared-sync,tag v1.0.0)。v2.0 在 `develop` 分支开发。
> 本文档定架构与状态机;具体技术栈见末尾「待定决策」,定了再进入实现。

## 1. 目标(来自需求)

不把同步服务器放公网。实际部署是**星型拓扑**(家↔公司只是其中一个例子,不是限定):

```text
1 个 VPS 公网中转中心   ——  只做打洞协调(rendezvous)+ 中继兜底(relay),不存任何数据
1 个同步数据中心        ——  唯一跑 shared-sync 服务端(git 权威 current 分支)的私网节点
N 个同步客户端          ——  各跑 shared-sync 引擎,都只与「数据中心」同步
```

要点:

1. **只有「客户端 ↔ 数据中心」一种连接**,客户端之间互不通信 —— 因此**不需要 N×N 打洞**,只需 N 条「客户端→数据中心」隧道。这把连接问题大幅简化。
2. 每条「客户端↔数据中心」隧道独立地:**主路径** VPS 协助 UDP 打洞建直连 P2P(VPS 只牵线不转发);**备用路径** 打不通(对称 NAT/CGNAT)时经 VPS relay 中继兜底;**自动切回** 打洞恢复后切回直连。
3. **数据中心是唯一权威**(沿用 v1:服务端 current 分支),数据只落在数据中心这个私网节点,绝不落公网 VPS。
4. **可水平扩展**:新增客户端 = 发一张证书 + 指向 lighthouse 的配置,自动找到数据中心接入,无需改动其他节点。

## 2. 核心设计原则

### 2.1 connd 固定本地端点,三层切换对上层透明(关键)

三条路径用的传输与地址各不相同(方案2 是 Nebula overlay IP;TCP 兜底是 VPS 隧道地址),无法靠"同一个 overlay IP"统一。改用更强的抽象:

> **connd 在每个客户端暴露一个固定的本地端点**(如 `127.0.0.1:8418`),把它转发到「当前激活层」对应的数据中心后端。

- shared-sync 引擎的 `server_url` 填这个固定本地端点(`http://127.0.0.1:8418/shared.git`),**永远不变,引擎对底层走哪一层零感知**。
- connd 切层时只是把这个本地端点的上游从一条路径换到另一条;切换瞬间最多一次 TCP 连接重置,而引擎每个同步周期本就是**幂等 + 失败重试**(v1 核心安全设计),一次抖动只意味着某轮重试,**不丢数据、v1 同步内核一行不改**。
- 这个本地代理抽象天然支持任意多层、任意异构传输(UDP overlay / TCP 隧道都行)。

### 2.2 兜底优先,逐级升级

启动顺序:**先用最可达的低层(TCP 隧道)保证立刻可用,再后台逐级向上探测(UDP 中继 → 直连),哪层稳定就升上去**。好处:连接全程不中断,任何网络环境都先连上,再尽量优化到直连的低延迟/高带宽/不过 VPS。

## 3. 架构(星型)

```text
                       公网 VPS 中转中心(无数据)
                  ┌──────────────────────────────┐
                  │  rendezvous(打洞协调,极小流量)│
                  │  relay(中继兜底,只转发加密包)  │
                  └───────▲──────────▲──────────▲──┘
        打洞协调 / 兜底中继 │          │          │
        ┌──────────────────┘          │          └──────────────────┐
        │                             │                             │
 ┌──────┴───────┐            ┌────────┴────────┐            ┌────────┴───────┐
 │  客户端 1     │            │   客户端 2 …N    │            │   数据中心        │
 │ sync 引擎+connd│            │  sync 引擎+connd │            │ shared-sync 服务端 │
 │ overlay .11   │            │  overlay .12…   │            │ +connd  overlay .2 │
 └──────┬────────┘            └────────┬────────┘            └────────▲───────┘
        │  server_url=http://10.77.0.2:8418   每条隧道独立:           │
        └──── 直连 P2P(打洞 OK)/ 经 VPS relay(打不通)──────────────────┘
              （客户端之间不通信;全部指向数据中心 overlay IP）
```

- **VPS 中转中心**:`rendezvous`(信令/打洞协调,极小流量)+ `relay`(中继兜底,仅打不通时承载加密流量,**读不到明文**)。一台即可服务全网;relay 压力随"落到中继的隧道数"上升,故直连打洞成功率直接决定 VPS 带宽消耗。
- **数据中心**:唯一跑 shared-sync 服务端(v1 那套)的私网节点,持有权威 current 分支。在每条路径上都有确定的可达后端(Nebula overlay `10.77.0.2:8418` / TCP 隧道经 VPS 转发)。
- **客户端(N 个)**:各跑 shared-sync 引擎 + connd,引擎只连本地固定端点 `127.0.0.1:8418`(见 §2.1)。
- **connd(连接管理器)**:每个节点一个。管理三层路径、暴露本地代理端点、跑分层状态机、健康探测、逐级升降、暴露连接状态。
- **VPS 三个角色**:`rendezvous`(打洞协调)+ `UDP relay`(Nebula 中继)+ `TCP relay`(frp 式反向隧道接入点)。数据中心对 TCP relay 保持一条出站反向隧道,使其在 NAT 后仍可被客户端经 VPS 抵达。
- **shared-sync 引擎/GUI**:基本不动,只新增"连接状态"展示(当前层 + 是否过 VPS)。

> 与 v1 的关系:数据中心 = v1 服务端,客户端 = v1 客户端,`server_url` 改成 connd 本地端点即可。v2 只在"网络可达性"层加自适应连接,**v1 同步语义与代码完全复用**。

## 4. 三层路径阶梯与状态机(connd 的核心)

三条路径按优先级排成阶梯(数字越小越优:更快、更省 VPS、更私密):

```text
  层  名称(对应用户方案)          传输          经过 VPS?     备注
  ─────────────────────────────────────────────────────────────────────
  T0  DIRECT(方案2)              Nebula UDP 直连  否(P2P)     最快;打洞成功才有
  T1  UDP_RELAY(方案1·UDP)       Nebula UDP 中继  是(转发)     UDP 通但打不通直连时
  T2  TCP_RELAY(方案1·TCP 兜底)  frp 式 TCP 隧道  是(转发)     UDP 被封死时的终极兜底
```

**调度原则:始终运行在「当前健康的最高优先层」。**

```text
            启动
             │  立刻起 T2(最可达)保证可用
             ▼
   ┌──────────────────────────── 持续并行探测各层健康 ────────────────────────────┐
   │                                                                              │
 ┌────┐   更高层稳定≥T_up   ┌──────────┐   更高层稳定≥T_up   ┌────┐
 │ T2 │ ─────────升级──────► │    T1    │ ─────────升级──────► │ T0 │
 │TCP │ ◄────────降级─────── │ UDP中继  │ ◄────────降级─────── │直连│
 └────┘   本层失败N次,落到   └──────────┘   本层失败N次,落到   └────┘
          下方仍健康的最高层                  下方仍健康的最高层
```

- **升级(切到更优层)**:后台持续探测更高层;某更高层健康**连续稳定 ≥ `T_up`(滞后窗口)**才切上去 —— 防抖动频繁切(flapping)。对应"方案2 恢复则切回方案2"。
- **降级(掉到更次层)**:当前层连续失败 `N` 次 → 立即切到**下方仍健康的最高层**(兜底优先于性能),后台继续探测上层伺机回升。
- 切层 = connd 把本地代理端点的上游换到目标层后端;上层最多一次瞬断。
- 一般化:阶梯可配置增减层数;状态机以"层健康向量 + 优先级 + 滞后"驱动,不写死三层。

参数(可配):`T_up`(升级滞后,建议 20–30s)、`N`(降级阈值,建议 3–5 次)、`P`(上层探测周期,建议 30–60s)、心跳间隔(建议 5–10s)。

## 5. 健康探测(每层独立)

- **T0/T1(Nebula)**:经 nebula **控制 sshd** 跑 `list-hostmap -json`,解析对端条目的 `currentRemote` 判定:非空且 ≠ lighthouse 地址 → 直连(T0);为空(仅 `currentRelaysToMe`)→ 经 relay(T1)。**权威字段是 `currentRemote`**;`currentRelaysToMe` 非空可能只是备用中继登记,不代表数据走中继。并在 overlay 内对数据中心做轻量心跳量 RTT/丢包(hostmap 降级有 ~10-15s 滞后,须叠加心跳确认)。Phase1b 实测细节与陷阱见 `v2/sim-vps/README.md`。
- **T2(TCP 隧道)**:对本地代理→VPS→数据中心做 TCP 探活(如 HTTP HEAD `/info/refs` 或 TCP 连通)。
- **区分"路径断"与"对端真下线"**:多层同时探测;若所有层都不通,则是数据中心离线/VPS 故障,connd 进入重连等待,而非在死路径间空切。
- relay 容量意识:T0 直连成功率越高,落到 T1/T2 的隧道越少,VPS 带宽越省。connd 上报各客户端所在层,便于运维观测 VPS 压力。

## 6. 与 v1 的集成边界

- 引擎**不改同步算法**;只把 `server_url` 指向 connd 本地端点 `http://127.0.0.1:8418/shared.git`。
- GUI 新增「连接」页/状态条:当前层(T0 直连 / T1 UDP 中继 / T2 TCP 兜底 / 重连中)、是否过 VPS、对端、RTT、上次切层时间。
- connd 与 sync_cli/GUI 可同机共存(connd 管网络,引擎管同步,互不抢锁)。

## 7. 规模化(N 客户端)

- **数据中心固定身份**:overlay IP `10.77.0.2`,所有客户端 connd 都把本地端点上游指向它(经各自当前层)。新增/替换客户端不影响数据中心与其他客户端。
- **接入 = 发证 + 配置**:每个客户端一张 CA 签发的 Nebula 证书 + 指向 lighthouse 的配置。需要可扩展的签发流程(`gen-certs.sh` 支持任意节点名 / 后续可做"申请-签发"接入服务),类比 v1 的 `client/daemon` 安装器。
- **VPS 容量**:一台 VPS 即可服务全网;真实带宽压力来自落到 T1/T2 的隧道。直连(T0)成功率越高越省 VPS。必要时可加多台 relay/lighthouse 水平扩展。
- **数据中心放置**:它是全网唯一服务端,建议放在直连打洞友好(非对称 NAT)的网络,以提高各客户端 T0 命中率、降低 VPS 负担。

## 8. 安全

- overlay 全程加密(Nebula 证书 + Noise 协议)。
- T1/T2 中继兜底时,VPS **只转发加密流量,读不到 git 明文**(端到端密钥不在 VPS);TCP 兜底层同样在隧道内承载 overlay 加密流量。
- rendezvous 仅交换公网映射等元数据,不碰业务数据。
- VPS 叠加防火墙 + 证书签发控制谁能入网(数据中心防火墙只放行 overlay 内 tcp 8418)。

## 9. 已定方案(2026-06-14)

1. **拓扑**:星型 —— 1 VPS 中转中心 + N 客户端 + 1 数据中心(§1/§3)。
2. **技术栈**:Nebula(T0 直连 + T1 UDP 中继)+ frp 式 TCP 隧道(T2 兜底)+ Go sidecar connd(管理与切换)。
3. **失败切换**:三层阶梯,优先 T0,逐级兜底,上层恢复即升级回去(§4)。
4. **透明集成**:connd 本地固定端点,v1 同步内核不改(§2.1/§6)。

## 10. 路线图

- ✅ Phase0:Nebula 配置骨架 + connd 状态机骨架 + 双 NAT 模拟(relay 链路 + shared-sync over overlay 跑通;Docker Desktop 下 direct 打洞未收敛)。
- ✅ Phase1a:真 VPS 部署 lighthouse+relay;真机验证 Mac 穿 NAT 接入、overlay 连通、shared-sync over overlay、不暴露公网。
- ✅ Phase1b:VPS netns 可控双 NAT 验证 **T0 直连打洞**(real Linux full-cone NAT 下直连稳定收敛;降级 relay / 切回 direct 全过;脚本沉淀 `v2/sim-vps/`)。判定法:nebula 控制 sshd `list-hostmap -json` 的 `currentRemote`(见 §5 / `v2/sim-vps/README.md`)。
- ✅ Phase2:connd 接真 Nebula(控制 sshd `list-hostmap -json` 探测 T0/T1 + overlay 心跳兜底)+ 固定本地端点 TCP 代理(原子切上游)+ N 层优先级阶梯状态机(`internal/ladder`,泛化任意层数,升级滞后/N 次降级/全挂重连)。真机集成:本机 Docker 容器跑 connd+真 nebula 连真 lighthouse,status 显示 tier=T0(currentRemote=54.198.93.78:4242)/ 改 lighthouseUnderlay 后显示 T1,本地端点 `127.0.0.1:8418` git ls-remote 通(`v2/connd/integration/`)。go test 61 测试全绿。
- ✅ Phase3:T2 终极兜底层(frp **STCP** TCP 隧道)+ 并入阶梯,**完整三层阶梯端到端验证**(`v2/frp/`)。
  - **架构**:VPS 跑 frps(systemd,bindPort 7000,与 nebula-lighthouse/ss-server 共存,STCP 不在 VPS 开 remotePort);数据中心 frpc 以 STCP **服务端**把本地 git 注册给中继(不暴露公网);客户端 frpc 以 STCP **visitor** 在本地 `127.0.0.1:18418` 暴露——**这个本地口即 connd 的 `t2BackendAddr`**。`secretKey` 端到端(visitor↔数据中心),frps 读不到 git 明文。connd 侧零逻辑改动:`upstreamOf(TierTCPRelay)` 返回 `t2BackendAddr`,`tierprobe.NewTCPHeartbeat` 探活,阶梯自动纳管 T2。frpc 作 sidecar 常驻(connd 也可托管,接口已留)。
  - **修了 connd 一个并发探测 bug**:`tierprobe.ProbeTiers` 原先串行探测三层,共用一个 `probeTimeout`;UDP 封死时 overlay 心跳的 TCP 拨号阻塞到超时、耗尽预算,导致随后的 T2 探测在已超时的 ctx 上瞬间失败 → 误判 T2 DOWN → 该降级 T2 时却进了 RECONNECTING。改为**三层并发探测**(各层独立,慢的不拖累别层),加回归测试 `TestProbeTiersSlowOverlayDoesNotStarveT2`。`go build`+`go vet`+`go test ./...` 全绿(62 测试函数)。
  - **端到端三态实测**(本机两容器=数据中心+客户端,**都真连真 VPS** lighthouse+frps;`v2/frp/run-e2e.sh`,`PASS=8 FAIL=0`,2026-06-14):

    ```text
    态1 正常态     tier=T1  viaVps=true  upstream=10.77.0.3:80    tiersHealth T0/T1/T2=UP   git ls-remote ⇒ ca0f2a1 HEAD / refs/heads/current ✓
    态2 封死UDP    tier=T2  viaVps=true  upstream=127.0.0.1:18418 tiersHealth T0=DOWN T1=DOWN T2=UP  git ls-remote(经同一本地端点 127.0.0.1:8418,走 frp TCP 隧道)⇒ ca0f2a1 HEAD / refs/heads/current ✓;同时 ping 10.77.0.3 失败(overlay 直达确已断)——T2 兜底核心证明
    态3 恢复UDP    tier=T0  viaVps=false upstream=10.77.0.3:80    tiersHealth T0/T1/T2=UP   git ls-remote ⇒ ca0f2a1 HEAD / refs/heads/current ✓(滞后窗口后一路升回直连)
    ```

    引擎(git 客户端)全程只连固定本地端点 `http://127.0.0.1:8418/shared.git`,对走 T0/T1(overlay)还是 T2(frp TCP)零感知;切层即原子切代理上游(§2.1)。
- ⏳ Phase4:N 客户端证书签发/接入工具 + 星型多客户端联调。
- ⏳ Phase5:GUI 连接状态页 + e2e 自动化(netns 模拟对称 NAT/UDP 封锁,验证逐级降级与恢复升级)。
