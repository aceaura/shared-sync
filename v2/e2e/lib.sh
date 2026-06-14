#!/usr/bin/env bash
# =============================================================================
# v2/e2e/lib.sh —— Phase5 完整三层阶梯 e2e 函数库(真 Linux netns,容器内自洽)
#
# 在【一个 --privileged Linux 容器】里用 ip netns + veth + iptables 搭一套【自洽】的
# 星型 v2 世界,驱动【真 connd】走完整三层阶梯,并按 NAT 类型 / UDP 封锁断言逐级升降级:
#
#   backbone bridge br-e2ebb(100.66.0.0/24,模拟"公网")
#    ├─ ns e2e-pub : lighthouse(am_lighthouse + am_relay,overlay 10.99.0.1)
#    │               + frps(bindPort 7000)  ← T2 STCP 撮合点(自洽,不连真 VPS)
#    ├─ ns e2e-rd  : 数据中心路由器(full-cone NAT,固定)— 让 DC 打洞友好(DESIGN §7)
#    ├─ ns e2e-dc  : 数据中心 nebula(10.99.0.2)+ git http(8418)+ frpc STCP 服务端
#    ├─ ns e2e-rc  : 客户端路由器(NAT 类型【可切】:fullcone / symmetric / blockudp)← 被测变量
#    └─ ns e2e-cli : 客户端 nebula(10.99.0.11)+ 控制 sshd + frpc visitor + 【connd】
#                    connd 固定本地端点 127.0.0.1:8418;t2BackendAddr=127.0.0.1:18418
#
# 与生产 / sim-vps 完全隔离:
#   * 独立 overlay 网段 10.99.0.0/24(生产 10.77 / sim-vps 10.88)
#   * 独立 backbone 100.66.0.0/24、独立 tun e2eneb0、独立 netns 前缀 e2e-
#   * 独立 CA(在容器内 /work/certs 现签,不碰仓库 v2/nebula/certs)
#   * 自带 frps(容器内 netns),不连真 VPS frps;不动真 lighthouse/frps/ss-server
#
# NAT 类型(客户端路由器,被测核心):
#   fullcone  : 出站 SNAT 固定源端口(端点无关)+ 入站静态 DNAT → 打洞可成,connd → T0
#   symmetric : 普通 MASQUERADE(每目的不同源端口映射)→ 打洞必失败 → connd 落 T1
#   blockudp  : 在客户端路由器 DROP 所有 underlay UDP → nebula 全 DOWN → connd 落 T2
#
# 依赖(容器内):bash ip(iproute2) iptables conntrack python3 ssh ssh-keygen
#               nebula nebula-cert frpc frps git connd(均打进镜像)。
# =============================================================================
set -uo pipefail

# ---- 可调参数 ---------------------------------------------------------------
E2E_ROOT="${E2E_ROOT:-/work}"
E2E_OVERLAY_CIDR="${E2E_OVERLAY_CIDR:-10.99.0.0/24}"
E2E_BB="${E2E_BB:-100.66.0}"            # 模拟"公网"骨干 /24 前缀
E2E_PORT="${E2E_PORT:-4242}"           # nebula underlay UDP 端口
E2E_SSHD_PORT="${E2E_SSHD_PORT:-2222}" # 客户端 nebula 控制 sshd
E2E_GIT_PORT="${E2E_GIT_PORT:-8418}"   # 数据中心 git http 端口(overlay 直达 / frp 后端)
E2E_VISITOR_PORT="${E2E_VISITOR_PORT:-18418}" # 客户端 frpc visitor 本地口 = connd t2Backend
E2E_FRPS_PORT="${E2E_FRPS_PORT:-7000}"
E2E_PROXY_PORT="${E2E_PROXY_PORT:-8418}"      # connd 固定本地端点
E2E_STATUS_PORT="${E2E_STATUS_PORT:-4243}"
E2E_FRP_TOKEN="${E2E_FRP_TOKEN:-e2e-frp-token}"
E2E_FRP_SECRET="${E2E_FRP_SECRET:-e2e-stcp-secret}"

NEBULA="${NEBULA:-$(command -v nebula || echo /usr/local/bin/nebula)}"
NEBULA_CERT="${NEBULA_CERT:-$(command -v nebula-cert || echo /usr/local/bin/nebula-cert)}"
FRPC="${FRPC:-$(command -v frpc || echo /usr/local/bin/frpc)}"
FRPS="${FRPS:-$(command -v frps || echo /usr/local/bin/frps)}"
CONND="${CONND:-$(command -v connd || echo /usr/local/bin/connd)}"
CONNTRACK="${CONNTRACK:-$(command -v conntrack 2>/dev/null || ls /usr/sbin/conntrack /sbin/conntrack 2>/dev/null | head -1)}"

