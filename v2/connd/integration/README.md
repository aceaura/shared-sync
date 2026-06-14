# connd Phase2 真机集成验证

在本机用 Docker 跑一个 Linux 容器,容器里 connd 管理**真 nebula** 子进程连**真
lighthouse**(默认 54.198.93.78),起固定本地端点代理,经 overlay 访问数据中心,
对「三层判定 + 本地代理转发」做端到端实跑。

> 为什么用容器:connd 要管理 nebula 进程并需要 TUN/NET_ADMIN;macOS 上 nebula 要
> root 且不便起 TUN。容器 `--cap-add NET_ADMIN --device /dev/net/tun` 即可在 Linux
> 内核里起 overlay,且能真连到公网 lighthouse。

## 拓扑(Phase2)

```text
  Mac(本机,穿真家庭/办公 NAT)
   └─ Docker 容器 connd-p2  (--cap-add NET_ADMIN --device /dev/net/tun)
        ├─ connd run
        │   ├─ 管理 nebula 子进程(node-home 证书,overlay 10.77.0.2)
        │   │     └─ 连真 lighthouse 54.198.93.78:4242(static_host_map)
        │   ├─ 控制 sshd 127.0.0.1:2222 → list-hostmap -json 判 T0/T1
        │   └─ 固定本地端点代理 127.0.0.1:8418 → 当前层数据中心后端
        └─ git ls-remote http://127.0.0.1:8418/shared.git
                                  │
        经 overlay ──────────────►│
                                  ▼
   真 VPS 54.198.93.78  overlay 10.77.0.1
     ├─ nebula-lighthouse(systemd,am_lighthouse+am_relay)
     └─ ss-server 容器(shared-sync git server)绑 10.77.0.1:8418
        —— Phase2 以 lighthouse 节点充当「数据中心 peer」(peer=10.77.0.1)
```

## 用法

```bash
bash run-integration.sh              # 跑全部断言并自动清理容器
KEEP=1 bash run-integration.sh       # 跑完保留容器(docker exec -it connd-p2 bash 进去排查)
bash run-integration.sh --cleanup    # 仅清理容器
```

可调环境变量:`LH_IP`(lighthouse 公网 IP)、`DC_OVERLAY`(数据中心 peer overlay,默认
`10.77.0.1`)、`DC_PORT`(默认 `8418`)、`CONTAINER`/`IMAGE` 名。

依赖:`docker` + `go`(交叉编译 connd linux 二进制)+ `ssh-keygen`。证书需先用
`v2/nebula/gen-certs.sh` 生成(用 node-home=10.77.0.2 证书)。

## 脚本做了什么

1. 生成 connd 控制 ssh 密钥对 + nebula sshd hostkey。
2. 渲染 `node.yml`(含 sshd 控制块,填入控制公钥)。
3. 写 connd 配置(连数据中心 `DC_OVERLAY:DC_PORT`,control.enabled=true)。
4. `GOOS=linux go build` 出 connd 二进制,打进 `Dockerfile.connd` 镜像(nebula+ssh+git)。
5. `docker run --cap-add NET_ADMIN --device /dev/net/tun` 起容器跑 `connd run`。
6. 等 overlay 起 + ping 数据中心通,然后断言:
   - overlay = `10.77.0.2`;
   - ping 数据中心通;
   - `connd status` 当前层为 T0/T1(已建链,非 RECONNECTING);
   - `git ls-remote http://127.0.0.1:8418/shared.git` 经本地端点成功(看到 HEAD/refs)。

## 实测(2026-06-14)

```text
overlay=10.77.0.2/24  数据中心可达=yes
PASS: connd 起的 nebula overlay = 10.77.0.2
PASS: overlay 内 ping 数据中心 10.77.0.1 通
PASS: connd status 当前层为 T0(currentRemote=54.198.93.78:4242,viaVps=false,T0/T1 UP)
PASS: git ls-remote 经本地端点成功(aeed015... HEAD / refs/heads/current)
PASS=4 FAIL=0
```

实测拿到的真机 hostmap(与 Phase1b handoff 一致):

```json
{ "vpnAddrs": ["10.77.0.1"], "remoteAddrs": ["54.198.93.78:4242"],
  "currentRemote": "54.198.93.78:4242", "currentRelaysToMe": [], "messageCounter": 33 }
```

T1 演示:把 connd 配置 `lighthouseUnderlay` 设为 `54.198.93.78`,同一链路的 `currentRemote`
(=lighthouse)即被判为 relay → `tier=T1, viaVps=true`;本地端点 git ls-remote 仍通。
这验证了 T0/T1 两个判定分支与代理在两层下的转发。

## 注意 / 清理

- 脚本默认跑完清理容器;`KEEP=1` 时持久工作目录在 `~/.shared-sync-v2/<容器名>/`,
  `--cleanup` 后可手动 `rm -rf`。
- **绝不触碰** VPS 上的 `nebula-lighthouse`(systemd)与 `ss-server` 容器 —— 它们是已验证
  的生产部署,本验证只读地复用其 lighthouse/relay 与 git server。
- 已知限制:Docker Desktop 的 LinuxKit NAT 对**节点间**直连打洞不收敛(Phase0 结论);
  但本验证里数据中心 peer 是 lighthouse(有公网固定端点,无需打洞),故 T0 判定正常。
  真正的「两 NAT 后节点」直连打洞已在 Phase1b 的真 Linux netns 验证过(`v2/sim-vps/`)。
```
