#!/usr/bin/env bash
# =============================================================================
# v2/e2e/run.sh —— Phase5 完整三层阶梯 e2e(在【真 Linux】容器/VPS 内跑)
#
# 用 netns 精确控制客户端 NAT 类型 / UDP 封锁,驱动【真 connd】走完整三层阶梯并断言:
#
#   场景A  full-cone NAT     → connd 稳定 T0 直连(viaVps=false,currentRemote=对端NAT映射),git 通
#   场景B  对称 NAT(打洞必失败)→ connd 落 T1 UDP 中继(viaVps=true),git 仍通
#   场景C  封死 UDP          → connd 落 T2 TCP 兜底(viaVps=true),git 仍通
#   场景D  恢复(C→B→A)     → 解封后逐级升回,断言最终回到该 NAT 应有最高层
#
# 每场景断言 connd status 的 tier/viaVps + 引擎经【固定本地端点】git ls-remote 成功。
# 输出逐场景 PASS/FAIL 汇总;任一 FAIL 退出码 1;结束清理。
#
# 注:本脚本要求【真 Linux + root + netns】。在 macOS 上请用 ./run-in-docker.sh
#     (它把整套封进 --privileged Linux 容器后调用本脚本)。
#
# 用法(Linux/VPS 内):
#   sudo bash run.sh              # 跑四场景并清理
#   sudo KEEP=1 bash run.sh       # 跑完保留 netns 供排查
#   sudo bash run.sh --cleanup    # 仅清理
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }
hdr()  { echo; echo "==================== $* ===================="; }

if [[ "$(id -u)" != "0" ]]; then echo "需要 root(创建 netns / iptables)"; exit 1; fi
export PATH="${PATH}:/usr/sbin:/sbin:/usr/local/bin"
for t in ip iptables python3 ssh ssh-keygen git "$NEBULA" "$NEBULA_CERT" "$FRPC" "$FRPS" "$CONND"; do
  command -v "$t" >/dev/null 2>&1 || [[ -x "$t" ]] || { echo "缺依赖: $t"; exit 1; }
done
[[ -n "${CONNTRACK}" ]] || echo "  [WARN] 未找到 conntrack CLI;切 NAT 后旧映射回收略慢,不影响结论"

cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo; echo ">> KEEP=1:保留 netns。手动清理:  sudo bash ${SCRIPT_DIR}/run.sh --cleanup"
    return
  fi
  echo; log "清理 e2e netns/bridge/iptables"; topo_down; log "清理完成。"
}
trap cleanup EXIT
if [[ "${1:-}" == "--cleanup" ]]; then trap - EXIT; topo_down; echo "已清理。"; exit 0; fi

# 诊断:打印 connd status 关键字段 + git 首行。
dump() {
  local tier via up cr t0 t1 t2 rc
  tier="$(e2e_status_field tier)"; via="$(e2e_status_field viaVps)"
  up="$(e2e_status_field upstream)"; cr="$(e2e_status_field currentRemote)"
  t0="$(e2e_status_field tiersHealth.T0)"; t1="$(e2e_status_field tiersHealth.T1)"; t2="$(e2e_status_field tiersHealth.T2)"
  rc="$(e2e_status_field reconnecting)"
  echo "    connd: tier=$tier viaVps=$via upstream=$up currentRemote=$cr tiersHealth{T0=$t0 T1=$t1 T2=$t2} reconnecting=$rc"
  echo "    git ls-remote(经 127.0.0.1:${E2E_PROXY_PORT}): $(e2e_git_ls | head -1)"
}

# ---- SETUP ------------------------------------------------------------------
hdr "SETUP 证书 / 配置 / 拓扑(默认 full-cone)/ 服务(lighthouse+frps+dc+client connd)"
mkdir -p "${E2E_ROOT}/run"
e2e_gen_certs
e2e_render_configs
topo_up
# 基础可达性
if ns "$NS_CLI" ping -c2 -W2 "$LH_BB" >/dev/null 2>&1 && ns "$NS_DC" ping -c2 -W2 "$LH_BB" >/dev/null 2>&1; then
  info "client/dc 经各自 NAT 可达 lighthouse backbone ${LH_BB}"
