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
- ✅ Phase4:N 客户端证书签发/接入工具 + 星型多客户端真机联调(都真连真 VPS)。
  - **签发(`v2/nebula/gen-certs.sh` 扩展)**:子命令化 + 角色化命名,保留旧批量用法。
    `sign lighthouse|datacenter|client-<名字>[ <ip>]` 幂等签发任意角色节点证书;`client-*` 自动从
    `10.77.0.11+` 分配空闲 overlay IP(扫 `certs/` 已占用 IP),非 client-* 节点要求显式 IP;
    `list`/`print` 查看;`sign` 末行输出 `ASSIGNED <name> <ip>/24` 供上层脚本消费。私钥仍只落
    `v2/nebula/certs/`(gitignored)。星型 IP 规划:lighthouse=.1 / **datacenter=.2** / 客户端=.11+
    (与旧 home/company 的 .2/.3 解耦)。
  - **接入工具(`v2/deploy/enroll-client.sh <名字> <lighthouse公网IP> [dc-overlay]`)**:一条命令产出
    **可直接跑的客户端配置包** `v2/deploy/dist/<名字>/` —— 经 gen-certs 签证 + 生成控制 ssh 密钥/
    sshd hostkey + 渲染 `node.yml`(连真 lighthouse 撑 T0/T1)/`frpc-visitor.toml`(本地
    `127.0.0.1:18418` = connd `t2BackendAddr`)/`connd.yaml`(三层阶梯 + 固定本地端点
    `127.0.0.1:8418`)+ 拷 ca/crt/key + README/MANIFEST。**「新增一台客户端 = 跑一次这个脚本,
    不动 lighthouse/数据中心/其他客户端」**;dist/ 含私钥已 gitignore。
  - **星型联调(`v2/deploy/star-e2e.sh`,真机实跑)**:本机 Docker 起 1 数据中心(生产 git 镜像
    + nebula `datacenter`=10.77.0.2 + frpc STCP 服务端)+ **2 客户端**(ss-alice=.11 / ss-bob=.12,
    配置直接挂 `enroll-client.sh` 产出的 dist/<名字>/),**都真连真 VPS**(lighthouse 4242 +
    frps 7000)。客户端互不通信,各自经本地端点 `127.0.0.1:8418` 指向同一数据中心 `10.77.0.2`。
    STCP `serverName=ss-git` 单一数据中心 proxy,N 个 visitor 共用同一 secretKey 即 N 条独立 T2。
  - **端到端实测**(`star-e2e.sh`,`FREEZE_UDP=1`,**PASS=14 FAIL=0**,2026-06-14;跑完清理本机
    容器/网络,VPS 上 nebula-lighthouse/frps/ss-server 全程 active 未动):

    ```text
    N→1 星型   alice/bob 各经【各自本地端点 127.0.0.1:8418】git ls-remote ⇒ 67b13d3 HEAD / refs/heads/current ✓✓
               (稳态两客户端均 tier=T1 viaVps=true upstream=10.77.0.2:80;Docker 下 T0 直连不收敛,T1 为稳定最优层)
    共享中转   alice clone→新增 from-alice-<ts>.txt→push refs/heads/current(快进)✓
               bob 全新 clone 工作树含 README + from-alice-<ts>.txt ✓;bob pull 读到内容 "hello from alice @ <ts>" ✓
               —— 证明 N 客户端经【同一数据中心】中转共享,A 写 B 见
    隧道独立   封 alice 出站 UDP:alice 独立降级 tier=T2(T0/T1=DOWN,upstream=127.0.0.1:18418,git 经 frp TCP 仍通)✓
               同一时刻 bob 不受影响 tier=T1(T1=UP,upstream=10.77.0.2:80,git 仍通)✓ —— 每条客户端↔数据中心隧道各自独立
               解封 alice UDP:滞后窗口后 alice 升回 overlay tier=T1 ✓
    ```

    引擎(git 客户端)全程只连各自固定本地端点 `http://127.0.0.1:8418/shared.git`,对走 T0/T1/T2 零感知。
