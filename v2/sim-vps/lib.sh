#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared-sync v2 sim-vps 可复用函数库
#
# 在【真 Linux】上用 ip netns + veth + iptables 搭一套可控双 NAT 实验台,
# 验证 Nebula 的 T0 直连打洞 / T1 中继兜底 / 切回。被 run.sh 与未来 e2e 复用。
#
# 设计目标:与生产 nebula-lighthouse(overlay 10.77.0.0/24)完全隔离 ——
#   * 独立 overlay 网段 10.88.0.0/24 + 独立 CA(sim-vps CA)
#   * 独立 tun 设备名 svpneb0(生产是 nebula1)
#   * 全部跑在自建 netns 内,不碰 host 路由表/生产容器
#
# 依赖:bash, ip(iproute2), iptables, conntrack, nebula(>=1.10), docker(仅生成证书),
#       python3(解析 hostmap JSON), ssh/ssh-keygen(nebula sshd 控制通道)。
# 需要 root(创建 netns / iptables)。
# =============================================================================
set -uo pipefail

# ---- 可调参数(可用环境变量覆盖)-------------------------------------------
SVP_ROOT="${SVP_ROOT:-/root/sim-vps}"      # 运行期工作目录(证书/配置/日志/pid)
SVP_OVERLAY_CIDR="${SVP_OVERLAY_CIDR:-10.88.0.0/24}"
SVP_BACKBONE="${SVP_BACKBONE:-100.64.0}"   # 模拟"公网"骨干 /24 前缀
SVP_NEBULA="${SVP_NEBULA:-$(command -v nebula || echo /usr/local/bin/nebula)}"
SVP_NEBULA_IMAGE="${SVP_NEBULA_IMAGE:-nebulaoss/nebula:latest}"  # 仅 nebula-cert 用
SVP_PORT="${SVP_PORT:-4242}"               # nebula underlay UDP 端口
SVP_SSHD_PORT="${SVP_SSHD_PORT:-2222}"     # nebula 控制 sshd 端口(每个 node netns 内)

# conntrack CLI 常装在 /usr/sbin(非交互 shell 的 PATH 可能不含 sbin)。
# 解析绝对路径;找不到则留空,block_direct 退化为 flush 而不强制清表(不影响结论)。
SVP_CONNTRACK="${SVP_CONNTRACK:-$(command -v conntrack 2>/dev/null || ls /usr/sbin/conntrack /sbin/conntrack 2>/dev/null | head -1)}"

# 固定 IP 规划:
#   lighthouse overlay 10.88.0.1 / backbone 100.64.0.1
#   nodeA overlay 10.88.0.2 / priv 10.10.1.2 / routerA pub 100.64.0.10
#   nodeB overlay 10.88.0.3 / priv 10.10.2.2 / routerB pub 100.64.0.20
LH_BB="${SVP_BACKBONE}.1"
A_PUB="${SVP_BACKBONE}.10"; A_PRIV=10.10.1.2; A_GW=10.10.1.1; A_NET=10.10.1.0/24
B_PUB="${SVP_BACKBONE}.20"; B_PRIV=10.10.2.2; B_GW=10.10.2.1; B_NET=10.10.2.0/24

# netns 名(全部 svp- 前缀,便于清理时精确匹配)
NS_PUB=svp-pub; NS_RA=svp-ra; NS_RB=svp-rb; NS_NA=svp-na; NS_NB=svp-nb

ns()  { ip netns exec "$@"; }
log() { echo ">> $*"; }

# 控制通道封装:在 node netns 内对本地 nebula sshd 跑控制命令。
# 用法:ctl <ns> <command...>     例:ctl "$NS_NA" list-hostmap -json
ctl() {
  local nsname="$1"; shift
  ns "$nsname" ssh -i "${SVP_ROOT}/ssh/id_ed25519" -p "${SVP_SSHD_PORT}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR \
    ctl@127.0.0.1 "$@" 2>/dev/null
}

