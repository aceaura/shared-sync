# v2/frp —— T2 终极兜底层(frp STCP TCP 隧道)

`T2` 是三层路径阶梯(DESIGN_v2 §4)的**最后一层**:当 UDP 被完全封死(对称 NAT 极端、
企业防火墙只放行 TCP、运营商封 UDP),Nebula 的 T0(直连)/ T1(UDP 中继)全部 DOWN 时,
仍能让客户端经一条纯 TCP 隧道抵达数据中心 git。本目录提供这条隧道的全部部署件。

技术选型:**frp 的 STCP(secret TCP)模式**。数据中心**不在 VPS 公网暴露任何业务端口**,
只有持同一 `secretKey` 的客户端 visitor 经 VPS 中继(frps)撮合后,才能建立到数据中心 git
的端到端隧道;VPS frps **只转发加密的 STCP 流量,读不到 git 明文**。

```
  层  传输            经 VPS?  本目录负责
  ───────────────────────────────────────────────────
  T0  Nebula UDP 直连  否       (v2/nebula)
  T1  Nebula UDP 中继  是       (v2/nebula + VPS lighthouse/relay)
  T2  frp STCP TCP     是       ← 本目录
```

## 拓扑与数据流

```text
                       公网 VPS 54.198.93.78
              ┌────────────────────────────────────────┐
              │ nebula-lighthouse(systemd,生产,只读复用)│  ← T0/T1 协调+中继
              │ frps(systemd,bindPort 7000)             │  ← T2 STCP 撮合中继
              └───────▲────────────────────────▲────────┘
       出站 TCP 7000  │                        │  出站 TCP 7000
        (STCP visitor)│                        │  (STCP 服务端注册)
   ┌──────────────────┴───┐          ┌─────────┴──────────────────┐
   │  客户端节点            │          │  数据中心节点                │
   │  connd                │          │  git server(8418/容器内80)  │
   │   ├─ nebula node-home │          │  nebula node-company         │
   │   │   (10.77.0.2)     │          │   (10.77.0.3)                │
   │   ├─ 固定端点          │          │  frpc(STCP【服务端】)        │
   │   │  127.0.0.1:8418   │          │   name=ss-git → 本机 git     │
   │   └─ t2BackendAddr ───┼──┐       └──────────────────────────────┘
   │  frpc(STCP visitor)   │  │
   │   bindAddr 127.0.0.1  │  │  引擎只连固定端点 127.0.0.1:8418;
   │   bindPort 18418 ◄────┼──┘  connd 切到 T2 时把上游换成 t2BackendAddr=127.0.0.1:18418
   └───────────────────────┘
```

T2 激活时的字节流:

```
引擎 ──► connd 代理 127.0.0.1:8418 ──(切到 T2)──► 客户端 frpc visitor 127.0.0.1:18418
     ──TCP──► VPS frps:7000 ──STCP 撮合──► 数据中心 frpc ──► 数据中心 git
```

引擎的 `server_url` 永远是 `http://127.0.0.1:8418/shared.git`,对走哪一层零感知
(DESIGN_v2 §2.1)。connd 切层只是把这个固定端点的上游在 overlay 后端 ↔ visitor 本地口
之间原子切换。

## 文件清单

| 文件 | 角色 | 跑在哪 |
| --- | --- | --- |
| `config/frps.toml` | frp 中继服务器配置(bindPort 7000) | **VPS** |
| `frps.service` | frps systemd 单元 | **VPS** |
| `deploy-frps.sh` | 把 frps 部署到 VPS(下二进制+渲染配置+systemd) | 本机→VPS |
| `config/frpc-datacenter.toml` | 数据中心 frpc(STCP **服务端**),把 git 注册给中继 | 数据中心 |
| `config/frpc-visitor.toml.tmpl` | 客户端 frpc(STCP **visitor**)模板,本地开 `t2BackendAddr` | 客户端 |
| `config/node-datacenter.yml.tmpl` | 数据中心 nebula 节点配置(node-company=10.77.0.3) | 数据中心 |
| `secret.env.example` | 口令/密钥示例(复制成 `secret.env`,gitignored) | 本机 |
| `run-e2e.sh` | 一键端到端三态验证(真连真 VPS) | 本机 |
| `Dockerfile.datacenter` / `datacenter-entrypoint.sh` | e2e 数据中心容器(git+nebula+frpc) | 本机 |
| `Dockerfile.client` / `client-entrypoint.sh` | e2e 客户端容器(connd+nebula+frpc visitor) | 本机 |

