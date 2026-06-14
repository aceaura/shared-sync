# v2 Phase1 — 真实 VPS 部署与验证

把 Nebula lighthouse+relay 部署到一台公网 VPS,验证私网节点经它建立 overlay、shared-sync
跑在 overlay 上(不暴露公网)。

## 部署

```bash
# 1) 生成证书(一次性;ca.key 离线保管)
v2/nebula/gen-certs.sh

# 2) 部署 lighthouse 到公网 VPS(需先放行安全组 UDP 4242)
v2/deploy/deploy-lighthouse.sh root@<VPS公网IP>

# 3) 在各私网节点拉起 nebula 节点(开发期用容器;生产由 connd 原生管理)
v2/deploy/run-node.sh home    <VPS公网IP>
v2/deploy/run-node.sh company <VPS公网IP>

# 4) 验证 overlay 连通
docker exec nb-home ping -c3 10.77.0.1     # → lighthouse
```

## 已验证结果(2026-06-14,真机)

VPS:AWS Amazon Linux 2023(us-east-1),公网 `54.198.93.78`,SG 放行 UDP 4242。
节点:Mac(家庭 NAT + Docker NAT 双层后)以容器跑 node-home。

| 验证项 | 结果 |
|---|---|
| lighthouse 部署(systemd,开机自启) | ✅ overlay `10.77.0.1` up、监听 udp 4242 |
| Mac 穿真 NAT 接入(握手) | ✅ `Handshake message received certName=lighthouse from 54.198.93.78:4242` |
| Mac → lighthouse overlay ping | ✅ 0% 丢包,RTT ~310ms(真实跨网到 AWS) |
| shared-sync 经真 overlay | ✅ Mac 容器 clone→commit→push→回读 git server(`10.77.0.1:8418`)全通 |
| git server 不暴露公网 | ✅ 公网 `54.198.93.78:8418` 不可达(curl rc=52);仅 overlay 内 `git ls-remote` 可达 |

> git server 用 `-p 10.77.0.1:8418:80` 仅绑 overlay IP,加上 SG 只开 4242,双重保证不暴露公网。
> 本验证里 git server 临时跑在 lighthouse 节点上仅为测试传输;架构上它应跑在某个私网节点。

## 尚未验证(诚实说明)

- **两个独立 NAT 之间的 direct 打洞**:需要两个真实的不同网络位置。目前只有 Mac(家庭 NAT)
  + 一台公网 VPS;把第二个节点放在 VPS 同主机会遇到 hairpin/同主机回环,不构成有效的两 NAT 拓扑。
  因此"打洞建立 direct""direct⇄relay 自动切回"仍待:(a) 第二个真实 NAT 站点,或
  (b) 在这台真 Linux VPS 上用 netns+iptables 搭可控 NAT 类型的双节点(real Linux 的 conntrack
  能让 direct 收敛,区别于 Phase0 在 Docker Desktop/LinuxKit 下的失败)。
- **connd 接管**:当前节点由容器手动拉起;connd 的 direct/relay 精确探测(解析 nebula hostmap)
  与状态机联动尚未接到真 nebula 上。

## 清理

```bash
docker rm -f nb-home nb-company                      # 本机节点容器
ssh root@<VPS公网IP> 'systemctl disable --now nebula-lighthouse; docker rm -f ss-server'
```

---

# Phase4 — N 客户端接入工具 + 星型多客户端联调

星型拓扑(DESIGN_v2 §1/§3/§7):1 VPS 中转中心 + 1 数据中心 + N 客户端,客户端互不通信,
都只与数据中心同步。**新增一台客户端 = 跑一次 `enroll-client.sh`,不动其他节点。**

## 角色化 IP 规划

| 角色 | overlay IP | 说明 |
|---|---|---|
| lighthouse | `10.77.0.1` | VPS 公网中转(打洞协调 + UDP/TCP 中继) |
| **datacenter** | `10.77.0.2` | 唯一同步数据中心(git 权威 `current` 分支) |
| client-<名字> | `10.77.0.11+` | N 个客户端,签证时自动分配空闲 IP |

