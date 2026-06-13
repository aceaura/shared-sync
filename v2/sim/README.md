# v2/sim — 双 NAT 本地模拟环境 + 连通性实跑验证

用 Docker 在本机复现 shared-sync v2「两个 NAT 后的私网借公网 lighthouse 互通」的拓扑,
并实跑三步验证:Nebula 链路本身通 → 双 NAT 下 overlay 互通 → 中继兜底 + shared-sync 端到端。

> 上游依赖 [`v2/nebula/`](../nebula/)(CA/证书/lighthouse.yml/node.yml.tmpl),本目录直接复用。
> 复用的设计见 [`DESIGN_v2.md`](../../DESIGN_v2.md):稳定 overlay IP、兜底优先、direct 为升级。

---

## 1. 一键运行

```bash
bash v2/sim/run.sh            # 构建镜像 → 三步验证 → 打印 PASS/FAIL → 自动清理
KEEP=1     bash v2/sim/run.sh # 跑完不清理,便于手动 docker exec 排查
SKIP_BUILD=1 bash v2/sim/run.sh
```

需要:Docker(本机实测 29.1.3 + Compose v5)、`/opt/homebrew/bin` 里的工具(脚本已自动 export PATH)。
首次会拉 `nebulaoss/nebula:latest`(Nebula 1.10.3)与 `ghcr.io/aceaura/shared-sync-server:1.0.0`。

最近一次实跑结果:**STEP1/2/3a/3b/3c 全 PASS(5/5),结束无残留**。

---

## 2. 拓扑

三张【互不直连】的 docker bridge 网络模拟「公网 + 两个独立家庭/公司私网」:

```
            ┌──────────────── public 10.88.0.0/24 ────────────────┐
            │  lighthouse 10.88.0.10   (rendezvous 打洞协调 + relay 中继)
            │        ▲                                ▲            │
            │  router-home 10.88.0.2          router-company 10.88.0.3
            └────────┼────────────────────────────────┼───────────┘
       (NAT/MASQ)    │                                 │  (NAT/MASQ)
        priv-home 10.66.0.0/24                 priv-company 10.55.0.0/24
            │                                         │
        home 10.66.0.2                          company 10.55.0.2
        默认路由 -> 10.66.0.1(router-home)      默认路由 -> 10.55.0.1(router-company)
        overlay 10.77.0.2                       overlay 10.77.0.3
        + shared-sync-server(共享 home netns)
```

- **priv-home 与 priv-company 之间没有任何 L3 直连路由**。两端只能各自经自己的 router
  `MASQUERADE` 到 public 段,在 lighthouse 处相遇 → 这就是「双 NAT」。
- overlay 网段 `10.77.0.0/24` 由证书内 `-networks` 决定;主备路径共用同一 overlay IP,
  路径切换对 shared-sync 引擎透明。
- shared-sync 服务端用 `network_mode: service:home` 复用 home 节点的 netns(含 nebula tun);
  home 在 PREROUTING 把 overlay `:8418` REDIRECT 到服务端监听的 `:80`,于是对端用
  `http://10.77.0.2:8418/shared.git` 访问,**同步流量跑在 overlay 上**。

### 文件

| 文件 | 作用 |
| --- | --- |
| `docker-compose.flat.yml` | STEP1 平面拓扑:3 个 nebula 容器同网,排除证书/配置问题 |
| `docker-compose.nat.yml`  | STEP2/3 双 NAT 拓扑(核心) |
| `Dockerfile.node`         | nebula 节点镜像(alpine + 官方 /nebula 二进制 + ping/curl/git) |
| `Dockerfile.router`       | NAT 网关镜像(alpine + iptables/iproute2) |
| `node-entrypoint.sh`      | 节点入口:改默认路由走 router、渲染 nebula 配置、(home)8418→80 重定向、起 nebula |
| `router-entrypoint.sh`    | router 入口:ip_forward 校验 + MASQUERADE + full-cone DNAT/SNAT + BLOCK_DIRECT |
| `run.sh`                  | 一键三步验证 + PASS/FAIL + 清理 |

---

## 3. 三步验证(run.sh 实跑内容)

| 步骤 | 做什么 | 断言 | 实跑结果 |
| --- | --- | --- | --- |
| **STEP1** 平面 | 3 nebula 同网,home ping company overlay | overlay 互通 | PASS,0% loss,RTT ~0.5ms |
| **STEP2** 双 NAT | NAT 拓扑起,home ping company overlay;读 conntrack 判 direct/relay | overlay 互通 | PASS,0% loss;判定 **RELAY** |
| **STEP3a** 阻断 | router FORWARD 丢两 public IP 间 UDP,强制 relay,再 ping | 阻断后仍通 | PASS,0% loss |
| **STEP3b** 端到端 | company 经 `http://10.77.0.2:8418/shared.git` clone+commit+push+复 clone | 文件回读成功 | PASS,`* [new branch] current` |
| **STEP3c** 解除 | 删除阻断规则,再 ping | 仍互通 | PASS,0% loss |

### direct / relay 怎么判定

run.sh 读 `router-home` 的 `/proc/net/nf_conntrack`:
- 若存在「去往对端 router public IP `10.88.0.3:4242` 且【已回包】(非 `[UNREPLIED]`)」的 UDP 流 → **direct**;
- 否则只有去 lighthouse(`10.88.0.10`)的流活跃 → **relay**(经 lighthouse 转发加密包)。