# ---- overlay / underlay 固定 IP 规划 ----------------------------------------
LH_OVL=10.99.0.1;  DC_OVL=10.99.0.2;  CLI_OVL=10.99.0.11
LH_BB="${E2E_BB}.1"                                   # lighthouse + frps backbone
RD_PUB="${E2E_BB}.20"; DC_PRIV=10.20.2.2; DC_GW=10.20.2.1; DC_NET=10.20.2.0/24
RC_PUB="${E2E_BB}.30"; CLI_PRIV=10.30.3.2; CLI_GW=10.30.3.1; CLI_NET=10.30.3.0/24

# netns 名(全 e2e- 前缀)
NS_PUB=e2e-pub; NS_RD=e2e-rd; NS_RC=e2e-rc; NS_DC=e2e-dc; NS_CLI=e2e-cli

ns()  { ip netns exec "$@"; }
log() { echo ">> $*"; }

# 控制通道:在客户端 netns 内对本地 nebula 控制 sshd 跑命令(connd 也走它判 T0/T1)。
ctl() {
  ns "$NS_CLI" ssh -i "${E2E_ROOT}/ssh/ctl_key" -p "${E2E_SSHD_PORT}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR ctl@127.0.0.1 "$@" 2>/dev/null
}

# peer_state <peer-overlay-ip>:从客户端看某 peer 是 DIRECT / RELAY / UNKNOWN。
# 解析 list-hostmap -json 的 currentRemote(与 sim-vps 同判据)。
E2E_PARSE_PY='
import sys, json
peer = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print("UNKNOWN no-hostmap"); sys.exit(0)
for h in data:
    if peer in h.get("vpnAddrs", []):
        cr  = h.get("currentRemote") or ""
        rtm = h.get("currentRelaysToMe") or []
        if cr:   print("DIRECT %s" % cr)
        elif rtm: print("RELAY %s" % ",".join(rtm))
        else:    print("UNKNOWN no-remote")
        sys.exit(0)
print("UNKNOWN peer-absent")
'
peer_state() { ctl list-hostmap -json | python3 -c "$E2E_PARSE_PY" "$1"; }

# =============================================================================
# 证书:独立 e2e CA + lighthouse / datacenter / client(overlay 10.99.0.0/24)。幂等。
# 直接用容器内 nebula-cert(无需 docker-in-docker)。
# =============================================================================
e2e_gen_certs() {
  local C="${E2E_ROOT}/certs"; mkdir -p "$C"
  if [[ ! -f "$C/ca.crt" ]]; then
    log "[cert] 签发 e2e CA(${E2E_OVERLAY_CIDR})"
    "$NEBULA_CERT" ca -name "shared-sync v2 e2e CA" -duration 8760h \
      -networks "${E2E_OVERLAY_CIDR}" -out-crt "$C/ca.crt" -out-key "$C/ca.key"
  fi
  local e n ip
  for e in lighthouse:${LH_OVL} datacenter:${DC_OVL} client:${CLI_OVL}; do
    n="${e%%:*}"; ip="${e##*:}"
    [[ -f "$C/$n.crt" ]] && continue
    log "[cert] 签发 $n -> $ip/24"
    "$NEBULA_CERT" sign -ca-crt "$C/ca.crt" -ca-key "$C/ca.key" -name "$n" \
      -networks "$ip/24" -duration 4380h -out-crt "$C/$n.crt" -out-key "$C/$n.key"
  done
  mkdir -p "${E2E_ROOT}/ssh"
  [[ -f "${E2E_ROOT}/ssh/ctl_key"      ]] || ssh-keygen -t ed25519 -N "" -q -f "${E2E_ROOT}/ssh/ctl_key"
  [[ -f "${E2E_ROOT}/ssh/sshd_hostkey" ]] || ssh-keygen -t ed25519 -N "" -q -f "${E2E_ROOT}/ssh/sshd_hostkey"
  chmod 600 "${E2E_ROOT}/ssh/ctl_key"
}