## STCP secret 模型(三个独立密钥,务必区分)

1. **`FRP_AUTH_TOKEN`**(`auth.token`):frpc(数据中心/客户端)接入 frps 的**接入口令**。
   三方(frps / 数据中心 frpc / 客户端 frpc)必须同值。控制谁能连上中继。
2. **`FRP_STCP_SECRET`**(`secretKey`):STCP 的**端到端密钥**。只有数据中心 frpc(服务端)
   与客户端 frpc(visitor)持有;**frps 不持有**,故 VPS 撮合时读不到隧道内 git 流量。
   这是「不在 VPS 公网暴露数据中心」的安全基石。
3. **`FRP_DASHBOARD_PWD`**:frps 本地 dashboard(仅回环 127.0.0.1:7500)口令,运维观测用。

`secret.env`(gitignored)集中存这三个值;`deploy-frps.sh` 与 `run-e2e.sh` 都读它,
渲染时替换配置里的 `__FRP_*__` 占位符。**私钥/secret 绝不入库**(见根 `.gitignore`)。

```bash
cp v2/frp/secret.env.example v2/frp/secret.env
# 填随机值:
#   FRP_AUTH_TOKEN=$(openssl rand -hex 24)
#   FRP_STCP_SECRET=$(openssl rand -hex 24)
#   FRP_DASHBOARD_PWD=$(openssl rand -hex 12)
#   FRP_SERVER_ADDR=<VPS 公网 IP>
```

## 端口约定(避开生产端口)

VPS 既有:UDP/TCP `4242`(nebula)、TCP `8418`(ss-server,绑 `10.77.0.1`)、`22`(ssh)。
frps 只新增:

- TCP `7000` —— frps `bindPort`,客户端/数据中心 frpc 出站连它(STCP 撮合)。
- TCP `7500` —— frps dashboard,**仅回环**,经 ssh 隧道查看,不对公网开。

STCP **不在 VPS 上开 remotePort**,故 VPS 公网只多暴露 `7000` 这一个撮合口;
`frps.toml` 的 `allowPorts = [{start=0,end=0}]` 进一步禁止任何 frpc 申请打开 VPS 公网端口
(纵深防御)。

## 部署 frps 到 VPS

```bash
bash v2/frp/deploy-frps.sh              # 部署到 secret.env 里的 FRP_SERVER_ADDR
bash v2/frp/deploy-frps.sh --status     # 查看 VPS frps 状态/日志
bash v2/frp/deploy-frps.sh --uninstall  # 停止移除 frps(不动 nebula-lighthouse/ss-server)
```

脚本自动探测 VPS 架构选 frp 二进制、渲染注入 secret、装 systemd 单元常驻、并校验
未触碰生产组件(nebula-lighthouse/ss-server)。frps 是 v2 部署的一部分,**可常驻**。

## 数据中心 frpc 怎么起(Phase4/5 接入点)

数据中心节点上需要:(a) shared-sync git server(v1 那套);(b) nebula 节点
(node-company=10.77.0.3,撑 T0/T1);(c) frpc STCP 服务端(撑 T2)。frpc 配置由
`frpc-datacenter.toml` 渲染:

```bash
sed -e "s#__FRP_SERVER_ADDR__#<VPS_IP>#" \
    -e "s#__FRP_AUTH_TOKEN__#<token>#" \
    -e "s#__FRP_STCP_SECRET__#<secret>#" \
    -e "s#__GIT_LOCAL_ADDR__#127.0.0.1#" \
    -e "s#__GIT_LOCAL_PORT__#8418#" \
    config/frpc-datacenter.toml > /etc/frp/frpc.toml
frpc -c /etc/frp/frpc.toml      # 后台/systemd 常驻
```