# -----------------------------------------------------------------------------
# peer_state <node-ns> <peer-overlay-ip>
#   程序式判定该 node 当前对某 peer 是 direct 还是 relay。
#   解析 `list-hostmap -json` 的 currentRemote 字段(权威判据,见 README)。
#   输出一行:  DIRECT <currentRemote>   /   RELAY <relaysToMe>   /   UNKNOWN
# -----------------------------------------------------------------------------
# 注意:用 `python3 -c "$SCRIPT"` 而非 `python3 - <<HEREDOC`。
# 后者会把 heredoc 接到 python 的 stdin,反而吃掉了管道里的 hostmap JSON。
SVP_PARSE_PY='
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
        # 权威判据:currentRemote 非空 => nebula 当前把数据发到该 underlay 端点。
        #   若该端点 == peer 的 NAT 公网映射 => DIRECT(T0)。
        #   若 currentRemote 为空(只有 relay 入口)=> RELAY(T1)。
        # 注意:currentRelaysToMe 即使非空也可能只是【备用】中继登记,
        #       不代表数据走中继 —— 必须以 currentRemote 为准。
        if cr:
            print("DIRECT %s" % cr)
        elif rtm:
            print("RELAY %s" % ",".join(rtm))
        else:
            print("UNKNOWN no-remote")
        sys.exit(0)
print("UNKNOWN peer-absent")
'
peer_state() {
  local nsname="$1" peer="$2"
  ctl "$nsname" list-hostmap -json | python3 -c "$SVP_PARSE_PY" "$peer"
}

# 轮询直到 peer_state 的首字段命中期望(DIRECT/RELAY),或超时。
# 用法:wait_state <node-ns> <peer> <DIRECT|RELAY> <timeout-s> [warm-target]
#   warm-target:轮询时持续 ping 的 overlay IP,用来"喂"nebula 触发探测/promote。
wait_state() {
  local nsname="$1" peer="$2" want="$3" timeout="${4:-30}" warm="${5:-$peer}" i st
  for ((i=0; i<timeout; i++)); do
    # 持续低速 ping 维持链路活跃 + 驱动 try_promote
    ns "$nsname" ping -c 2 -i 0.1 -W 1 "$warm" >/dev/null 2>&1 || true
    st="$(peer_state "$nsname" "$peer")"
    if [[ "${st%% *}" == "$want" ]]; then
      echo "$st"; return 0
    fi
    sleep 1
  done
  echo "$(peer_state "$nsname" "$peer")"   # 返回最后状态供诊断
  return 1
}

# =============================================================================
# 证书:独立 sim-vps CA + lh/nodeA/nodeB(overlay 10.88.0.0/24)。幂等。
# 用 docker 里的 nebula-cert(本机无需装 nebula-cert)。
# =============================================================================
svp_gen_certs() {
  local C="${SVP_ROOT}/certs"; mkdir -p "$C"
  _nc() { docker run --rm -v "${C}:/out" -w /out --entrypoint /nebula-cert "${SVP_NEBULA_IMAGE}" "$@"; }
  if [[ ! -f "$C/ca.crt" ]]; then
    log "签发 sim-vps CA (${SVP_OVERLAY_CIDR})"
    _nc ca -name "sim-vps CA" -duration 8760h -networks "${SVP_OVERLAY_CIDR}" -out-crt ca.crt -out-key ca.key
  fi
  local e n ip
  for e in lh:10.88.0.1 nodeA:10.88.0.2 nodeB:10.88.0.3; do
    n="${e%%:*}"; ip="${e##*:}"
    [[ -f "$C/$n.crt" ]] && continue
    log "签发节点证书 $n -> $ip/24"
    _nc sign -ca-crt ca.crt -ca-key ca.key -name "$n" -networks "$ip/24" \
        -duration 4380h -out-crt "$n.crt" -out-key "$n.key"
  done
  # nebula 控制 sshd 需要:授权用户公钥 + host key
  mkdir -p "${SVP_ROOT}/ssh"
  [[ -f "${SVP_ROOT}/ssh/id_ed25519" ]] || ssh-keygen -t ed25519 -N "" -q -f "${SVP_ROOT}/ssh/id_ed25519"
  [[ -f "${SVP_ROOT}/ssh/hostkey"     ]] || ssh-keygen -t ed25519 -N "" -q -f "${SVP_ROOT}/ssh/hostkey"
}