# =============================================================================
# 渲染配置:lighthouse / datacenter nebula / client nebula / frps / frpc(srv+visitor)/ connd
# =============================================================================
e2e_render_configs() {
  local C="${E2E_ROOT}/certs" CFG="${E2E_ROOT}/cfg"; mkdir -p "$CFG"
  local PUBKEY; PUBKEY="$(cat "${E2E_ROOT}/ssh/ctl_key.pub")"

  # ---- lighthouse(am_lighthouse + am_relay)---------------------------------
  cat > "$CFG/lighthouse.yml" <<YEOF
pki: {ca: $C/ca.crt, cert: $C/lighthouse.crt, key: $C/lighthouse.key}
static_host_map: {}
lighthouse: {am_lighthouse: true, serve_dns: false, hosts: []}
listen: {host: 0.0.0.0, port: ${E2E_PORT}}
punchy: {punch: true, respond: true}
relay: {am_relay: true, use_relays: false, relays: []}
tun: {disabled: false, dev: e2eneb0, mtu: 1300}
logging: {level: info, format: text}
firewall:
  outbound_action: drop
  inbound_action: drop
  conntrack: {tcp_timeout: 12m, udp_timeout: 3m, default_timeout: 10m}
  outbound: [{port: any, proto: any, host: any}]
  inbound:  [{port: any, proto: any, host: any}]
YEOF

  # ---- 数据中心 nebula(无控制 sshd;放行 overlay 内 git 端口 + icmp)--------
  cat > "$CFG/dc.yml" <<YEOF
pki: {ca: $C/ca.crt, cert: $C/datacenter.crt, key: $C/datacenter.key}
static_host_map:
  "${LH_OVL}": ["${LH_BB}:${E2E_PORT}"]
lighthouse: {am_lighthouse: false, serve_dns: false, hosts: ["${LH_OVL}"], interval: 10}
listen: {host: 0.0.0.0, port: ${E2E_PORT}}
punchy: {punch: true, respond: true, delay: 1s}
relay: {am_relay: false, use_relays: true, relays: ["${LH_OVL}"]}
tun: {disabled: false, dev: e2eneb0, mtu: 1300}
logging: {level: info, format: text}
firewall:
  outbound_action: drop
  inbound_action: drop
  conntrack: {tcp_timeout: 12m, udp_timeout: 3m, default_timeout: 10m}
  outbound: [{port: any, proto: any, host: any}]
  inbound:  [{port: any, proto: icmp, host: any}, {port: ${E2E_GIT_PORT}, proto: tcp, host: any}]
YEOF

  # ---- 客户端 nebula(含控制 sshd,供 connd / ctl 查 hostmap)----------------
  cat > "$CFG/cli.yml" <<YEOF
pki: {ca: $C/ca.crt, cert: $C/client.crt, key: $C/client.key}
static_host_map:
  "${LH_OVL}": ["${LH_BB}:${E2E_PORT}"]
lighthouse: {am_lighthouse: false, serve_dns: false, hosts: ["${LH_OVL}"], interval: 10}
listen: {host: 0.0.0.0, port: ${E2E_PORT}}
punchy: {punch: true, respond: true, delay: 1s}
relay: {am_relay: false, use_relays: true, relays: ["${LH_OVL}"]}
tun: {disabled: false, dev: e2eneb0, mtu: 1300}
logging: {level: info, format: text}
firewall:
  outbound_action: drop
  inbound_action: drop
  conntrack: {tcp_timeout: 12m, udp_timeout: 3m, default_timeout: 10m}
  outbound: [{port: any, proto: any, host: any}]
  inbound:  [{port: any, proto: icmp, host: any}, {port: ${E2E_GIT_PORT}, proto: tcp, host: any}]
sshd:
  enabled: true
  listen: 127.0.0.1:${E2E_SSHD_PORT}
  host_key: ${E2E_ROOT}/ssh/sshd_hostkey
  authorized_users:
    - user: ctl
      keys: ["${PUBKEY}"]
YEOF

  # ---- frps(自洽中继,跑在 lighthouse netns 的 backbone IP 上)--------------
  cat > "$CFG/frps.toml" <<YEOF
bindPort = ${E2E_FRPS_PORT}
auth.method = "token"
auth.token = "${E2E_FRP_TOKEN}"
log.to = "${E2E_ROOT}/run/frps.log"
log.level = "info"
transport.heartbeatTimeout = 90
allowPorts = [{ start = 0, end = 0 }]
YEOF

  # ---- frpc(数据中心 = STCP 服务端,把本地 git 注册给 frps)-----------------
  cat > "$CFG/frpc-dc.toml" <<YEOF
serverAddr = "${LH_BB}"
serverPort = ${E2E_FRPS_PORT}
auth.method = "token"
auth.token = "${E2E_FRP_TOKEN}"
# loginFailExit=false(顶层键,非 transport.*):frps 未就绪 / 抖动时持续重连而非退出。
loginFailExit = false
log.to = "${E2E_ROOT}/run/frpc-dc.log"
log.level = "info"
[[proxies]]
name = "e2e-git"
type = "stcp"
secretKey = "${E2E_FRP_SECRET}"
localIP = "127.0.0.1"
localPort = ${E2E_GIT_PORT}
YEOF

  # ---- frpc(客户端 = STCP visitor,本地 127.0.0.1:VISITOR_PORT = T2 后端)---
  cat > "$CFG/frpc-visitor.toml" <<YEOF
serverAddr = "${LH_BB}"
serverPort = ${E2E_FRPS_PORT}
auth.method = "token"
auth.token = "${E2E_FRP_TOKEN}"
# loginFailExit=false(顶层键,非 transport.*):frps 未就绪 / UDP 故障抖动时持续重连而非退出。
loginFailExit = false
log.to = "${E2E_ROOT}/run/frpc-visitor.log"
log.level = "info"
[[visitors]]
name = "e2e-git-visitor"
type = "stcp"
serverName = "e2e-git"
secretKey = "${E2E_FRP_SECRET}"
bindAddr = "127.0.0.1"
bindPort = ${E2E_VISITOR_PORT}
YEOF

  # ---- connd(被测主体):peer=DC overlay,t2Backend=本地 visitor 口 ---------
  # 探测/滞后参数压短,使 e2e 在分钟级内观察到逐级升降级。
  cat > "$CFG/connd.yaml" <<YEOF
peerOverlayIP: ${DC_OVL}
dataCenterPort: ${E2E_GIT_PORT}
localProxyAddr: 127.0.0.1:${E2E_PROXY_PORT}
t2BackendAddr: 127.0.0.1:${E2E_VISITOR_PORT}
lighthouseUnderlay: "${LH_BB}:${E2E_PORT}"
statusAddr: 127.0.0.1:${E2E_STATUS_PORT}
control:
  enabled: true
  host: 127.0.0.1
  port: ${E2E_SSHD_PORT}
  user: ctl
  keyPath: ${E2E_ROOT}/ssh/ctl_key
heartbeat: 3s
tUp: 8s
n: 3
p: 8s
probeTimeout: 2s
nebula:
  binPath: ${NEBULA}
  configPath: ${CFG}/cli.yml
  dryRun: false
YEOF
}