## 1) 签发证书(`v2/nebula/gen-certs.sh`,幂等)

```bash
v2/nebula/gen-certs.sh                          # 批量基线:CA + lighthouse + datacenter(+旧名兼容)
v2/nebula/gen-certs.sh sign datacenter          # 单签数据中心(10.77.0.2)
v2/nebula/gen-certs.sh sign client-alice         # 自动分配 10.77.0.11+
v2/nebula/gen-certs.sh sign client-bob 10.77.0.12 # 或显式指定 IP
v2/nebula/gen-certs.sh list                      # 列出已签节点 + overlay IP
```

私钥只落 `v2/nebula/certs/`(已 gitignore)。

## 2) 接入一台新客户端(`v2/deploy/enroll-client.sh`)

```bash
# 前置:v2/frp/secret.env(从 secret.env.example 复制,填 frps 端到端口令)
v2/deploy/enroll-client.sh alice 54.198.93.78    # 第 3 参可选:数据中心 overlay,默认 10.77.0.2
```

产出 **可直接跑的客户端配置包** `v2/deploy/dist/alice/`:

- `node.yml` — nebula 节点(连真 lighthouse,撑 T0/T1)
- `frpc-visitor.toml` — frpc STCP visitor(本地 `127.0.0.1:18418` = connd `t2BackendAddr`)
- `connd.yaml` — 三层阶梯 + 固定本地端点 `127.0.0.1:8418`(引擎 `server_url` 永远指它)
- `ca.crt` / `client-alice.crt|.key` / `ctl_key*` / `sshd_hostkey*`
- `README.md` / `MANIFEST.txt`

把目录拷到目标机(挂到 `/etc/nebula` 与 `/etc/frp`),按包内 README 起三件套即可。
`dist/` 含私钥,已 gitignore。

## 3) 星型联调验证(`v2/deploy/star-e2e.sh`,真连真 VPS)

```bash
bash v2/deploy/star-e2e.sh                 # 1 数据中心 + 2 客户端(alice/bob),真连真 VPS
FREEZE_UDP=1 bash v2/deploy/star-e2e.sh    # 额外验证「封一个客户端 UDP→只它降级 T2,另一个不受影响」
KEEP=1 ... / bash star-e2e.sh --cleanup    # 保留容器排查 / 仅清理本机容器与网络
```

客户端配置由 `enroll-client.sh` 真实产出并直接挂载,验证接入工具产物可直接跑。

## 已验证结果(2026-06-14,真机,`FREEZE_UDP=1` → PASS=14 FAIL=0)

| 验证项 | 结果 |
|---|---|
| N→1 星型:两客户端各经【各自本地端点】git ls-remote 同一数据中心 | ✅ alice/bob 均列到 `67b13d3 HEAD / refs/heads/current` |
| 稳态层 | ✅ alice/bob 均 `tier=T1`(overlay UDP relay)`upstream=10.77.0.2:80`;Docker 下 T0 直连不收敛 |
| 共享中转:alice push 文件 → bob clone 看到 | ✅ bob 全新 clone 工作树含 `from-alice-<ts>.txt`;pull 读到 `hello from alice @ <ts>` |
| 隧道独立:封 alice UDP → 只 alice 降级 | ✅ alice `tier=T2`(frp TCP,git 仍通);同刻 bob 仍 `tier=T1` git 仍通 |
| alice UDP 恢复后升回 | ✅ 滞后窗口后 alice 升回 `tier=T1` |
| VPS 生产组件未动 | ✅ nebula-lighthouse / frps / ss-server 全程 `active`,跑完清理本机容器/网络 |

> 跑完自动清理本机容器(ss-dc / ss-alice / ss-bob)与网络 starnet;VPS 上的 systemd 服务只读复用、不停。