# =============================================================================
# 渲染 nebula 配置:lighthouse + nodeA + nodeB
#   lighthouse: am_lighthouse + am_relay,监听 backbone 100.64.0.1:4242
#   node:       static_host_map 指向 lighthouse,use_relays,punchy 打洞,
#               sshd 控制通道(127.0.0.1:2222)供程序式查 hostmap。
# =============================================================================
svp_render_configs() {
  local C="${SVP_ROOT}/certs" CFG="${SVP_ROOT}/cfg"; mkdir -p "$CFG"
  local PUBKEY; PUBKEY="$(cat "${SVP_ROOT}/ssh/id_ed25519.pub")"

  cat > "$CFG/lighthouse.yml" <<YEOF
pki: {ca: $C/ca.crt, cert: $C/lh.crt, key: $C/lh.key}
static_host_map: {}
lighthouse: {am_lighthouse: true, serve_dns: false, hosts: []}
listen: {host: 0.0.0.0, port: ${SVP_PORT}}
punchy: {punch: true, respond: true}
relay: {am_relay: true, use_relays: false, relays: []}
tun: {disabled: false, dev: svpneb0, mtu: 1300}
logging: {level: info, format: text}
firewall:
  outbound_action: drop
  inbound_action: drop
  conntrack: {tcp_timeout: 12m, udp_timeout: 3m, default_timeout: 10m}
  outbound: [{port: any, proto: any, host: any}]
  inbound:  [{port: any, proto: icmp, host: any}, {port: any, proto: any, host: any}]
YEOF

  _node_cfg() {  # $1=name $2=cert-base
    cat > "$CFG/$1.yml" <<YEOF
pki: {ca: $C/ca.crt, cert: $C/$2.crt, key: $C/$2.key}
static_host_map:
  "10.88.0.1": ["${LH_BB}:${SVP_PORT}"]
lighthouse: {am_lighthouse: false, serve_dns: false, hosts: ["10.88.0.1"], interval: 10}
listen: {host: 0.0.0.0, port: ${SVP_PORT}}
punchy: {punch: true, respond: true, delay: 1s}
relay: {am_relay: false, use_relays: true, relays: ["10.88.0.1"]}
tun: {disabled: false, dev: svpneb0, mtu: 1300}
logging: {level: info, format: text}
firewall:
  outbound_action: drop
  inbound_action: drop
  conntrack: {tcp_timeout: 12m, udp_timeout: 3m, default_timeout: 10m}
  outbound: [{port: any, proto: any, host: any}]
  inbound:  [{port: any, proto: icmp, host: any}, {port: 8418, proto: tcp, host: any}]
sshd:
  enabled: true
  listen: 127.0.0.1:${SVP_SSHD_PORT}
  host_key: ${SVP_ROOT}/ssh/hostkey
  authorized_users:
    - user: ctl
      keys: ["${PUBKEY}"]
YEOF
  }
  _node_cfg nodeA nodeA
  _node_cfg nodeB nodeB
}