也可手动用 nebula 自带的 hostmap dump:`docker exec sim-nat-home sh -c 'kill -USR1 1'`,再看
`docker logs sim-nat-home`。

---

## 4. 为让 docker NAT 能跑通,做了两处非显然修正

排查中踩到两个 docker 网络层的坑(详见 `docker-compose.nat.yml` / `router-entrypoint.sh` 注释):

1. **关掉 docker 对 private 网桥的自动 MASQUERADE**
   (`com.docker.network.bridge.enable_ip_masquerade: "false"`)。
   否则 docker 会装 `-A POSTROUTING -s 10.66.0.0/24 ! -o <bridge> -j MASQUERADE`,
   把「经 router 转发进 private 段的对端包」源地址改写成网桥地址(如 `10.66.0.254`),
   节点把对端误认成自己的网关,回包发错方向 → tunnel `state:dead`。关掉后源 IP 一路保留到
   router,由 router 自己做【单层】NAT。

2. **router 对 nebula 端口 4242 做端口保持 SNAT + 固定 DNAT**(full-cone 化)。
   通用 `MASQUERADE` 会按目的不同分配【不同】源端口(行为近 symmetric NAT),打洞打不通。
   `router-entrypoint.sh` 对 `--sport 4242` 出站固定 SNAT 到 `pub_ip:4242`,配合入站
   `DNAT pub_ip:4242 -> node:4242`,让节点在公网上呈现稳定 endpoint(真实家用路由器多为此型)。

---

## 5. 已知局限(如实记录,留给下一阶段)

### 5.1 direct 打洞在本 docker 拓扑【无法收敛】,恒走 relay

**现象**:STEP2 即使不阻断,nebula 也走 relay;direct 握手始终 `[UNREPLIED]` / `tunnel dead`。

**根因(已用脱离 nebula 的纯 UDP 回环实验定位)**:在 router-home / router-company 上各加
临时 `DNAT udp/9000 -> node:9000` + 端口保持 `SNAT`,company 端 socat 能收到并回 echo,
但 home 端收不到 echo。conntrack 显示两侧都是两条独立的 `[UNREPLIED]` 流,而非一条双向流——
即 **两层 NAT 叠加 + 各自独立的 DNAT/SNAT 使 UDP 的来回 4-tuple 无法在 conntrack 里配成对**,
回包匹配不上正向流的反向映射。这是 docker bridge 模型(尤其 Docker Desktop 的 LinuxKit VM)
模拟「NAT 背后再 NAT 的对称双向 UDP 打洞」的固有限制,不是证书/nebula 配置问题
(STEP1 平面拓扑里 nebula direct 一打就通,已证明这一点)。

**影响**:本模拟可完整验证 **relay 兜底链路**与 **shared-sync overlay 端到端**(这正是设计里
「兜底优先、连接全程不中断」的核心保证),但**不能**验证「打洞建立 direct」与「direct⇄relay
自动切回」。STEP3c 解除阻断后真实环境应切回 direct,本环境仍是 relay。

**下一步怎么弄(任选其一)**:
- 用 **Linux network namespace + veth + 真 iptables**(非 docker bridge)手搭双 NAT,
  能精确控制 NAT 类型(full-cone vs symmetric),direct 可打通——在 Linux 主机或
  `--privileged` 的单个 Linux 容器内用 `ip netns` 搭建。
- 或在【真公网 VPS】+ 两个真实 NAT(家庭/手机热点)做一次 direct 实测,作为
  connd Phase1 的验收(模拟环境只兜底验 relay)。
- 或换 `gVisor`/用户态网络栈复现端口行为;成本高,不建议在 Phase0 做。

### 5.2 重启 home 节点会断开 shared-sync 服务端

`sharedsync-server` 用 `network_mode: service:home` 复用 home 的 netns。**一旦 `docker restart
home`,netns 被重建,server 容器会留在旧的(已死)netns 上**,表现为 home 内 `127.0.0.1:80`
连不上。run.sh 因此**全程不重启 home**;若手动重启了 home,需 `docker restart
sim-nat-sharedsync-server` 让其重新附着。

### 5.3 home 自访问 `10.77.0.2:8418` 不通(无影响)

PREROUTING 的 REDIRECT 只作用于【经过】协议栈的转发/入站包,不作用于本机发往本机非 loopback
IP 的包。所以 home 自己 curl `10.77.0.2:8418` 会失败,但**对端 company 经 overlay 访问正常**
(STEP3b 已验证 200 + clone/push 成功)。这只是自测路径的特性,不影响真实用法。

---

## 6. 手动排查片段(KEEP=1 跑完后)

```bash
# 进 home 看 nebula 日志 / hostmap
docker logs sim-nat-home | tail -30
docker exec sim-nat-home sh -c 'kill -USR1 1' && docker logs sim-nat-home | tail

# 看 router 的 NAT 规则与 conntrack
docker exec sim-nat-router-home iptables -t nat -S
docker exec sim-nat-router-home sh -c 'cat /proc/net/nf_conntrack | grep 4242'

# 手动跑一次 overlay 上的 git
docker exec sim-nat-company sh -c 'git clone http://10.77.0.2:8418/shared.git /tmp/x && ls /tmp/x'

# 手动清理
docker compose -f v2/sim/docker-compose.nat.yml  down -v
docker compose -f v2/sim/docker-compose.flat.yml down -v
```