frpc 启动后 frps 日志出现 `start proxy success`,即数据中心 git 已注册到中继,
等待 visitor 撮合。

## 客户端 frpc visitor + connd 接入

客户端 visitor 配置由模板 `frpc-visitor.toml.tmpl` 渲染。`bindAddr:bindPort` 这个本地口
**就是 connd 的 `t2BackendAddr`**:

```bash
sed -e "s#__FRP_SERVER_ADDR__#<VPS_IP>#" \
    -e "s#__FRP_AUTH_TOKEN__#<token>#" \
    -e "s#__FRP_STCP_SECRET__#<secret>#" \
    -e "s#__VISITOR_BIND_ADDR__#127.0.0.1#" \
    -e "s#__VISITOR_PORT__#18418#" \
    config/frpc-visitor.toml.tmpl > /etc/frp/frpc-visitor.toml
frpc -c /etc/frp/frpc-visitor.toml      # sidecar 常驻
```

connd 侧**无需改逻辑**,只在 connd 配置填一行:

```yaml
t2BackendAddr: 127.0.0.1:18418     # = visitor 本地口;空则 T2 恒 DOWN
```

connd 自动:
- `controller.upstreamOf(TierTCPRelay)` 把 T2 代理上游指向 `t2BackendAddr`;
- 用 `tierprobe.NewTCPHeartbeat(t2BackendAddr)` 对它做 T2 健康探测;
- 阶梯状态机把 T2 纳入升降级调度(UDP 全挂 → 降到 T2;UDP 恢复 → 升回 T1/T0)。

### frpc 由谁管:sidecar vs connd 子进程

Phase3 e2e 里 **frpc 作 sidecar 常驻**(`client-entrypoint.sh` 先起 frpc 再起 connd),
理由:解耦,便于在 e2e 里单独对 frpc / UDP 做故障注入,且选「能稳定跑通」的方式。
connd 已为「由 connd 启停 frpc 子进程」留了清晰接口(配置只认 `t2BackendAddr` 这个
本地口,不关心谁起的 frpc),生产可二选一:
- **sidecar**(本 e2e 方式):frpc 由 systemd/launchd 与 connd 平级常驻;
- **connd 托管**:由 connd 像管 nebula 子进程那样 fork/监督 frpc(后续可加,接口不变)。

## 一键端到端三态验证

```bash
bash v2/frp/run-e2e.sh           # 跑三态,结束清理本机容器/网络(不动 VPS frps/nebula/ss-server)
KEEP=1 bash v2/frp/run-e2e.sh    # 跑完保留容器供排查
bash v2/frp/run-e2e.sh --cleanup # 仅清理本机容器/网络
```

拓扑:本机两容器(数据中心 `ss-dc` + 客户端 `ss-cli`)都连真 VPS(lighthouse + frps)。
三态:

1. **正常态**:overlay 直达,connd=T0/T1,git 经本地端点通。
2. **封死 UDP**:客户端容器内 `iptables -A OUTPUT -p udp -j DROP` → nebula 全 DOWN →
   connd 自动降级 **T2(viaVps=true)**,git 经**同一本地端点**走 frp TCP 隧道仍成功。
   (核心证明:此刻 overlay 直达已断,本地端点 git 仍通。)
3. **恢复 UDP**:解除 DROP → 滞后窗口后升级回 T1/T0,git 仍通。

实测结果见 `DESIGN_v2.md §10 Phase3`。

## 纪律 / 清理

- **绝不触碰** VPS 上的 `nebula-lighthouse`(systemd)与 `ss-server` 容器 —— 生产组件。
  frps 是 v2 部署的一部分,可常驻;临时测试容器(`ss-dc`/`ss-cli`)与本机规则用完即清。
- 客户端 e2e 容器以 `--cap-add NET_ADMIN` 跑,可在容器内 iptables 注入/解除 UDP 封锁;
  规则随容器销毁而消失,不影响宿主。
- `secret.env` 与 frp 二进制(运行期下载)均已 gitignored。
```