# =============================================================================
# topo_up — 建 netns 双 NAT 拓扑(full-cone NAT,SNAT 固定端口 + 静态 DNAT)
# =============================================================================
topo_up() {
  log "[topo] 清理可能残留的 sim netns/bridge"
  topo_down >/dev/null 2>&1 || true

  log "[topo] 创建 namespaces"
  ip netns add "$NS_PUB"; ip netns add "$NS_RA"; ip netns add "$NS_RB"
  ip netns add "$NS_NA";  ip netns add "$NS_NB"

  log "[topo] backbone bridge(模拟公网)br-svpbb"
  ip link add br-svpbb type bridge; ip link set br-svpbb up

  _attach_bb() {  # $1=ns $2=host-if $3=peer-if $4=ip
    ip link add "$2" type veth peer name "$3"
    ip link set "$2" master br-svpbb; ip link set "$2" up
    ip link set "$3" netns "$1"
    ns "$1" ip link set lo up; ns "$1" ip link set "$3" up
    ns "$1" ip addr add "$4/24" dev "$3"
  }
  _attach_bb "$NS_PUB" svpbb-pubh svpbb-pub "$LH_BB"
  _attach_bb "$NS_RA"  svpbb-rah  svpbb-ra  "$A_PUB"
  _attach_bb "$NS_RB"  svpbb-rbh  svpbb-rb  "$B_PUB"

  log "[topo] 私网段 A: routerA ${A_GW} <-> nodeA ${A_PRIV}"
  ip link add svpA-r type veth peer name svpA-n
  ip link set svpA-r netns "$NS_RA"; ip link set svpA-n netns "$NS_NA"
  ns "$NS_RA" ip addr add "$A_GW/24" dev svpA-r; ns "$NS_RA" ip link set svpA-r up
  ns "$NS_NA" ip link set lo up
  ns "$NS_NA" ip addr add "$A_PRIV/24" dev svpA-n; ns "$NS_NA" ip link set svpA-n up
  ns "$NS_NA" ip route add default via "$A_GW"

  log "[topo] 私网段 B: routerB ${B_GW} <-> nodeB ${B_PRIV}"
  ip link add svpB-r type veth peer name svpB-n
  ip link set svpB-r netns "$NS_RB"; ip link set svpB-n netns "$NS_NB"
  ns "$NS_RB" ip addr add "$B_GW/24" dev svpB-r; ns "$NS_RB" ip link set svpB-r up
  ns "$NS_NB" ip link set lo up
  ns "$NS_NB" ip addr add "$B_PRIV/24" dev svpB-n; ns "$NS_NB" ip link set svpB-n up
  ns "$NS_NB" ip route add default via "$B_GW"

  log "[topo] routers: forwarding + full-cone NAT(udp/${SVP_PORT})"
  _nat() {  # $1=ns $2=pub $3=node-priv $4=net $5=pubif
    ns "$1" sysctl -q -w net.ipv4.ip_forward=1
    ns "$1" ip route add default via "$LH_BB" 2>/dev/null || true
    # full-cone 出站:SNAT 固定源端口(端点无关源映射)
    ns "$1" iptables -t nat -A POSTROUTING -s "$3" -p udp --sport "${SVP_PORT}" -o "$5" -j SNAT --to-source "${2}:${SVP_PORT}"
    # full-cone 入站:静态 DNAT,任何源打到 pub:4242 都转给内部节点(端点无关目的映射)
    ns "$1" iptables -t nat -A PREROUTING -d "$2" -p udp --dport "${SVP_PORT}" -i "$5" -j DNAT --to-destination "${3}:${SVP_PORT}"
    # 其它流量(icmp 等)普通 MASQUERADE,使节点仍能访问 backbone
    ns "$1" iptables -t nat -A POSTROUTING -s "$4" ! -p udp -o "$5" -j MASQUERADE
    ns "$1" iptables -t nat -A POSTROUTING -s "$4" -p udp ! --sport "${SVP_PORT}" -o "$5" -j MASQUERADE
  }
  _nat "$NS_RA" "$A_PUB" "$A_PRIV" "$A_NET" svpbb-ra
  _nat "$NS_RB" "$B_PUB" "$B_PRIV" "$B_NET" svpbb-rb

  # 关键:host root-ns 若开了 bridge-nf-call-iptables(常见于装了 docker),
  # 桥接帧会过 root 的 FORWARD 链(策略常为 DROP)。放行本 sim backbone 桥的转发。
  # 插到 DOCKER-USER(若存在)最前,带 comment 便于精确清理;否则插 FORWARD。
  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    iptables -C DOCKER-USER -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT 2>/dev/null \
      || iptables -I DOCKER-USER 1 -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT
  else
    iptables -C FORWARD -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT 2>/dev/null \
      || iptables -I FORWARD 1 -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT
  fi
}

# =============================================================================
# nebula 起停
# =============================================================================
svp_start_nebula() {
  local RUN="${SVP_ROOT}/run" CFG="${SVP_ROOT}/cfg"; mkdir -p "$RUN"
  svp_stop_nebula   # 先确保无残留实例(避免端口/握手竞争 "network is unreachable")
  _start() { # $1=ns $2=name
    ns "$1" sh -c '[ -e /dev/net/tun ] || (mkdir -p /dev/net; mknod /dev/net/tun c 10 200)' 2>/dev/null || true
    # setsid + nohup:脱离当前(可能是 ssh 非交互)会话,使 nebula 在脚本退出/翻页后存活,
    # 并与脚本各步骤的子 shell 生命周期解耦。
    setsid nohup ip netns exec "$1" "$SVP_NEBULA" -config "$CFG/$2.yml" > "$RUN/$2.log" 2>&1 &
    echo "$!" > "$RUN/$2.pid"
    disown 2>/dev/null || true
  }
  _start "$NS_PUB" lighthouse; sleep 2
  _start "$NS_NA"  nodeA
  _start "$NS_NB"  nodeB
  # 等待三个控制 sshd 就绪(最多 ~15s),确保 ctl 查询可用
  local i
  for ((i=0; i<15; i++)); do
    if ns "$NS_NA" sh -c "exec 3<>/dev/tcp/127.0.0.1/${SVP_SSHD_PORT}" 2>/dev/null; then break; fi
    sleep 1
  done
  sleep 1
}

