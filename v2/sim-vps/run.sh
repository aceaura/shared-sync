#!/usr/bin/env bash
# =============================================================================
# run.sh — shared-sync v2 sim-vps 一键验证(真 Linux netns 双 NAT)
#
# 在任意 Linux(需 root + nebula + iproute2 + iptables + conntrack + python3 +
# docker[仅生成证书])上一键完成:
#   建 netns 双 NAT 拓扑 -> 起 nebula(lighthouse + nodeA + nodeB)
#   STEP2  验证 A↔B 经 lighthouse 打洞建立 T0 直连(hostmap currentRemote=B 的 NAT 映射)
#   STEP3  阻断两私网段直连 UDP -> 降级 T1 中继(hostmap currentRemote 空、走 relay),overlay 仍通
#   STEP4  解除阻断 + 灌包驱动 promote -> 切回 T0 直连(数据回到 B 的 NAT 映射)
#   结束自动清理(netns/bridge/本 sim 的 iptables 规则)。
#
# 用法:
#   sudo bash run.sh            # 跑全部并清理
#   sudo KEEP=1 bash run.sh     # 跑完保留环境(手动排查)
#
# 退出码:全部关键断言通过=0;任一失败=1。
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PEER_B=10.88.0.3   # 从 nodeA 看 nodeB 的 overlay IP
PEER_A=10.88.0.2
PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }
hdr()  { echo; echo "==================== $* ===================="; }

if [[ "$(id -u)" != "0" ]]; then echo "需要 root(创建 netns / iptables)"; exit 1; fi
# 工具解析:含 /usr/sbin、/sbin(非交互 shell 的 PATH 常缺 sbin)
export PATH="${PATH}:/usr/sbin:/sbin"
for t in ip iptables python3 ssh ssh-keygen; do
  command -v "$t" >/dev/null || { echo "缺依赖: $t"; exit 1; }
done
[[ -n "${SVP_CONNTRACK}" ]] || echo "  [WARN] 未找到 conntrack CLI(/usr/sbin/conntrack);block_direct 不强制清表,降级窗口可能略长,不影响结论"
[[ -x "$SVP_NEBULA" ]] || { echo "未找到 nebula 可执行文件(SVP_NEBULA=$SVP_NEBULA)"; exit 1; }

cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo; echo ">> KEEP=1:保留环境。手动清理:  sudo bash ${SCRIPT_DIR}/run.sh --cleanup"
    return
  fi
  echo; log "清理 sim 环境(netns/bridge/iptables)"; topo_down; log "清理完成。"
}
trap cleanup EXIT

if [[ "${1:-}" == "--cleanup" ]]; then trap - EXIT; topo_down; echo "已清理。"; exit 0; fi

# ---- 准备:证书 + 配置 + 拓扑 + nebula ---------------------------------------
hdr "SETUP 证书 / 配置 / 拓扑 / nebula"
svp_gen_certs
svp_render_configs
topo_up
# 基础可达性:两节点经各自 NAT 都能 ping 通 lighthouse backbone
if ns "$NS_NA" ping -c2 -W2 "$LH_BB" >/dev/null 2>&1 && ns "$NS_NB" ping -c2 -W2 "$LH_BB" >/dev/null 2>&1; then
  info "nodeA/nodeB 经 NAT 可达 lighthouse backbone ${LH_BB}"
else
  fail "节点无法经 NAT 到达 lighthouse — 拓扑/转发异常"; exit 1
fi
# 验证两私网段确实互不直连(只能经 backbone NAT)
if ! ns "$NS_NA" ping -c1 -W1 "$B_PRIV" >/dev/null 2>&1; then
  info "私网段隔离正确:nodeA 不能直连 nodeB 私网 ${B_PRIV}"
else
  fail "私网段未隔离(nodeA 直接 ping 通了 nodeB 私网)";
fi
svp_start_nebula
info "nebula 已起(lighthouse + nodeA + nodeB),overlay ${SVP_OVERLAY_CIDR},tun=svpneb0"

# =============================================================================
# STEP 2 — T0 直连打洞收敛
# =============================================================================
hdr "STEP2 验证 T0 直连打洞(real Linux conntrack 下应收敛)"
ns "$NS_NA" ping -c 6 -i 0.4 -W 2 "$PEER_B" >/dev/null 2>&1 || true
ST="$(wait_state "$NS_NA" "$PEER_B" DIRECT 30 "$PEER_B")"
echo "  hostmap(nodeA 看 nodeB): ${ST}"
if [[ "${ST%% *}" == "DIRECT" && "${ST#* }" == "${B_PUB}:${SVP_PORT}" ]]; then
  pass "STEP2 T0 直连:currentRemote=${B_PUB}:${SVP_PORT}(B 的 NAT 公网映射)"
  RTT="$(ns "$NS_NA" ping -c 5 -W 2 "$PEER_B" 2>&1 | tail -1)"
  info "overlay RTT(direct): ${RTT}"