- 🔄 Phase5:GUI 连接状态页(⏳ 待做)+ e2e 自动化(✅ 完成,见下)。
  - ✅ **Phase5-e2e 完整三层阶梯回归门禁(`v2/e2e/`)**:用 `ip netns` 精确控制客户端 NAT 类型
    与 UDP 封锁,驱动**真 connd** 走完整阶梯并按场景断言 `tier`/`viaVps` + 引擎经固定本地端点
    `git ls-remote` 成功;任一断言失败退出码 1,结束清理。
    - **自洽世界**:把整个星型(lighthouse+frps+数据中心 git+客户端 connd)封进一个
      `--privileged` Linux 容器(`run-in-docker.sh`),可在 macOS / 将来 CI 一键复现,
      **不连真 VPS、不动生产 nebula-lighthouse/frps/ss-server**。独立 overlay `10.99.0.0/24`
      / backbone `100.66.0.0/24` / tun `e2eneb0` / netns 前缀 `e2e-` / 独立 CA / 自带 frps,
      与生产 + sim-vps 完全隔离。
    - **NAT 精确模拟**(`set_client_nat`):full-cone(SNAT 固定源端口 + 入站静态 DNAT)→ 打洞成 →
      T0;对称(普通 MASQUERADE 无入站 DNAT + DROP 客户端↔数据中心直连 UDP,保留 relay 路径)→
      打洞必失败 → T1;封死 UDP → T2。切 NAT 只清 UDP conntrack,不误伤 frpc↔frps 的 TCP 隧道。
    - **端到端四场景实测**(`bash v2/e2e/run-in-docker.sh`,**PASS=17 FAIL=0**,2026-06-14,
      本机 macOS arm64 → privileged linux/arm64 容器,自洽世界 + 真 connd):

      ```text
      场景A full-cone  tier=T0 viaVps=false upstream=10.99.0.2:8418 currentRemote=100.66.0.20:4242 hostmap=DIRECT  tiersHealth T0/T1/T2=UP  git ls-remote ⇒ refs/heads/current ✓
      场景B 对称NAT    tier=T1 viaVps=true  upstream=10.99.0.2:8418 currentRemote=(空) hostmap=RELAY 10.99.0.1  T0=DOWN T1/T2=UP  git 仍通 ✓
      场景C 封死UDP    tier=T2 viaVps=true  upstream=127.0.0.1:18418(frpc visitor)  T0/T1=DOWN T2=UP  ping 10.99.0.2 失败(overlay 确断)/ git 经同一本地端点走 frp TCP 仍通 ✓
      场景D 恢复C→B→A  D1 解封UDP仍对称⇒升回 T1;D2 恢复 full-cone⇒灌包驱动 try_promote 升回 T0(viaVps=false);每步 git 仍通 ✓
      ```

      引擎全程只连固定本地端点 `http://127.0.0.1:8418/shared.git`,对走 T0/T1(overlay)还是
      T2(frp TCP)零感知;切层即原子切代理上游(§2.1)。每场景断言 connd hostmap `currentRemote`
      + overlay 心跳判层(§5)。坑(均已修):frpc 默认 `loginFailExit=true` 启动竞态会让 frpc
      退出致 T2 永 DOWN(改顶层 `loginFailExit=false` + 等 frps 就绪);`conntrack -F` 全清误伤
      frpc TCP(改只删 UDP);对称 NAT 须显式断直连 UDP 才驱动 T0→T1 降级。
  - ⏳ **GUI 连接状态页**:把 connd `/status`(tier/viaVps/upstream/peer/rttMs/lastSwitch 等)
    接进 client/app 的连接页(DESIGN §6),为独立子任务,尚未做。
- 🔄 Phase7:跨平台一体化(装 App → 导入接入包 → 完事;见下 §11)。
  - ✅ **App「导入接入包」能力**(client/app,平台无关、已单测):
    `app_state.dart` 的纯逻辑函数 `importEnrollBundle` + 设置页「导入接入包」按钮。
  - ⏳ **特权服务安装**(安装器注册 connd/nebula 系统服务):待 connd 原生(非容器)
    跑通后再落地,见 §11.4。

## 11. Phase7:跨平台一体化(装 App → 导入接入包 → 完事)

### 11.1 背景与目标

v2 至今要装两次:桌面 App(同步引擎 + GUI)与独立的 connd 连接层(connd/nebula/frpc
三件套 + 证书),用户得手动起三件套、改 `server_url`,体验差。Phase7 把二者收敛成
**一次安装 + 一次导入**:

> **装 App → 首启向导里「导入接入包」→ 选共享目录 → 完事。** 连接层二进制随 App 安装器
> 一并落地并注册为系统服务(特权,建虚拟网卡);接入包(证书 + 配置)由 App 落到每机
> 固定数据目录并改写路径;引擎 `server_url` 自动指向 connd 本地端点 `127.0.0.1:8418`。

把工作分两类:**(A) 平台无关、可测**(本阶段已做:导入接入包的纯逻辑 + UI + 单测);
**(B) 特权 / 平台相关**(安装器打包二进制、注册系统服务、就地升级——待 connd 原生验证后做)。

### 11.2 每机固定数据目录(连接层配置/证书的家)

连接层所有运行态文件(证书、node.yml、connd.yaml、frpc-visitor.toml、ctl_key、
sshd_hostkey)统一落到**每机固定数据目录**,App 与系统服务都读它,且**跨 App 升级保留**:

| 平台 | 数据目录 |
|---|---|
| Windows | `%ProgramData%\shared-sync`(即 `C:\ProgramData\shared-sync`) |
| macOS | `/Library/Application Support/shared-sync` |
| Linux(开发/容器) | `/var/lib/shared-sync` |

(App 自身偏好仍各自放用户级目录,见 `AppState._defaultPrefsPath`;数据目录只放连接层。)

### 11.3 App 首启向导「导入接入包」(✅ 平台无关部分已做)

- **入口**:设置页 / 首启向导加「导入接入包…」按钮(`settings_page.dart`),`file_selector`
  选 enroll 产出的**目录**(zip 见 §11.6 TODO)。