# =============================================================================
# topo_up —— 建 netns 星型拓扑(双 NAT;客户端 NAT 类型默认 fullcone,可后续切换)
# =============================================================================
topo_up() {
  log "[topo] 清理可能残留"
  topo_down >/dev/null 2>&1 || true

  log "[topo] 创建 namespaces"
  ip netns add "$NS_PUB"; ip netns add "$NS_RD"; ip netns add "$NS_RC"
  ip netns add "$NS_DC";  ip netns add "$NS_CLI"

  log "[topo] backbone bridge br-e2ebb(模拟公网)"
  ip link add br-e2ebb type bridge; ip link set br-e2ebb up

  _attach_bb() {  # $1=ns $2=host-if $3=peer-if $4=ip
    ip link add "$2" type veth peer name "$3"
    ip link set "$2" master br-e2ebb; ip link set "$2" up
    ip link set "$3" netns "$1"
    ns "$1" ip link set lo up; ns "$1" ip link set "$3" up
    ns "$1" ip addr add "$4/24" dev "$3"
  }
  _attach_bb "$NS_PUB" e2ebb-pubh e2ebb-pub "$LH_BB"
  _attach_bb "$NS_RD"  e2ebb-rdh  e2ebb-rd  "$RD_PUB"
  _attach_bb "$NS_RC"  e2ebb-rch  e2ebb-rc  "$RC_PUB"

  log "[topo] 私网段 DC: routerD ${DC_GW} <-> dc ${DC_PRIV}"
  ip link add e2eD-r type veth peer name e2eD-n
  ip link set e2eD-r netns "$NS_RD"; ip link set e2eD-n netns "$NS_DC"
  ns "$NS_RD" ip addr add "$DC_GW/24" dev e2eD-r; ns "$NS_RD" ip link set e2eD-r up
  ns "$NS_DC" ip link set lo up
  ns "$NS_DC" ip addr add "$DC_PRIV/24" dev e2eD-n; ns "$NS_DC" ip link set e2eD-n up
  ns "$NS_DC" ip route add default via "$DC_GW"

  log "[topo] 私网段 CLI: routerC ${CLI_GW} <-> client ${CLI_PRIV}"
  ip link add e2eC-r type veth peer name e2eC-n
  ip link set e2eC-r netns "$NS_RC"; ip link set e2eC-n netns "$NS_CLI"
  ns "$NS_RC" ip addr add "$CLI_GW/24" dev e2eC-r; ns "$NS_RC" ip link set e2eC-r up
  ns "$NS_CLI" ip link set lo up
  ns "$NS_CLI" ip addr add "$CLI_PRIV/24" dev e2eC-n; ns "$NS_CLI" ip link set e2eC-n up
  ns "$NS_CLI" ip route add default via "$CLI_GW"

  # 路由器基础:forwarding + 默认路由到 backbone(经 lighthouse netns 不需要,直接 backbone)
  for r in "$NS_RD" "$NS_RC"; do
    ns "$r" sysctl -q -w net.ipv4.ip_forward=1
    ns "$r" ip route add default via "$LH_BB" 2>/dev/null || true
  done

  # 数据中心路由器:固定 full-cone NAT(让 DC 打洞友好;DC 不是被测变量)
  _nat_fullcone "$NS_RD" "$RD_PUB" "$DC_PRIV" "$DC_NET" e2ebb-rd

  # 客户端路由器:默认先建 full-cone(场景 A 起点;B/C 用 set_client_nat 切换)
  E2E_CLI_NAT="fullcone"
  _nat_fullcone "$NS_RC" "$RC_PUB" "$CLI_PRIV" "$CLI_NET" e2ebb-rc

  # host root-ns 若开了 bridge-nf-call-iptables(装了 docker 常见),桥接帧过 FORWARD(常 DROP)。
  # 放行本 e2e backbone 桥转发(精确 comment,便于清理)。
  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    iptables -C DOCKER-USER -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT 2>/dev/null \
      || iptables -I DOCKER-USER 1 -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT
  else
    iptables -C FORWARD -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT 2>/dev/null \
      || iptables -I FORWARD 1 -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT
  fi
}

