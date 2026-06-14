# v2 一体化角色安装器

把 v2 自适应连接(Nebula T0/T1 + frp T2 + connd 三层阶梯)按【三个角色】一键装好、起好、开机自启。

```
中转中心(公网 VPS)   →  install-center.sh      lighthouse + frps
数据中心(私网节点)   →  install-datacenter.sh  nebula 10.77.0.2 + frpc + git 服务端
客户端(N 台)        →  install-client.sh      nebula + frpc visitor + connd(固定本地端点)
```

服务管理:Linux=systemd / macOS=launchd(均开机自启 + 崩溃重启)。二进制按平台从
GitHub Release 拉取 `connd-<os>-<arch>`(由 release.yml 产出),Release 不可达时回退本地
`go build`;nebula/frpc 取官方 release。

## 前置(操作机,一次性)

```bash
v2/nebula/gen-certs.sh                 # CA + lighthouse + datacenter
v2/nebula/gen-certs.sh sign datacenter # 确保数据中心证书(10.77.0.2)
cp v2/frp/secret.env.example v2/frp/secret.env   # 填三把随机口令(全网一致)
# VPS 安全组放行 UDP 4242(nebula)+ TCP 7000(frps)
```

## 三步部署

```bash
# 1) 中转中心(本机经 ssh 推到 VPS)
bash v2/install/install-center.sh root@<VPS公网IP>

# 2) 数据中心(在数据中心节点上跑,需 docker;Linux)
bash v2/install/install-datacenter.sh <VPS公网IP>

# 3) 每台客户端:操作机签发接入包 → 拷到客户端 → 安装
v2/deploy/enroll-client.sh alice <VPS公网IP>          # 产出 v2/deploy/dist/alice/
scp -r v2/deploy/dist/alice  client-host:~/alice       # 拷到客户端
# 客户端机上:
sudo bash v2/install/install-client.sh ~/alice ~/SharedWork   # 第2参可选:同步共享目录
```

装完后:**客户端的 shared-sync 引擎(GUI 或 `sync_cli`)`server_url` 永远填
`http://127.0.0.1:8418/shared.git`**;connd 在底下自动选 T0/T1/T2 并升降级,引擎无感知。

## 运维

```bash
bash v2/install/install-center.sh     --status root@<VPS>
bash v2/install/install-datacenter.sh --status
bash v2/install/install-client.sh     --status        # 含 connd 当前层(T0/T1/T2)
... --uninstall                                        # 各角色移除服务(证书/配置保留)
```

## 验证状态(诚实说明)

- ✅ **机械核心**(本会话实测,macOS/arm64):配置渲染占位全替换;nebula(darwin universal zip)
  /frpc/connd 三个二进制按平台获取且可执行;脚本 `bash -n` 全过。
- ✅ **接线正确性**:安装器装的 nebula+frpc+connd 三件套接线,与 `v2/deploy/star-e2e.sh`
  真机验证(真连 VPS,2 客户端 + 1 数据中心,三层升降级 PASS=14)完全一致——安装器只是
  把同一套接线包成 systemd/launchd 服务。
- ⏳ **systemd/launchd 服务层端到端冒烟**:需在真实第二个 NAT 站点(独立 Linux/macOS 节点)
  上跑一次完整 install-client + install-datacenter。当前只有 Mac + 单台 VPS(同主机 hairpin
  无法让 nebula 在 VPS 上以客户端/数据中心角色对自己的 lighthouse 收敛),故该端到端冒烟留待
  有第二真实站点时执行。

## Windows 客户端

connd / frpc / nebula 均有 Windows 二进制(Release 提供 `connd-windows-amd64.exe`)。
Windows 服务化建议用 NSSM 把 `connd run -config connd.yaml` 注册为服务(类比
`client/daemon/README.md` 的 Windows 章节);本目录脚本暂只覆盖 Linux/macOS。
