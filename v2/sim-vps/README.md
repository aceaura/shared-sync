# sim-vps — 真 Linux netns 双 NAT 实验台(验证 Nebula T0 直连打洞)

Phase1b 的产物。在**真 Linux**(VPS / 任意 Linux 主机,需 root)上用 `ip netns` +
`veth` + `iptables` 搭一套**可控双 NAT** 环境,验证 Nebula 的三层路径:

- **T0 直连(DIRECT)**:A↔B 经 lighthouse 协调,UDP 打洞建立 P2P 直连。
- **T1 中继(RELAY)**:打不通时经 lighthouse 中继兜底。
- **切回**:直连恢复后自动升级回 T0。

> 补 Phase0 的缺口:Phase0 在 macOS Docker Desktop / LinuxKit 下 direct 打洞**未收敛**
> (其 NAT 行为不是真 conntrack)。本实验台在**真 Linux conntrack + full-cone NAT** 下,
> T0 直连**可稳定收敛**(见下方实测),并沉淀「如何程序式判定 direct vs relay」供 connd 用。

## 一键运行

```bash
sudo bash run.sh            # 跑 STEP2/3/4 全部断言并自动清理
sudo KEEP=1 bash run.sh     # 跑完保留环境,便于手动排查
sudo bash run.sh --cleanup  # 仅清理(netns/bridge/本 sim 的 iptables 规则)
```

依赖:`root` + `nebula(>=1.10)` + `iproute2` + `iptables` + `python3` + `ssh/ssh-keygen` +
`docker`(仅用于 `nebula-cert` 生成证书,无需本机装 nebula-cert);`conntrack` CLI 可选
(没有时降级窗口略长,不影响结论)。运行期工作目录默认 `/root/sim-vps`(`SVP_ROOT` 可改)。

## 拓扑

```text
                 ┌─────────────────────────────────────────────┐
                 │        backbone 100.64.0.0/24  (模拟"公网")   │
                 │            Linux bridge: br-svpbb            │
                 └──┬───────────────┬───────────────────┬──────┘
       100.64.0.1   │     100.64.0.10│         100.64.0.20│
   ┌────────────────┴─┐   ┌──────────┴────────┐  ┌────────┴──────────┐
   │  netns svp-pub   │   │  netns svp-ra      │  │  netns svp-rb      │
   │  lighthouse      │   │  router A (NAT)    │  │  router B (NAT)    │
   │  overlay 10.88.0.1│  │  full-cone NAT     │  │  full-cone NAT     │
   │  am_lighthouse   │   │  SNAT+静态DNAT     │  │  SNAT+静态DNAT     │
   │  am_relay        │   └─────────┬──────────┘  └─────────┬─────────┘
   └──────────────────┘   priv 10.10.1.1/24       priv 10.10.2.1/24
                                    │                       │
                          ┌─────────┴────────┐    ┌─────────┴────────┐
                          │ netns svp-na      │    │ netns svp-nb      │
                          │ nodeA priv 10.10.1.2│  │ nodeB priv 10.10.2.2│
                          │ overlay 10.88.0.2  │   │ overlay 10.88.0.3  │
                          └───────────────────┘    └───────────────────┘

两 private 段(10.10.1.0/24 与 10.10.2.0/24)之间【不可直接路由】,
只能各自经 router NAT 出 backbone 相遇 —— 真实双 NAT 打洞场景。
```

- **overlay 10.88.0.0/24** + **独立 sim-vps CA** + **tun=svpneb0**,与生产 nebula-lighthouse
  (overlay 10.77.0.0/24、CA、`nebula1`)**完全隔离**,可与生产并存。
- **full-cone NAT(关键)**:每个 router 对 nebula 的 `udp/4242` 用
  「**SNAT 固定源端口** + **静态 DNAT 入站**」,得到**端点无关(endpoint-independent)**映射 ——
  这是直连打洞能成的前提。默认的 `MASQUERADE` 是**端点相关**(类对称 NAT),打洞不通(见「踩坑」)。

## 「如何判定 direct vs relay」—— connd 要用的核心 handoff

### 结论:用 Nebula 内置 **控制 sshd** 的 `list-hostmap -json`,解析 `currentRemote`