svp_stop_nebula() {
  local RUN="${SVP_ROOT}/run" p
  for p in lighthouse nodeA nodeB; do
    [[ -f "$RUN/$p.pid" ]] && kill "$(cat "$RUN/$p.pid")" 2>/dev/null || true
    rm -f "$RUN/$p.pid" 2>/dev/null || true
  done
  # 兜底:精确 pkill 本 sim 的 nebula(按 sim cfg 目录匹配,绝不误杀生产 nebula-lighthouse)
  pkill -f "nebula -config ${SVP_ROOT}/cfg/" 2>/dev/null || true
  sleep 1
}

# =============================================================================
# topo_down — 拆除所有 sim netns / bridge / 本 sim 加的 iptables 规则
#   只删自己建的(svp- 前缀 netns、br-svpbb、带 svp-sim-backbone comment 的规则)。
#   不碰生产 nebula-lighthouse / ss-server / docker0。
# =============================================================================
topo_down() {
  svp_stop_nebula
  local n l
  for n in "$NS_PUB" "$NS_RA" "$NS_RB" "$NS_NA" "$NS_NB"; do ip netns del "$n" 2>/dev/null || true; done
  # 删可能遗留在 root-ns 的 sim veth host 端(netns 删除通常会带走,但 KEEP/中断可能留孤儿)
  for l in svpbb-pubh svpbb-rah svpbb-rbh svpA-r svpA-n svpB-r svpB-n; do
    ip link del "$l" 2>/dev/null || true
  done
  ip link del br-svpbb 2>/dev/null || true
  # 删本 sim 在 root-ns 加的 backbone 放行规则(精确按 comment 匹配,可能有多条)
  while iptables -C DOCKER-USER -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT 2>/dev/null; do
    iptables -D DOCKER-USER -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT
  done
  while iptables -C FORWARD -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i br-svpbb -o br-svpbb -m comment --comment svp-sim-backbone -j ACCEPT
  done
}

# 在两 router 上阻断/恢复 A<->B 之间的直连 UDP(强制 relay / 解除)。
# 经 lighthouse(backbone .1)的中继路径不受影响。
block_direct() {
  ns "$NS_RA" iptables -I FORWARD -p udp -d "$B_PUB" -j DROP
  ns "$NS_RA" iptables -I FORWARD -p udp -s "$B_PUB" -j DROP
  ns "$NS_RB" iptables -I FORWARD -p udp -d "$A_PUB" -j DROP
  ns "$NS_RB" iptables -I FORWARD -p udp -s "$A_PUB" -j DROP
  # 清掉已建立的 direct conntrack,使 DROP 立即生效(否则旧流仍被 ESTABLISHED 放行)
  if [[ -n "${SVP_CONNTRACK}" ]]; then
    ns "$NS_RA" "${SVP_CONNTRACK}" -F >/dev/null 2>&1 || true
    ns "$NS_RB" "${SVP_CONNTRACK}" -F >/dev/null 2>&1 || true
  fi
}
unblock_direct() {
  ns "$NS_RA" iptables -D FORWARD -p udp -d "$B_PUB" -j DROP 2>/dev/null || true
  ns "$NS_RA" iptables -D FORWARD -p udp -s "$B_PUB" -j DROP 2>/dev/null || true
  ns "$NS_RB" iptables -D FORWARD -p udp -d "$A_PUB" -j DROP 2>/dev/null || true
  ns "$NS_RB" iptables -D FORWARD -p udp -s "$A_PUB" -j DROP 2>/dev/null || true
}

# 持续灌包驱动 nebula 的 try_promote(relay->direct 升级靠包计数触发)。
# 用法:warm_promote <node-ns> <peer> <count>
warm_promote() {
  ns "$1" ping -c "${3:-2000}" -i 0.01 -W 1 "$2" >/dev/null 2>&1 || true
}
