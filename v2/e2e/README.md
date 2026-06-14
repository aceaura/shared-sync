# v2/e2e —— Phase5 完整三层阶梯 e2e(NAT/封锁场景下 connd 逐级升降级的回归门禁)

把 v2 的**完整三层阶梯**做成自动化 e2e:用 `ip netns` 精确控制客户端的 **NAT 类型**与
**UDP 封锁**,驱动**真 connd** 走完整阶梯,并按场景断言 `tier`/`viaVps` + 引擎经
**固定本地端点** `git ls-remote` 成功。任一断言失败退出码 1。作为 v2 的回归门禁。

> 复用件:沿用 `v2/sim-vps`(netns 双 NAT + full-cone/对称 NAT 经验 + hostmap `currentRemote`
> 判定)、`v2/frp`(STCP T2 兜底)、`v2/connd`(真阶梯状态机)。不同点:本套把整个星型世界
> (lighthouse+frps+数据中心+客户端+connd)**自洽**封进一个 `--privileged` 容器,可在
> macOS / 将来 CI 一键复现,**不连真 VPS、不碰生产 nebula-lighthouse/frps/ss-server**。

## 覆盖的四场景(DESIGN_v2 §4/§5/§7)

| 场景 | 客户端 NAT/封锁 | 期望 connd | 关键断言 |
| --- | --- | --- | --- |
| **A** | full-cone NAT | **T0 直连** | `tier=T0` `viaVps=false`,`currentRemote`=数据中心 NAT 映射(非 lighthouse),hostmap=DIRECT,git 通 |
| **B** | 对称 NAT(打洞必失败) | **T1 UDP 中继** | `tier=T1` `viaVps=true`,`currentRemote` 空 / hostmap=RELAY(经 lighthouse),git 仍通 |
| **C** | 封死 UDP | **T2 TCP 兜底** | `tier=T2` `viaVps=true`,`upstream`=frpc visitor 本地口;overlay 直达已断(ping 失败)但 git 经【同一本地端点】走 frp TCP 仍通 |
| **D** | 恢复 C→B→A | **逐级升回** | D1:解封 UDP 但仍对称 → 升回 **T1**;D2:恢复 full-cone → 升回 **T0**(滞后窗口 + 灌包驱动 `try_promote`);每步 git 仍通 |

每场景都断言:① connd `status` 的 `tier`/`viaVps`(权威判据是 nebula hostmap `currentRemote`
+ overlay 心跳,见 DESIGN §5);② 引擎(git 客户端)经 connd 固定本地端点
`http://127.0.0.1:8418/shared.git` `ls-remote` 列到真实 ref。

## 自洽拓扑(全部在一个容器的 netns 内)

```text
 backbone bridge br-e2ebb(100.66.0.0/24,模拟"公网")
  ├─ ns e2e-pub : lighthouse(am_lighthouse + am_relay,overlay 10.99.0.1)
  │               + frps(bindPort 7000)        ← T2 STCP 撮合点(自洽,非真 VPS)
  ├─ ns e2e-rd  : 数据中心路由器(full-cone NAT,固定)— DC 打洞友好(DESIGN §7)
  ├─ ns e2e-dc  : 数据中心 nebula(10.99.0.2)+ git http(8418)+ frpc STCP 服务端
  ├─ ns e2e-rc  : 客户端路由器(NAT 类型【可切】fullcone/symmetric/blockudp)← 被测变量
  └─ ns e2e-cli : 客户端 nebula(10.99.0.11)+ 控制 sshd + frpc visitor + 【connd】
                  connd 固定本地端点 127.0.0.1:8418;t2BackendAddr=127.0.0.1:18418
```

与生产 / sim-vps 完全隔离:独立 overlay `10.99.0.0/24`、backbone `100.66.0.0/24`、tun
`e2eneb0`、netns 前缀 `e2e-`、独立 CA(容器内现签)、自带 frps(不连真 VPS)。

### NAT 类型如何精确模拟(`lib.sh: set_client_nat`)

- **fullcone**:出站 SNAT 固定源端口(端点无关源映射)+ 入站静态 DNAT(端点无关目的映射)
  → nebula 打洞可成 → connd 升 **T0**。`currentRemote`=数据中心 NAT 公网映射(`RD_PUB:4242`)。
- **symmetric**:普通 `MASQUERADE`(逐 (dst-ip,dst-port) 选不同源端口 = 端点相关映射),
  **无 full-cone 的入站静态 DNAT**,且 DROP 客户端↔数据中心的【直连】underlay UDP(只保留
  客户端↔lighthouse 的 relay 路径)→ 打洞必失败、已建直连也被打断 → nebula 落 relay →
  connd 落 **T1**。这精确复刻对称 NAT 的可观测后果:「到数据中心的直连端点不可用,只能经 relay」。
- **blockudp**:保留 full-cone 规则但在 FORWARD DROP 所有 underlay UDP(含到 lighthouse)
  → nebula 全 DOWN → connd 落 **T2**(frp TCP)。
- 切换后只清 **UDP** conntrack(`conntrack -D -p udp`)使旧 underlay 映射立即失效,
  **不动 TCP conntrack**(否则会打断 frpc↔frps 的 STCP 隧道,误伤 T2)。

## 用法

### A) macOS / 任意宿主(推荐):封进 privileged 容器一键跑

```bash
bash v2/e2e/run-in-docker.sh            # 构建镜像 + 跑四场景,结束删容器
KEEP=1 bash v2/e2e/run-in-docker.sh     # 容器保留排查:docker exec -it ss-e2e bash
bash v2/e2e/run-in-docker.sh --cleanup  # 仅删容器/镜像
```