**Nebula 1.10 的 `SIGUSR1` 不再向日志打印 hostmap**(实测发信号无任何输出),
**不要再依赖 SIGUSR1**。Nebula 提供了官方的**控制通道:内置 sshd**,通过它跑
`list-hostmap -json` 拿到结构化的 per-peer underlay 状态 —— 这是程序式判定的**权威来源**。

#### 1) 给节点配置控制 sshd(node 配置里加,sim 已自动渲染)

```yaml
sshd:
  enabled: true
  listen: 127.0.0.1:2222            # 仅本机;connd 与 nebula 同机,本地查询
  host_key: /path/to/hostkey        # ssh-keygen 生成
  authorized_users:
    - user: ctl
      keys: ["ssh-ed25519 AAAA... (connd 持有的公钥)"]
```

#### 2) 查询(connd 用 ssh exec 一次性命令)

```bash
ssh -i <key> -p 2222 -o StrictHostKeyChecking=no ctl@127.0.0.1 list-hostmap -json
```

返回 JSON 数组,每个元素是一个已知 peer。关键字段:

```jsonc
{
  "vpnAddrs": ["10.88.0.3"],              // peer 的 overlay IP(用它定位数据中心)
  "remoteAddrs": ["100.64.0.20:4242",     // 候选 underlay 端点(NAT 公网映射 + 私网直连)
                  "10.10.2.2:4242"],
  "currentRemote": "100.64.0.20:4242",    // ★ 当前实际发包的 underlay 端点(权威判据)
  "currentRelaysToMe": [],                // 备用中继入口(见下方"陷阱")
  "messageCounter": 21                    // 活跃度;持续增长=链路在用
}
```

#### 3) 判定规则(connd 实现)

针对数据中心 peer(已知其 overlay IP,如 `10.88.0.2`),在 hostmap 里找到对应条目后:

| 条件                                                                 | 判定        |
| -------------------------------------------------------------------- | ----------- |
| `currentRemote` 非空,且 **不是 lighthouse 的 underlay 地址**         | **DIRECT(T0)** |
| `currentRemote` 为空,但 `currentRelaysToMe` 非空                     | **RELAY(T1)**  |
| peer 不在 hostmap / 两者皆空                                          | 未建链 / UNKNOWN |

**权威字段是 `currentRemote`**:它就是 nebula 当前把加密包发往的 underlay socket 地址。
- 若它等于 peer 的 **NAT 公网映射**(`remoteAddrs` 里的非私网项)→ 数据走**直连**。
- 若它为空(只剩 relay 入口)→ 数据走**中继**。

> ⚠️ **陷阱(实测踩到,connd 必须注意)**:
> 1. **`currentRelaysToMe` 非空 ≠ 正在走中继**。direct 收敛后,nebula 仍会**保留一个备用
>    relay 登记**作为快速回退,此时 `currentRemote` 已是直连映射、数据 100% 走直连。
>    **不要看到 `currentRelaysToMe` 非空就判 relay —— 一律以 `currentRemote` 为准。**
> 2. **降级有滞后窗口**:直连路径被掐断后,hostmap 的 `currentRemote` 会**短暂残留**旧的
>    直连地址(~10-15s),nebula 才探测到死路并清空切到 relay。connd 不能只信 hostmap 一拍,
>    应**叠加 overlay 内对数据中心的轻量心跳/RTT**:`currentRemote` 指 direct **且** 心跳通,
>    才确认 direct 健康;心跳连续失败 N 次即触发降级(对应 DESIGN_v2 §4 的 N 次降级)。
> 3. **升级(relay→direct)由包计数触发**:nebula 的 `try_promote` 大约每 ~1000 个 overlay
>    包尝试一次提升。空闲链路可能长时间停在 relay。connd 若要"尽快切回 direct",可在探测期
>    **主动产生少量 overlay 流量**(如心跳本身)驱动 promote;实测灌包后秒级切回直连。

#### 4) 日志旁证(无控制 sshd 时的兜底解析)

握手日志里 `from=` 字段可佐证(但**不如 hostmap 权威/实时**,仅供调试):

