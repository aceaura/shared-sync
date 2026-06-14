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