else
  fail "节点无法经 NAT 到达 lighthouse — 拓扑/转发异常"; exit 1
fi
e2e_start_services
info "服务已起:lighthouse+frps(pub)/ git+nebula+frpc(dc)/ frpc-visitor+connd(client)"
info "connd 固定本地端点 127.0.0.1:${E2E_PROXY_PORT};数据中心 overlay ${DC_OVL}:${E2E_GIT_PORT}"

# =============================================================================
# 场景 A —— full-cone NAT:connd 稳定 T0 直连
# =============================================================================
hdr "场景A  full-cone NAT → 期望 connd 稳定 T0 直连(viaVps=false),git 通"
set_client_nat fullcone
info "客户端路由器 = full-cone NAT;等 nebula 打洞 + connd 升级到 T0(滞后窗口)..."
A_TIER="$(e2e_wait_tier '^T0$' 60 2)"
dump
A_VIA="$(e2e_status_field viaVps)"; A_CR="$(e2e_status_field currentRemote)"
A_PS="$(peer_state "$DC_OVL")"
info "客户端看数据中心 hostmap: ${A_PS}"
if [[ "$A_TIER" == "T0" ]]; then pass "场景A tier=T0(直连)"; else fail "场景A 未到 T0(tier=$A_TIER)"; fi
if [[ "$A_VIA" == "false" ]]; then pass "场景A viaVps=false(不经 VPS)"; else fail "场景A viaVps 应为 false(=$A_VIA)"; fi
# currentRemote 应是数据中心 NAT 公网映射(RD_PUB:4242),而非 lighthouse。
if [[ "$A_CR" == "${RD_PUB}:${E2E_PORT}" ]]; then
  pass "场景A currentRemote=${RD_PUB}:${E2E_PORT}(数据中心 NAT 映射,真直连)"
else
  info "场景A currentRemote=$A_CR(期望 ${RD_PUB}:${E2E_PORT};非 lighthouse 即视为直连端点)"
  [[ -n "$A_CR" && "$A_CR" != "${LH_BB}:${E2E_PORT}" ]] && pass "场景A currentRemote 非 lighthouse(直连端点)" || fail "场景A currentRemote 异常($A_CR)"
fi
if e2e_git_ok; then pass "场景A git ls-remote 经本地端点成功(T0 overlay 直达)"; else fail "场景A git ls-remote 失败"; fi

# =============================================================================
# 场景 B —— 对称 NAT:打洞必失败,connd 落 T1 UDP 中继
# =============================================================================
hdr "场景B  对称 NAT(打洞必失败)→ 期望 connd 落 T1 UDP 中继(viaVps=true),git 通"
set_client_nat symmetric
info "客户端路由器 = 对称 NAT(普通 MASQUERADE,逐目的不同源端口);等 connd 降到 T1..."
# 对称 NAT 下 T0 不可达;若刚才在 T0,connd 需降级到 T1(经 N 次失败 + hostmap relay)。
B_TIER="$(e2e_wait_tier '^T1$' 50)"
dump
B_VIA="$(e2e_status_field viaVps)"
B_PS="$(peer_state "$DC_OVL")"
info "客户端看数据中心 hostmap: ${B_PS}(对称 NAT 下应为 RELAY / 无直连 currentRemote)"
if [[ "$B_TIER" == "T1" ]]; then pass "场景B tier=T1(UDP 中继)"; else fail "场景B 未落 T1(tier=$B_TIER)"; fi
if [[ "$B_VIA" == "true" ]]; then pass "场景B viaVps=true(经 VPS relay)"; else fail "场景B viaVps 应为 true(=$B_VIA)"; fi
if e2e_git_ok; then pass "场景B git ls-remote 仍成功(T1 中继兜底,overlay 仍通)"; else fail "场景B git ls-remote 失败"; fi