```text
# DIRECT —— from 是 peer 的 NAT 公网映射,无 (relayed) 后缀
Handshake message received certName=nodeB ... from="100.64.0.20:4242" ... vpnAddrs="[10.88.0.3]"

# RELAY —— from 是 lighthouse 地址,带 (relayed) 后缀
Handshake message received certName=nodeB ... from="100.64.0.1:4242 (relayed)" ... vpnAddrs="[10.88.0.3]"
```

#### 5) 其它可用控制命令(`help` 全量)

`list-hostmap` / `print-tunnel` / `print-relays` / `list-pending-hostmap` /
`list-lighthouse-addrmap` / `query-lighthouse` / `change-remote` / `close-tunnel` /
`device-info` / `reload`。connd 主用 `list-hostmap -json`;`print-relays -json` 可观测
中继负载(DESIGN_v2 §5「relay 容量意识」)。

## 实测结果(2026-06-14,Amazon Linux 2023 x86_64,nebula 1.10.3)

`sudo bash run.sh` 输出汇总(全部关键断言 PASS):

```text
STEP2 T0 直连:hostmap currentRemote=100.64.0.20:4242(B 的 NAT 公网映射)  RTT≈0.42ms
STEP3 降级 T1:阻断 100.64.0.10<->100.64.0.20 UDP 后 currentRemote 空、经 relay 10.88.0.1;overlay 仍通
STEP4 切回 T0:解除阻断+灌包,currentRemote 回到 100.64.0.20:4242;抓包确认 206 包直连、0 包经 relay  RTT≈0.37ms
PASS=4  FAIL=0
```

对比:RELAY 时 overlay RTT 多一跳(经 lighthouse),DIRECT 时 sub-ms。

## 文件

| 文件        | 作用                                                                       |
| ----------- | -------------------------------------------------------------------------- |
| `run.sh`    | 一键:建拓扑→起 nebula→STEP2/3/4 断言→清理。退出码 0=全过。                 |
| `lib.sh`    | 可复用函数库(拓扑/证书/配置/nebula 起停/`peer_state` 判定/block_direct)。 |
| `README.md` | 本文。                                                                     |

`lib.sh` 是未来 e2e 的基础:`source lib.sh` 后可直接调用
`svp_gen_certs` / `svp_render_configs` / `topo_up` / `svp_start_nebula` /
`peer_state <ns> <peer>` / `wait_state` / `block_direct` / `unblock_direct` / `topo_down`。

## 踩坑记录(供复现/排障)

1. **Docker 主机的 `br-netfilter`**:装了 docker 的主机 `bridge-nf-call-iptables=1`,
   桥接帧会过 root-ns 的 `FORWARD`(策略常为 `DROP`)→ backbone 不通。
   `topo_up` 自动在 `DOCKER-USER`(或 `FORWARD`)插一条放行 `br-svpbb` 转发的规则
   (带 `svp-sim-backbone` comment,清理时精确删除)。
2. **MASQUERADE 打不通直连**:Linux `MASQUERADE` 的回包映射**绑定目的端**(端点相关,
   形同对称 NAT),A 发往 B 公网映射的包在 B 的 router 上无 conntrack 命中被丢。
   必须改成 **SNAT 固定源端口 + 静态 DNAT 入站**(full-cone),`topo_up` 已这么做。
3. **nebula 进程被 ssh 会话回收**:在 ssh 非交互会话里 `cmd &` 起的 nebula 会随子 shell
   退出被杀。`svp_start_nebula` 用 `setsid nohup` 脱离会话存活。
4. **`SIGUSR1` 在 1.10 无 hostmap 输出**:别用,改用控制 sshd `list-hostmap`。
5. **heredoc 吃管道**:`cmd | python3 - <<'PY'` 会把 heredoc 当 python 的 stdin,
   吃掉管道数据;改 `cmd | python3 -c "$SCRIPT" args`。

## 清理保证

`run.sh` 默认 `trap EXIT` 清理;只删自己建的(`svp-*` netns、`br-svpbb`、`svp*` veth、
带 `svp-sim-backbone` comment 的规则、按 `/root/sim-vps/cfg/` 精确匹配的 sim nebula 进程)。
**绝不触碰**生产 `nebula-lighthouse`(systemd,`-config /etc/nebula/`)与 `ss-server` 容器。