# full-cone NAT:出站 SNAT 固定源端口(端点无关源映射)+ 入站静态 DNAT(端点无关目的映射)。
_nat_fullcone() {  # $1=router-ns $2=pub $3=priv $4=net $5=pubif
  local r="$1" pub="$2" priv="$3" net="$4" pif="$5"
  # underlay UDP(4242):full-cone
  ns "$r" iptables -t nat -A POSTROUTING -s "$priv" -p udp --sport "${E2E_PORT}" -o "$pif" -j SNAT --to-source "${pub}:${E2E_PORT}"
  ns "$r" iptables -t nat -A PREROUTING -d "$pub" -p udp --dport "${E2E_PORT}" -i "$pif" -j DNAT --to-destination "${priv}:${E2E_PORT}"
  # 其它(icmp / tcp:frp / 非 4242 udp)普通 MASQUERADE,保证可达 backbone
  ns "$r" iptables -t nat -A POSTROUTING -s "$net" ! -p udp -o "$pif" -j MASQUERADE
  ns "$r" iptables -t nat -A POSTROUTING -s "$net" -p udp ! --sport "${E2E_PORT}" -o "$pif" -j MASQUERADE
}

# 清空某路由器的 nat 表与 e2e 注入的 FORWARD DROP(切 NAT 类型前重置)。
_router_reset() {  # $1=router-ns
  ns "$1" iptables -t nat -F
  ns "$1" iptables -F FORWARD 2>/dev/null || true
}

