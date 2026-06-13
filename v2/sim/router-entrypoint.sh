#!/usr/bin/env bash
# =============================================================================
# router-entrypoint.sh — 模拟家庭/公司出口路由器(做 NAT)
#
# 每个 private 网段放一个本容器:
#   * private 网卡(eth_priv):面向私网节点(home/company),是它们的默认网关。
#   * public  网卡(eth_pub):面向 public 网段(lighthouse 所在),做源地址伪装。
# 节点出网 -> 经本容器 MASQUERADE(改写源 IP 为 router 的 public IP)-> 模拟 NAT。
# 两个 private 网段之间没有任何直连路由,只能各自经 public 段(lighthouse)相遇。
#
# 第三步"打洞失败"注入:BLOCK_DIRECT=1 时,在 FORWARD 上丢弃
# "去往对端 router public IP" 的 UDP(nebula 数据端口),逼迫流量走 relay。
# 仍放行去往 lighthouse 的 UDP(否则连 relay/发现都断)。
#
# 环境变量:
#   PUBLIC_IFACE    public 侧网卡名(默认自动探测含 PUBLIC_SUBNET 的网卡)
#   PUBLIC_SUBNET   public 网段前缀,用于探测网卡,如 "10.88.0."
#   LIGHTHOUSE_PUB_IP  lighthouse 在 public 段的 IP(relay 放行白名单)
#   PEER_ROUTER_PUB_IP 对端 router 的 public IP(BLOCK_DIRECT 时丢弃去它的 UDP)
#   BLOCK_DIRECT    "1" 阻断两 private 段之间的直连 UDP(强制 relay)
# =============================================================================
set -euo pipefail

log() { echo "[router-entrypoint $(hostname)] $*" >&2; }

PUBLIC_SUBNET="${PUBLIC_SUBNET:-10.88.0.}"

# ---- 探测 public 侧网卡 ------------------------------------------------------
if [[ -z "${PUBLIC_IFACE:-}" ]]; then
  PUBLIC_IFACE="$(ip -o -4 addr show | awk -v p="${PUBLIC_SUBNET}" '$4 ~ p {print $2; exit}')"
fi
: "${PUBLIC_IFACE:?未能探测到 public 网卡,请检查 PUBLIC_SUBNET}"
log "public 网卡=${PUBLIC_IFACE}"

# ---- 开启转发 + MASQUERADE(核心 NAT) ---------------------------------------
# compose 的 sysctls 已在命名空间创建时把 ip_forward 置 1(之后 /proc/sys 只读),
# 所以这里只校验、不强写(强写会在只读 fs 上报错;配 set -e 会误杀容器)。
CUR_FWD="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
if [[ "${CUR_FWD}" != "1" ]]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || \
    log "WARN: 无法写 ip_forward(当前=${CUR_FWD});请确认 compose 设了 sysctls"
fi
log "net.ipv4.ip_forward=${CUR_FWD}(compose sysctls 已置 1)"

# nebula 数据端口 4242 的源端口保持(endpoint-independent / full-cone 化):
#   通用 MASQUERADE 会按"目的不同"给每条流分配【不同】源端口(行为近似 symmetric NAT),
#   这会让对端学到的 endpoint 端口与实际不符,UDP 打洞打不通,只能一直走 relay。
#   这里对【源端口=4242】(nebula 监听口)的出站包做固定 SNAT 到 pub_ip:4242,
#   配合下面对 4242 的入站 DNAT,使本节点在公网上始终呈现为稳定的 pub_ip:4242
#   —— 这就是 full-cone(端口保持)NAT,真实世界大量家用路由器即如此,本就可打洞。
#   必须放在通用 MASQUERADE 之前(-I 1),否则会被 MASQUERADE 先匹配。
if [[ -n "${PUBLIC_IP:-}" ]]; then
  iptables -t nat -I POSTROUTING 1 -o "${PUBLIC_IFACE}" -p udp --sport 4242 \
    -j SNAT --to-source "${PUBLIC_IP}:4242"
  log "port-preserving SNAT: udp/sport4242 -> ${PUBLIC_IP}:4242 (full-cone)"
fi

# 其余从私网经 public 网卡出去的包,源地址伪装成 router 的 public IP(典型家用 NAT)。
iptables -t nat -A POSTROUTING -o "${PUBLIC_IFACE}" -j MASQUERADE
log "MASQUERADE on ${PUBLIC_IFACE}"

# ---- full-cone NAT 化(让打洞能成) ------------------------------------------
# 背景:docker 网桥的 MASQUERADE 对【入站、无 conntrack 命中】的 UDP 直接丢,
# 行为接近 symmetric NAT —— 这会让 UDP 打洞打不通,nebula 只能一直走 relay。
# 为在 docker 里复现"打洞成功 -> 直连"的主路径,把 router 做成 full-cone NAT:
# 给节点的 nebula 数据端口(4242)做一条固定 DNAT —— router public IP 上到达
# :4242 的 UDP 转发给私网节点,且 MASQUERADE 保留源端口。于是节点在公网上有了
# 稳定可达的 endpoint(router_pub_ip:4242),对端打过来即命中,直连建立。
# (真实世界里大量家用路由器就是 full-cone / 端口保持型,本就可打洞;
#  symmetric/CGNAT 打不通的场景由第三步的 BLOCK_DIRECT 显式模拟。)
if [[ -n "${NODE_PRIV_IP:-}" ]]; then
  log "full-cone DNAT: ${PUBLIC_IFACE}:udp/4242 -> ${NODE_PRIV_IP}:4242(让打洞可成)"
  iptables -t nat -A PREROUTING -i "${PUBLIC_IFACE}" -p udp --dport 4242 \
    -j DNAT --to-destination "${NODE_PRIV_IP}:4242"
fi

# ---- 第三步:阻断直连 UDP,强制走 relay --------------------------------------
if [[ "${BLOCK_DIRECT:-0}" == "1" ]]; then
  : "${PEER_ROUTER_PUB_IP:?BLOCK_DIRECT 需要 PEER_ROUTER_PUB_IP}"
  log "BLOCK_DIRECT=1:丢弃去往对端 router(${PEER_ROUTER_PUB_IP})的 UDP,逼走 relay"
  # 注意:必须放在 MASQUERADE 之外的 filter/FORWARD,匹配私网节点转发出去的包。
  # 去往对端 router public IP 的 UDP 一律丢(那是对端 NAT 后的直连 endpoint)。
  # 去往 lighthouse 的 UDP 不动 —— 发现 + relay 仍通。
  iptables -A FORWARD -o "${PUBLIC_IFACE}" -p udp -d "${PEER_ROUTER_PUB_IP}" -j DROP
  # 反向(对端打过来的洞)同样丢,确保双向都打不通。
  iptables -A FORWARD -i "${PUBLIC_IFACE}" -p udp -s "${PEER_ROUTER_PUB_IP}" -j DROP
fi

log "iptables nat 表:"
iptables -t nat -S >&2
log "iptables filter FORWARD:"
iptables -S FORWARD >&2

log "router 就绪,保持前台运行"
# 保持容器存活;sleep infinity 在 alpine coreutils/busybox 都可用。
exec sleep infinity