- **解析与落盘**(纯逻辑 `importEnrollBundle`,`app_state.dart`,已单测):
  1. 校验目录含 `node.yml` / `connd.yaml` / `frpc-visitor.toml` / `ca.crt` /
     `client-*.crt` / `client-*.key` / `ctl_key` / `sshd_hostkey`(缺则报错,不写半套);
  2. 把这些文件写到数据目录(§11.2),`.pub` 存在则一并存档;
  3. 把 `node.yml` / `connd.yaml` 里所有 `/etc/nebula/` 改写为数据目录(**统一正斜杠**,
     Windows 上 nebula 也吃正斜杠);把 `connd.yaml` 的 `binPath:` 指到数据目录下的
     nebula 可执行(名平台相关:Windows `nebula.exe` / 其余 `nebula`,函数参数
     `nebulaBinName` 传入);
  4. 返回:写入的文件清单 + 解析出的 overlay IP / 客户端名 / 数据中心 overlay +
     固定 `server_url = http://127.0.0.1:8418/shared.git`。
- **配置回填**:导入成功后 App 自动把引擎 `server_url` 设为该固定本地端点并保存配置
  (`AppState.importBundle`),用户只需再选共享目录。提示「接入包已导入,连接层将由
  安装服务接管」;**connd 未运行时连接页保留既有友好提示**(`connection_page.dart`)。
- **边界**:此函数/方法**只碰文件与字符串**——不起进程、不碰特权、不装服务、不连网络,
  故可确定性单测(用 `v2/deploy/dist/winpc` 真实样例作输入)。

### 11.4 特权服务(⏳ 待 connd 原生验证后落地)

connd + nebula 需管理员/root(建虚拟网卡 tun/Wintun)。**App 本体不提权**,只:
读 connd `/status`、写数据目录配置、触发服务重启(重启动作本身要提权)。分平台:

- **Windows**:安装器(Inno Setup)把 `connd.exe` / `nebula.exe` / `frpc.exe` +
  **Wintun** 驱动随 App 一并安装,并**注册 Windows 服务(LocalSystem)**指向数据目录的
  `connd.yaml`。配置变更后触发重启:由 App 提权(UAC)或安装器辅助小工具 `sc stop/start`。
- **macOS**:打包形态从纯 `.dmg` 改为 **`.pkg`**,其 `postinstall` 脚本把二进制装到
  `/Library/Application Support/shared-sync/bin`(或 `/usr/local/...`),并安装一个
  **launchd LaunchDaemon(root)** `com.aceaura.shared-sync.connd.plist` 指向数据目录的
  `connd.yaml`。配置变更后由 App 调 `launchctl kickstart -k system/com.aceaura.shared-sync.connd`
  触发重载(该子命令在系统域,需一次提权授权)。
- **为何待验证**:connd/nebula 至今只在 **privileged Linux 容器**里端到端验证过
  (Phase2–5 全是容器内 netns / Docker)。**connd 原生跑在 Windows 服务 / macOS
  LaunchDaemon 下**(真 Wintun / 真 utun、真系统服务生命周期、真提权重启)尚未验证,
  故安装器注册服务这部分**先不落地**,等 connd 原生跑通后再做(本设计先把契约定清)。

### 11.5 自动覆盖上次安装(就地升级)

目标:升级 App **不需重新导入接入包**——配置在数据目录里,安装器不碰它。

- **Windows(Inno Setup)**:固定 `AppId` 即就地升级覆盖旧版;补**安装前停**旧
  connd/frpc 服务、换二进制、**安装后起**服务。`%ProgramData%\shared-sync` 数据目录
  **不在安装器的文件清单里**,天然跨升级保留。
- **macOS(.pkg)**:升级即替换 `/Applications/Shared Sync.app` 与
  `/Library/Application Support/shared-sync/bin` 下二进制,`postinstall` 重载 LaunchDaemon
  (`launchctl bootout` 旧 → `bootstrap` 新,或 `kickstart -k`)。数据目录里的证书/配置
  **不被 pkg payload 覆盖**(payload 只含二进制 + plist),保留。
- 升级流程统一:**检测旧版 → 停旧 connd/frpc → 换二进制 → 重载服务**;接入包配置原样保留。
  (这部分随 §11.4 一起,待 connd 原生验证后落地。)

### 11.6 现状与 TODO

- ✅ 已做(平台无关、可测):`importEnrollBundle` 纯逻辑 + `AppState.importBundle` 回填
  server_url + 设置页「导入接入包…」按钮 + 单测(`client/app/test/enroll_import_test.dart`,
  用 `v2/deploy/dist/winpc` 真实样例)。`flutter analyze` 0 issue;`flutter test` 全绿。
- ⏳ **zip 接入包**:当前先支持选**目录**;zip 解压可后续用 `archive` 包加(本阶段
  目录优先,留 TODO)。导入逻辑本身对「已解开的目录」无差别,zip 仅需前置一步解压。
- ⏳ **特权服务安装 / 就地升级**(§11.4 / §11.5):待 connd 原生(Windows 服务 /
  macOS LaunchDaemon,真虚拟网卡)验证后落地。