else
  fail "STEP2 未收敛到 direct(状态: ${ST})"
  info "nodeA 日志尾部:"; tail -8 "${SVP_ROOT}/run/nodeA.log" | sed 's/^/      /'
fi

# =============================================================================
# STEP 3 — 阻断直连 UDP,降级到 T1 中继
# =============================================================================
hdr "STEP3 阻断两私网段直连 UDP -> 降级 T1 中继(overlay 仍通)"
block_direct
info "已在 router 上 DROP ${A_PUB}<->${B_PUB} 的 UDP(仅保留经 lighthouse 的 relay)"
ST="$(wait_state "$NS_NA" "$PEER_B" RELAY 40 "$PEER_B")"
echo "  hostmap(nodeA 看 nodeB): ${ST}"
if [[ "${ST%% *}" == "RELAY" ]]; then
  pass "STEP3 已降级 T1 中继:currentRemote 空,经 relay ${ST#* }"
else
  fail "STEP3 未降级到 relay(状态: ${ST})"
fi
if ns "$NS_NA" ping -c 5 -W 3 "$PEER_B" >/dev/null 2>&1; then
  pass "STEP3 中继兜底下 overlay 仍互通(ping OK)"
else
  fail "STEP3 中继下 overlay 不通"
fi

# =============================================================================
# STEP 4 — 解除阻断,切回 T0 直连
# =============================================================================
hdr "STEP4 解除阻断 -> 切回 T0 直连"
unblock_direct
info "已解除阻断;灌包驱动 nebula try_promote(relay->direct 升级靠包计数触发)"
warm_promote "$NS_NA" "$PEER_B" 1500 &
WP=$!
ST="$(wait_state "$NS_NA" "$PEER_B" DIRECT 60 "$PEER_B")"
wait $WP 2>/dev/null || true
echo "  hostmap(nodeA 看 nodeB): ${ST}"
# 切回判定:currentRemote 回到 B 的 NAT 映射 + 数据确实走直连(抓 nodeB underlay)
DIRECT_PKTS=0
if [[ "${ST%% *}" == "DIRECT" && "${ST#* }" == "${B_PUB}:${SVP_PORT}" ]]; then
  ns "$NS_NB" timeout 4 tcpdump -ni svpB-n "udp and port ${SVP_PORT}" 2>/dev/null > /tmp/svp_cap.txt &
  ns "$NS_NA" ping -c 200 -i 0.02 -W 1 "$PEER_B" >/dev/null 2>&1 || true
  sleep 4
  # grep -c 无匹配时退出码非 0 且打印 "0";用 grep|wc -l 保证恒为单一整数。
  DIRECT_PKTS="$(grep -F "${A_PUB}." /tmp/svp_cap.txt 2>/dev/null | wc -l | tr -d ' ')"
  RELAY_PKTS="$(grep -F "${LH_BB}."  /tmp/svp_cap.txt 2>/dev/null | wc -l | tr -d ' ')"
  # 判定:数据【主体】走直连即算切回成功。促升瞬间可能有极少量在途 relay 包(< direct 的 5%),
  # 属正常过渡,不算失败 —— 关键是 currentRemote=direct 且 direct 包占绝对主导。
  if [[ "$DIRECT_PKTS" -gt 0 && $(( RELAY_PKTS * 20 )) -lt "$DIRECT_PKTS" ]]; then
    pass "STEP4 切回 T0 直连:currentRemote=${B_PUB}:${SVP_PORT};数据直连(${DIRECT_PKTS} 包来自 ${A_PUB},relay=${RELAY_PKTS} 过渡残包)"
    info "overlay RTT(direct): $(ns "$NS_NA" ping -c5 -W2 "$PEER_B" 2>&1 | tail -1)"
  else
    fail "STEP4 hostmap 显示 direct 但数据未走直连(direct=${DIRECT_PKTS} relay=${RELAY_PKTS})"
  fi
else
  fail "STEP4 未切回 direct(状态: ${ST})"
fi

# =============================================================================
# 汇总
# =============================================================================
hdr "汇总"
echo "  PASS=${PASS}  FAIL=${FAIL}"
if [[ "$FAIL" -eq 0 ]]; then echo "  ====> 全部关键断言 PASS"; exit 0
else echo "  ====> 有 ${FAIL} 项 FAIL"; exit 1; fi