# =============================================================================
# 场景 C —— 封死 UDP:connd 落 T2 TCP 兜底
# =============================================================================
hdr "场景C  封死 UDP → 期望 connd 落 T2 TCP 兜底(viaVps=true),git 仍通"
set_client_nat blockudp
info "客户端路由器 = DROP 所有 underlay UDP(含 lighthouse 4242);等 connd 降到 T2..."
C_TIER="$(e2e_wait_tier '^T2$' 50)"
dump
C_VIA="$(e2e_status_field viaVps)"; C_UP="$(e2e_status_field upstream)"
if [[ "$C_TIER" == "T2" ]]; then pass "场景C tier=T2(TCP 兜底)"; else fail "场景C 未落 T2(tier=$C_TIER)"; fi
if [[ "$C_VIA" == "true" ]]; then pass "场景C viaVps=true(经 VPS frps)"; else fail "场景C viaVps 应为 true(=$C_VIA)"; fi
if [[ "$C_UP" == "127.0.0.1:${E2E_VISITOR_PORT}" ]]; then
  pass "场景C upstream=127.0.0.1:${E2E_VISITOR_PORT}(frpc visitor 本地口 = T2 后端)"
else
  info "场景C upstream=$C_UP"
fi
# 真兜底证据:此刻 overlay 直达数据中心应不通(UDP 封死),但本地端点 git 仍通(走 frp TCP)。
if ! ns "$NS_CLI" ping -c1 -W2 "$DC_OVL" >/dev/null 2>&1; then
  pass "场景C overlay 直达数据中心已断(ping ${DC_OVL} 失败)—— UDP 确已封死"
else
  fail "场景C overlay 仍通(UDP 未真正封死,T2 兜底未被证明)"
fi
if e2e_git_ok; then pass "场景C git ls-remote 仍成功(经【同一本地端点】走 frp TCP 隧道)"; else fail "场景C git ls-remote 失败"; fi

# =============================================================================
# 场景 D —— 恢复(C→B→A):逐级升回
# =============================================================================
hdr "场景D  恢复 C→B→A:逐级升回(滞后窗口后回到该 NAT 应有最高层)"

info "D1) 解封 UDP,但仍对称 NAT(C→B):期望升回 T1(不到 T0,因对称 NAT 打洞仍失败)"
set_client_nat symmetric
D1_TIER="$(e2e_wait_tier '^T1$' 50)"
dump
if [[ "$D1_TIER" == "T1" ]]; then pass "场景D1 从 T2 升回 T1(UDP 恢复但对称 NAT 仍无直连)"; else fail "场景D1 未升回 T1(tier=$D1_TIER)"; fi
if e2e_git_ok; then pass "场景D1 git 仍通"; else fail "场景D1 git 失败"; fi

info "D2) 恢复 full-cone NAT(B→A):期望逐级升回 T0 直连(高速灌包驱动 try_promote)"
set_client_nat fullcone
D2_TIER="$(e2e_wait_tier '^T0$' 90 2)"
dump
D2_VIA="$(e2e_status_field viaVps)"
if [[ "$D2_TIER" == "T0" ]]; then pass "场景D2 升回 T0 直连(full-cone 恢复后回到最高层)"; else fail "场景D2 未升回 T0(tier=$D2_TIER)"; fi
if [[ "$D2_VIA" == "false" ]]; then pass "场景D2 viaVps=false(回到不经 VPS 的直连)"; else fail "场景D2 viaVps 应为 false(=$D2_VIA)"; fi
if e2e_git_ok; then pass "场景D2 git ls-remote 仍成功(全程透明,引擎无感)"; else fail "场景D2 git 失败"; fi

# =============================================================================
# 汇总
# =============================================================================
hdr "汇总(Phase5 完整三层阶梯 e2e)"
echo "  场景A full-cone→T0 / 场景B 对称→T1 / 场景C 封UDP→T2 / 场景D 恢复逐级升回"
echo "  PASS=${PASS}  FAIL=${FAIL}"
if [[ "$FAIL" -eq 0 ]]; then echo "  ====> 全部场景断言 PASS"; exit 0
else echo "  ====> 有 ${FAIL} 项 FAIL"; exit 1; fi