# set_client_nat <fullcone|symmetric|blockudp> —— 切换客户端路由器的 NAT 行为(被测核心)。
#   fullcone  : 端点无关映射 + 入站静态 DNAT → 打洞可成 → connd 升 T0
#   symmetric : 普通 MASQUERADE(逐目的不同源端口,无入站 DNAT)+ DROP 客户端↔数据中心的
#               直连 underlay UDP(保留客户端↔lighthouse 的 relay 路径)→ 打洞必失败、
#               已建直连也被打断 → nebula 落 relay → connd 落 T1。
#               (对称 NAT 的可观测后果就是「到数据中心的直连端点不可用,只能经 relay」,
#                这里用「无端点无关入站映射 + 断开直连对」精确复刻该后果。)
#   blockudp  : DROP 所有 underlay UDP(含到 lighthouse)→ nebula 全 DOWN → connd 落 T2。
# 切换后只清【UDP】conntrack 使旧 underlay 映射/旧直连流立即失效;不动 TCP conntrack
# (否则会打断 frpc visitor/服务端到 frps 的 TCP 隧道,误伤 T2)。
set_client_nat() {
  local mode="$1"
  _router_reset "$NS_RC"
  case "$mode" in
    fullcone)
      _nat_fullcone "$NS_RC" "$RC_PUB" "$CLI_PRIV" "$CLI_NET" e2ebb-rc
      ;;
    symmetric)
      # 普通 MASQUERADE:逐 (dst-ip,dst-port) 选不同源端口 → 端点相关映射(对称 NAT)。
      # 关键:无 full-cone 的「入站静态 DNAT」,故数据中心朝 RC_PUB:4242 的打洞包无处可投。
      ns "$NS_RC" iptables -t nat -A POSTROUTING -s "$CLI_NET" -o e2ebb-rc -j MASQUERADE
      # 断开客户端↔数据中心的【直连】underlay UDP(到/来自 DC 的 NAT 公网映射 RD_PUB),
      # 强制已建直连也回落到经 lighthouse 的 relay(client↔lighthouse 不受影响 → T1 仍可用)。
      ns "$NS_RC" iptables -I FORWARD -p udp -d "$RD_PUB" -j DROP
      ns "$NS_RC" iptables -I FORWARD -p udp -s "$RD_PUB" -j DROP
      ;;
    blockudp)
      # 保留 full-cone NAT 规则,但在 FORWARD 链 DROP 所有 underlay UDP(含到 lighthouse)。
      _nat_fullcone "$NS_RC" "$RC_PUB" "$CLI_PRIV" "$CLI_NET" e2ebb-rc
      ns "$NS_RC" iptables -I FORWARD -p udp --dport "${E2E_PORT}" -j DROP
      ns "$NS_RC" iptables -I FORWARD -p udp --sport "${E2E_PORT}" -j DROP
      ;;
    *) echo "未知 NAT 模式: $mode" >&2; return 1 ;;
  esac
  E2E_CLI_NAT="$mode"
  # 只清 UDP conntrack(-p udp),让旧 underlay 映射/旧直连流立即失效;
  # 保留 TCP conntrack,避免打断 frpc↔frps 的 STCP 隧道(T2)。
  if [[ -n "${CONNTRACK}" ]]; then
    ns "$NS_RC" "${CONNTRACK}" -D -p udp >/dev/null 2>&1 || true
  fi
}

# =============================================================================
# 服务进程起停
# =============================================================================
_spawn() {  # $1=ns $2=tag $3...=cmd
  local nsname="$1" tag="$2"; shift 2
  ns "$nsname" sh -c '[ -e /dev/net/tun ] || (mkdir -p /dev/net; mknod /dev/net/tun c 10 200)' 2>/dev/null || true
  setsid nohup ip netns exec "$nsname" "$@" > "${E2E_ROOT}/run/${tag}.log" 2>&1 &
  echo "$!" > "${E2E_ROOT}/run/${tag}.pid"
  disown 2>/dev/null || true
}

# 极简 git http server(git http-backend via python),serve 一个 bare 仓库的 ls-remote/clone。
# 用 git 自带 http-backend(CGI)+ python3 内置 CGI server,无需 nginx/apache。
e2e_init_git() {
  local GD="${E2E_ROOT}/git/shared.git"
  if [[ ! -d "$GD" ]]; then
    mkdir -p "${E2E_ROOT}/git"
    git init -q --bare "$GD"
    git --git-dir="$GD" config http.receivepack true
    # 写一个初始提交到 refs/heads/current(纯 plumbing,无工作树),供 ls-remote 列真实 ref。
    local BLOB TREE COMMIT
    BLOB="$(printf 'shared-sync v2 Phase5 e2e seed\n' | git --git-dir="$GD" hash-object -w --stdin)"
    TREE="$(printf '100644 blob %s\tREADME\n' "$BLOB" | git --git-dir="$GD" mktree)"
    COMMIT="$(echo 'phase5 seed' | GIT_AUTHOR_NAME=ss GIT_AUTHOR_EMAIL=ss@local \
              GIT_COMMITTER_NAME=ss GIT_COMMITTER_EMAIL=ss@local \
              git --git-dir="$GD" commit-tree "$TREE")"
    git --git-dir="$GD" update-ref refs/heads/current "$COMMIT"
  fi
}

