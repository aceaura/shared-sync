# v2/nebula — Nebula 配置骨架(打洞优先 / 中继兜底)

shared-sync v2.0 用 [Nebula](https://github.com/slackhq/nebula) 作为 overlay 数据面:
借一台公网 VPS(lighthouse)协助两个 NAT 后的私网做 **UDP 打洞建立直连 P2P**(主路径),
打不通时经 lighthouse **relay 中继兜底**(备用路径),恢复后自动切回直连。

这正是 [`DESIGN_v2.md`](../../DESIGN_v2.md) 里「兜底优先、直连为升级」的天然映射:
Nebula 启动即可经 relay 立刻互通,后台持续打洞,直连一旦稳定就自动优先走直连(低延迟/高带宽)。
overlay 虚拟 IP 全程不变,路径切换对 shared-sync 引擎透明。

> 本目录只提供 **证书体系 + 配置模板**(Phase 0 骨架)。connd(Go sidecar)负责渲染模板、
> 拉起 nebula 进程、跑健康探测与状态机 —— 见 `v2/connd/`。

---

## 1. 目录结构

```
v2/nebula/
├── gen-certs.sh          # 生成 CA + 三套节点证书(用容器内 nebula-cert,本机无需装 nebula)
├── certs/                # 产物(*.key 已被根 .gitignore 忽略,绝不入库)
│   ├── ca.crt  ca.key
│   ├── lighthouse.crt/.key
│   ├── node-home.crt/.key
│   └── node-company.crt/.key
├── config/
│   ├── lighthouse.yml    # 公网 VPS:打洞协调点 + relay 中继
│   └── node.yml.tmpl     # 普通节点模板(含占位符,部署时渲染)
└── README.md
```

## 2. overlay 网段与节点

| 节点          | overlay IP   | 角色                                   |
| ------------- | ------------ | -------------------------------------- |
| lighthouse    | `10.77.0.1`  | 公网 VPS:rendezvous(打洞协调)+ relay 中继 |
| node-home     | `10.77.0.2`  | 家用 PC(NAT 后)                        |
| node-company  | `10.77.0.3`  | 公司 PC(NAT 后)                        |

网段固定 `10.77.0.0/24`。overlay IP 写进证书(`-networks <ip>/24`),
主备两条路径共用同一 IP —— 这是「切换对上层透明」的根本。

---

## 3. 生成证书

```bash
bash v2/nebula/gen-certs.sh           # 幂等:已存在的证书会跳过
FORCE=1 bash v2/nebula/gen-certs.sh   # 强制重建全部
```

要点:

- **不要求本机安装 nebula**。脚本用官方镜像 `nebulaoss/nebula` 里的 `nebula-cert`
  (该镜像是 distroless 风格、无 shell,二进制在 `/nebula-cert`,故用 `--entrypoint /nebula-cert`)。
- 产物写到 `certs/`。脚本末尾会 `nebula-cert print` + `verify` 自检,确认每个节点证书
  确由本 CA 签发、overlay IP 正确、cert format v2。
- 证书有效期可调:`CA_DURATION`(默认 10 年)、`NODE_DURATION`(默认 5 年)。

### 私钥安全

`certs/*.key` 与 `ca.key` 是私钥,**已在根 `.gitignore` 忽略**:

```
v2/nebula/certs/*.key
v2/nebula/certs/ca.key
```

`ca.key` 一旦泄露,任何人都能签发能入网的证书 —— 切勿提交、切勿外发。
生产环境建议把 `ca.key` 离线保管,只在签发时临时取用。

---

## 4. 配置模板用法

### lighthouse.yml(公网 VPS,直接可用)

部署时把 `ca.crt / lighthouse.crt / lighthouse.key` 放到 VPS 的 `/etc/nebula/`,
配置里的 `pki` 路径已指向那里。VPS 需放行入站 **UDP 4242**。

### node.yml.tmpl(普通节点,需渲染)

模板含三个占位符,connd / 部署脚本渲染时替换:

| 占位符              | 含义                          | 示例              |
| ------------------- | ----------------------------- | ----------------- |
| `__NODE_CERT__`     | 节点证书文件名                | `node-home.crt`   |
| `__NODE_KEY__`      | 节点私钥文件名                | `node-home.key`   |
| `__LIGHTHOUSE_IP__` | lighthouse 的【公网】IP/域名  | `203.0.113.10`    |

> `__LIGHTHOUSE_IP__` 是 VPS 的**真实公网地址**(用于 `static_host_map` 首次找到 lighthouse),
> **不是** overlay IP。overlay IP `10.77.0.1` 已硬编码在模板里(lighthouse.hosts / relays / static_host_map 左值)。

手动渲染示例:

```bash
sed -e 's/__NODE_CERT__/node-home.crt/' \
    -e 's/__NODE_KEY__/node-home.key/' \
    -e 's/__LIGHTHOUSE_IP__/203.0.113.10/' \
    v2/nebula/config/node.yml.tmpl > /etc/nebula/config.yml
```

---

## 5. 关键字段解读(打洞优先 / 中继兜底如何对应)

字段名以 nebula v1.10.x 官方 example 为准,均已通过 `nebula -test` 校验。

### `static_host_map`(节点如何首次找到 lighthouse)
```yaml
static_host_map:
  "10.77.0.1": ["203.0.113.10:4242"]   # overlay IP -> 公网 endpoint
```
唯一的静态信息;其余 peer 的地址都由 lighthouse 动态发现。

### `lighthouse`(rendezvous / 发现)
- lighthouse 节点:`am_lighthouse: true` —— 它收集各节点上报的公网映射,
  帮两端交换地址做打洞(**牵线不转发数据**)。
- 普通节点:`am_lighthouse: false`,`hosts: ["10.77.0.1"]` —— 向该 lighthouse 注册并发现 peer。

### `punchy`(主路径 = 打洞直连优先)
```yaml
punchy:
  punch: true        # 主动发 UDP 打洞包,在 NAT 上打出映射,争取直连 P2P
  respond: true      # 收到对端探测时回应,提升双向打洞成功率
```
对应设计 §2.2:`punch` 让直连尽快建立;直连一旦打通,Nebula 自动优先走直连。

### `relay`(备用路径 = 中继兜底)
- lighthouse:`am_relay: true` —— 本节点【充当】中继,为打不通的两端转发**加密包**
  (VPS 读不到 git 明文,端到端密钥不在 VPS)。
- 普通节点:`use_relays: true` + `relays: ["10.77.0.1"]` —— 打不通直连时,经 lighthouse 中继。
  这保证连接全程不中断:打洞成功前/失败时先走 relay,成功后自动升级到直连。

### `firewall`(overlay 内流量,非主机物理网卡)
默认 `inbound/outbound_action: drop`,显式放行:
- **ICMP** —— connd 健康探测 / 连通性诊断(心跳、RTT)。
- **tcp 8418** —— shared-sync 同步服务端口(`server_url=http://<overlay-ip>:8418`)。
  仅普通节点放行;lighthouse 不跑 shared-sync,只放行 icmp。

---

## 6. 校验(已实测)

```bash
# 校验某个配置文件的语法/字段(容器内 nebula -test,不真正起网)
docker run --rm -v /etc/nebula:/etc/nebula \
  --entrypoint /nebula nebulaoss/nebula:latest \
  -test -config /etc/nebula/config.yml
```

退出码 0 即配置有效。镜像版本:**Nebula 1.10.3**,cert format **v2**。

---

## 7. 部署形态(后续阶段,非本骨架范围)

实际跑 nebula 需要内核 TUN 设备与 `NET_ADMIN` 权限。容器内运行需:
`--cap-add NET_ADMIN --device /dev/net/tun`,Linux 主机直跑则需 root / setcap。
connd 负责进程生命周期、健康探测与 DIRECT⇄FALLBACK 状态机 —— 见 `v2/connd/`。