`run-in-docker.sh` 自动:从 `nebulaoss/nebula` 镜像提取 `nebula`/`nebula-cert`、从 frp
release 提取 `frpc`/`frps`、`GOOS=linux` 交叉编译 `connd`,打进 `Dockerfile` 镜像,
`docker run --privileged --device /dev/net/tun` 跑 `run.sh`。

依赖:`docker`、`go`、能拉 `nebulaoss/nebula` 镜像与 frp release(或用本机缓存)。

### B) 已在真 Linux / VPS 里(有 root + netns):直接跑 run.sh

```bash
sudo bash v2/e2e/run.sh             # 跑四场景并清理
sudo KEEP=1 bash v2/e2e/run.sh      # 跑完保留 netns 排查
sudo bash v2/e2e/run.sh --cleanup   # 仅清理
```

需要 `nebula`/`nebula-cert`/`frpc`/`frps`/`connd` 在 PATH(或用环境变量指定路径)。
若在真 VPS 上跑:本套**自建独立 netns 世界**(独立网段/CA/tun/netns 前缀 + 自带 frps),
**不会动**生产 `nebula-lighthouse`/`frps`/`ss-server`(它们继续在 systemd / 容器里跑)。

## 文件

| 文件 | 作用 |
| --- | --- |
| `run.sh` | 四场景驱动 + 断言 + 逐场景 PASS/FAIL 汇总(在真 Linux/netns 内跑)。 |
| `lib.sh` | 可复用函数库:证书/配置渲染、netns 拓扑、`set_client_nat`(NAT 切换核心)、服务起停、connd status/git 断言辅助。 |
| `Dockerfile` | 自洽 e2e 世界镜像(debian + iproute2/iptables/conntrack/python3/git + nebula/frpc/frps/connd)。 |
| `run-in-docker.sh` | 宿主侧封装:备料 + 构建镜像 + privileged 跑 + 清理。 |

## 调参(环境变量,见 `lib.sh` 顶部)

`E2E_OVERLAY_CIDR`/`E2E_BB`(网段)、`E2E_PORT`(nebula underlay)、`E2E_GIT_PORT`/
`E2E_VISITOR_PORT`/`E2E_PROXY_PORT`/`E2E_FRPS_PORT`、`E2E_FRP_TOKEN`/`E2E_FRP_SECRET`。
connd 探测/滞后参数在 `connd.yaml` 渲染处压短(`heartbeat=3s tUp=8s n=3 p=8s`),
使升降级在分钟级内可观测;生产用默认(`tUp≈25s` 等)。

## 实测(2026-06-14,本机 macOS arm64 → privileged linux/arm64 容器,自洽世界,真 connd)

`bash run-in-docker.sh`,**PASS=17 FAIL=0**:

```text
场景A full-cone  tier=T0 viaVps=false upstream=10.99.0.2:8418 currentRemote=100.66.0.20:4242 tiersHealth T0/T1/T2=UP  hostmap=DIRECT  git ls-remote ⇒ refs/heads/current ✓
场景B 对称NAT    tier=T1 viaVps=true  upstream=10.99.0.2:8418 currentRemote=(空)            tiersHealth T0=DOWN T1/T2=UP  hostmap=RELAY 10.99.0.1  git 仍通 ✓
场景C 封死UDP    tier=T2 viaVps=true  upstream=127.0.0.1:18418(frpc visitor)            tiersHealth T0/T1=DOWN T2=UP  ping 10.99.0.2 失败(overlay 确断)/ git 经同一本地端点走 frp TCP 仍通 ✓
场景D1 C→B 恢复  tier=T1 viaVps=true(解封 UDP 但仍对称 → 升回 T1,不到 T0)            git 仍通 ✓
场景D2 B→A 恢复  tier=T0 viaVps=false(恢复 full-cone → 灌包驱动 try_promote 升回直连)  git 仍通 ✓
```

引擎(git 客户端)全程只连固定本地端点 `http://127.0.0.1:8418/shared.git`,对走
T0/T1(overlay)还是 T2(frp TCP)零感知;切层即原子切代理上游(DESIGN §2.1)。
跑完自动清理容器 / netns;VPS 生产组件未动。

## 已知陷阱(本套踩过,均已修)

- **frpc 启动竞态**:frps 未就绪时 frpc 首拨被 refuse,frp 默认 `loginFailExit=true` 会让
  frpc **直接退出**(不重连),导致 T2 永远 DOWN。修:配置加**顶层** `loginFailExit = false`
  (不是 `transport.loginFailExit` —— 那是运行期未知字段会被拒)+ 起 frpc 前先等 frps 监听。
- **切 NAT 误伤 T2**:`conntrack -F`(全清)会打断 frpc↔frps 的 established TCP,使 T2 抖 DOWN。
  改为只删 UDP conntrack(`-D -p udp`)。
- **对称 NAT 不会自动断已建直连**:只改 NAT 模式不能让 nebula 从已收敛的 T0 掉下来;须显式
  DROP 客户端↔数据中心的直连 UDP(保留 relay 路径)才能驱动 T0→T1 降级(见 `set_client_nat symmetric`)。
- **relay→direct 升级靠包计数**:D2 升回 T0 须高速灌包驱动 nebula `try_promote`
  (`e2e_warm_promote` / `e2e_wait_tier ... 2`),沿用 sim-vps STEP4 经验。
- **netns/Docker 下 NAT 后端**:用 `iptables-legacy`(镜像里 `update-alternatives` 切)避免
  nft 后端在 netns 内 nat/DNAT 行为差异。