# git http-backend 包装脚本(python3 CGIHTTPServer 调 git http-backend)。
_write_git_server_py() {
  cat > "${E2E_ROOT}/git_http.py" <<'PYEOF'
import os, sys, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
GIT_PROJECT_ROOT = os.environ.get("GIT_PROJECT_ROOT", "/work/git")
GIT_HTTP_BACKEND = "/usr/lib/git-core/git-http-backend"
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def _run(self, body=b""):
        path = self.path
        qs = ""
        if "?" in path:
            path, qs = path.split("?", 1)
        env = dict(os.environ)
        env["GIT_PROJECT_ROOT"] = GIT_PROJECT_ROOT
        env["GIT_HTTP_EXPORT_ALL"] = "1"
        env["PATH_INFO"] = path
        env["QUERY_STRING"] = qs
        env["REQUEST_METHOD"] = self.command
        env["GATEWAY_INTERFACE"] = "CGI/1.1"
        env["SERVER_PROTOCOL"] = "HTTP/1.1"
        env["CONTENT_TYPE"] = self.headers.get("Content-Type", "")
        env["CONTENT_LENGTH"] = str(len(body))
        env["REMOTE_USER"] = "e2e"
        p = subprocess.run([GIT_HTTP_BACKEND], input=body, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out = p.stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        status = "200 OK"
        headers = []
        for line in head.split(b"\r\n"):
            if not line:
                continue
            k, _, v = line.partition(b":")
            k = k.strip().decode(); v = v.strip().decode()
            if k.lower() == "status":
                status = v
            else:
                headers.append((k, v))
        code = int(status.split()[0])
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_GET(self):
        self._run()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self._run(self.rfile.read(n))
    def log_message(self, *a):
        pass
if __name__ == "__main__":
    addr = sys.argv[1] if len(sys.argv) > 1 else "0.0.0.0"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8418
    ThreadingHTTPServer((addr, port), H).serve_forever()
PYEOF
}

e2e_start_services() {
  local RUN="${E2E_ROOT}/run" CFG="${E2E_ROOT}/cfg"; mkdir -p "$RUN"
  e2e_stop_services
  e2e_init_git
  _write_git_server_py

  # 1) lighthouse + frps(都在 pub netns / backbone IP)
  _spawn "$NS_PUB" lighthouse "$NEBULA" -config "$CFG/lighthouse.yml"; sleep 2
  _spawn "$NS_PUB" frps "$FRPS" -c "$CFG/frps.toml"
  # 等 frps 真的在 backbone IP 监听后再起 frpc 客户端(否则首拨被 refuse;叠加 loginFailExit=false 双保险)。
  local j
  for ((j=0;j<20;j++)); do
    if ns "$NS_PUB" sh -c "exec 3<>/dev/tcp/${LH_BB}/${E2E_FRPS_PORT}" 2>/dev/null; then break; fi
    sleep 0.5
  done

  # 2) 数据中心:git http(8418)+ nebula + frpc STCP 服务端
  GIT_PROJECT_ROOT="${E2E_ROOT}/git" _spawn "$NS_DC" githttp \
    python3 "${E2E_ROOT}/git_http.py" 127.0.0.1 "${E2E_GIT_PORT}"
  # 注意:git http 要监听 overlay(供 T0/T1 直达)与 127.0.0.1(供 frpc 服务端)。
  # python server 绑 0.0.0.0 一次即可覆盖二者 —— 用 0.0.0.0。
  kill "$(cat "$RUN/githttp.pid" 2>/dev/null)" 2>/dev/null || true
  GIT_PROJECT_ROOT="${E2E_ROOT}/git" _spawn "$NS_DC" githttp \
    python3 "${E2E_ROOT}/git_http.py" 0.0.0.0 "${E2E_GIT_PORT}"
  _spawn "$NS_DC" dc-nebula "$NEBULA" -config "$CFG/dc.yml"
  _spawn "$NS_DC" frpc-dc "$FRPC" -c "$CFG/frpc-dc.toml"

  # 3) 客户端:nebula(connd 会托管)→ 这里由 connd 起;先起 frpc visitor(sidecar)
  _spawn "$NS_CLI" frpc-visitor "$FRPC" -c "$CFG/frpc-visitor.toml"
  # connd run 自己 fork nebula(nebula.configPath=cli.yml,dryRun=false)+ 控制 sshd + 代理
  _spawn "$NS_CLI" connd "$CONND" run -config "$CFG/connd.yaml"

  # 等关键端口就绪:控制 sshd / visitor / connd status
  local i
  for ((i=0;i<30;i++)); do
    if ns "$NS_CLI" sh -c "exec 3<>/dev/tcp/127.0.0.1/${E2E_STATUS_PORT}" 2>/dev/null; then break; fi
    sleep 1
  done
  sleep 1
}

e2e_stop_services() {
  local RUN="${E2E_ROOT}/run" p
  for p in lighthouse frps githttp dc-nebula frpc-dc frpc-visitor connd; do
    [[ -f "$RUN/$p.pid" ]] && kill "$(cat "$RUN/$p.pid")" 2>/dev/null || true
    rm -f "$RUN/$p.pid" 2>/dev/null || true
  done
  # 兜底:connd 可能已 fork 了 nebula 子进程,精确按 e2e cfg 目录 pkill,绝不误杀别的 nebula。
  pkill -f "config ${E2E_ROOT}/cfg/" 2>/dev/null || true
  pkill -f "config=${E2E_ROOT}/cfg/" 2>/dev/null || true
  pkill -f "${E2E_ROOT}/cfg/" 2>/dev/null || true
  pkill -f "${E2E_ROOT}/git_http.py" 2>/dev/null || true
  pkill -f "${E2E_ROOT}/cfg/connd.yaml" 2>/dev/null || true
  sleep 1
}

# =============================================================================
# topo_down —— 拆 netns / bridge / 本 e2e 加的 root-ns iptables 规则
# =============================================================================
topo_down() {
  e2e_stop_services
  local n l
  for n in "$NS_PUB" "$NS_RD" "$NS_RC" "$NS_DC" "$NS_CLI"; do ip netns del "$n" 2>/dev/null || true; done
  for l in e2ebb-pubh e2ebb-rdh e2ebb-rch e2eD-r e2eD-n e2eC-r e2eC-n; do
    ip link del "$l" 2>/dev/null || true
  done
  ip link del br-e2ebb 2>/dev/null || true
  while iptables -C DOCKER-USER -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT 2>/dev/null; do
    iptables -D DOCKER-USER -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT
  done
  while iptables -C FORWARD -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i br-e2ebb -o br-e2ebb -m comment --comment e2e-backbone -j ACCEPT
  done
}

# =============================================================================
# 探测/断言辅助(对 connd status + git 经客户端固定本地端点)
# =============================================================================
# connd status JSON(在客户端 netns 内查回环状态端点)。
e2e_status() {
  ns "$NS_CLI" "$CONND" status -addr "127.0.0.1:${E2E_STATUS_PORT}" -json 2>/dev/null
}
e2e_status_field() {  # $1=jq-path(python 解析,避免依赖 jq)
  # 注意:把 Python 的 True/False 归一成 JSON 风格 true/false,使 shell 断言可直接比较。
  e2e_status | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit(0)
k='$1'.split('.')
v=d
for x in k:
  v=v.get(x) if isinstance(v,dict) else None
if isinstance(v,bool): print('true' if v else 'false')
else: print(v if v is not None else '')"
}

# git 经客户端固定本地端点(connd 代理 127.0.0.1:8418)。
e2e_git_ls() {
  ns "$NS_CLI" git -c http.extraHeader= ls-remote "http://127.0.0.1:${E2E_PROXY_PORT}/shared.git" 2>&1
}
e2e_git_ok() {
  local o; o="$(e2e_git_ls)"; printf '%s\n' "$o" | grep -qiE "HEAD|refs/heads/current"
}

# 持续高速灌包驱动 nebula 的 try_promote(relay→direct 升级靠包计数触发,见 sim-vps)。
# 在 client→DC overlay 上灌 ICMP;同时让 DC 侧回程也有流量(ping 自然双向)。
e2e_warm_promote() {  # $1=count(默认 600)
  ns "$NS_CLI" ping -c "${1:-600}" -i 0.01 -W 1 "$DC_OVL" >/dev/null 2>&1 || true
}

# 等 connd tier 命中正则(每 2s 一拍)。
#   warm=1(默认):每拍灌少量包维持链路活跃 + 触发探测。
#   warm=2:每拍高速灌包驱动 relay→direct 的 try_promote(升级到 T0 时用)。
e2e_wait_tier() {  # $1=want-regex $2=max-ticks(默认 40) $3=warm(0/1/2,默认 1)
  local want="$1" max="${2:-40}" warm="${3:-1}" t i
  for ((i=0;i<max;i++)); do
    case "$warm" in
      1) ns "$NS_CLI" ping -c 2 -i 0.1 -W 1 "$DC_OVL" >/dev/null 2>&1 || true ;;
      2) ns "$NS_CLI" ping -c 120 -i 0.01 -W 1 "$DC_OVL" >/dev/null 2>&1 || true ;;
    esac
    t="$(e2e_status_field tier)"
    [[ "$t" =~ $want ]] && { echo "$t"; return 0; }
    sleep 1
  done
  echo "$(e2e_status_field tier)"; return 1
}
