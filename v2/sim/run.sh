#!/usr/bin/env bash
# =============================================================================
# run.sh — shared-sync v2 双 NAT 模拟环境一键验证
#
# 三步,全部用 docker 实跑,逐步打印 PASS/FAIL,结束自动清理:
#   STEP1  平面拓扑:3 个 nebula 容器同网,证明 Nebula 链路/证书/配置本身通。
#   STEP2  双 NAT 拓扑:home/company 各在独立 private 段、经各自 router NAT 出公网,
#          两 private 段之间无直连路由,只能经 public 段的 lighthouse 相遇。
#          验证 overlay 互通 + 判定 direct/relay。
#   STEP3  中继兜底 + shared-sync 端到端:
#            3a  在 router 上阻断两 private 段直连 UDP(强制 relay),验证 overlay 仍通;
#            3b  company 经 overlay IP 对 home 上的 shared-sync 服务端 clone/push;
#            3c  解除阻断,验证 overlay 仍通(本环境恒为 relay,见 README 局限说明)。
#
# 用法:
#   bash v2/sim/run.sh            # 跑全部三步并清理
#   KEEP=1 bash v2/sim/run.sh     # 跑完不清理(便于手动排查)
#   SKIP_BUILD=1 bash v2/sim/run.sh
#
# 退出码:全部关键断言通过=0;任一关键断言失败=1。
# 注意:direct 打洞在本 docker 拓扑无法收敛(见 README「已知局限」),
#       脚本把 direct 判定为【非关键】信息项,不作为 FAIL。
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
export PATH="/opt/homebrew/bin:${PATH}"

FLAT="docker-compose.flat.yml"
NAT="docker-compose.nat.yml"

OVERLAY_HOME="10.77.0.2"
OVERLAY_COMPANY="10.77.0.3"
REPO_URL="http://${OVERLAY_HOME}:8418/shared.git"

# router public IP(BLOCK_DIRECT 用)
HOME_PUB="10.88.0.2"
COMPANY_PUB="10.88.0.3"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }
hdr()  { echo; echo "==================== $* ===================="; }

# 等待:在 home 上 ping 通 company overlay,最多 N 秒。返回 0=通。
wait_overlay() {
  local from="$1" target="$2" timeout="${3:-40}" i
  for ((i=0; i<timeout; i++)); do
    if docker exec "$from" ping -c 1 -W 1 "$target" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo; echo ">> KEEP=1:保留环境。手动清理:"
    echo "   docker compose -f ${SCRIPT_DIR}/${FLAT} down -v"
    echo "   docker compose -f ${SCRIPT_DIR}/${NAT}  down -v"
    return
  fi
  echo; echo ">> 清理所有 sim 容器/网络 ..."
  docker compose -f "${FLAT}" down -v >/dev/null 2>&1 || true
  docker compose -f "${NAT}"  down -v >/dev/null 2>&1 || true
  echo ">> 清理完成。"
}
trap cleanup EXIT

# ---- 前置:证书存在 ----------------------------------------------------------
if [[ ! -f ../nebula/certs/ca.crt ]]; then
  echo ">> 未发现证书,先运行 v2/nebula/gen-certs.sh ..."
  bash ../nebula/gen-certs.sh >/dev/null 2>&1 || { echo "gen-certs 失败"; exit 1; }
fi

# ---- 构建镜像 ----------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  hdr "BUILD 镜像"
  docker build -t sharedsync-sim-node   -f Dockerfile.node   . >/dev/null 2>&1 && info "node 镜像就绪"   || { fail "node 镜像构建失败"; exit 1; }
  docker build -t sharedsync-sim-router -f Dockerfile.router . >/dev/null 2>&1 && info "router 镜像就绪" || { fail "router 镜像构建失败"; exit 1; }
  # 预拉 shared-sync 服务端(端到端用)
  docker pull ghcr.io/aceaura/shared-sync-server:1.0.0 >/dev/null 2>&1 || info "warn: 预拉 shared-sync-server 失败(STEP3b 可能受影响)"
fi

# 进场先清干净,避免上次残留
docker compose -f "${FLAT}" down -v >/dev/null 2>&1 || true
docker compose -f "${NAT}"  down -v >/dev/null 2>&1 || true

# =============================================================================
# STEP 1 — 平面拓扑
# =============================================================================
hdr "STEP 1 平面拓扑(证明 Nebula 链路本身通)"
docker compose -f "${FLAT}" up -d >/dev/null 2>&1
info "等待 nebula 握手 ..."
if wait_overlay sim-flat-home "${OVERLAY_COMPANY}" 40; then
  echo "  ---- ping home -> company(${OVERLAY_COMPANY})----"
  docker exec sim-flat-home ping -c 4 -W 2 "${OVERLAY_COMPANY}" 2>&1 | sed 's/^/    /'
  pass "STEP1 平面拓扑 overlay 互通(证书/配置正确)"
else
  echo "  ---- home 日志尾部 ----"; docker logs sim-flat-home 2>&1 | tail -15 | sed 's/^/    /'
  fail "STEP1 平面拓扑 overlay 不通"
fi
docker compose -f "${FLAT}" down -v >/dev/null 2>&1 || true

# =============================================================================
# STEP 2 — 双 NAT 拓扑
# =============================================================================
hdr "STEP 2 双 NAT 拓扑(核心:经 lighthouse 打通两 NAT 私网)"
BLOCK_DIRECT=0 docker compose -f "${NAT}" up -d >/dev/null 2>&1
info "等待发现 + 打洞/relay 建链(最多 60s)..."
if wait_overlay sim-nat-home "${OVERLAY_COMPANY}" 60; then
  echo "  ---- ping home -> company(${OVERLAY_COMPANY})under double-NAT ----"
  docker exec sim-nat-home ping -c 5 -W 3 "${OVERLAY_COMPANY}" 2>&1 | sed 's/^/    /'
  pass "STEP2 双 NAT 下 overlay 互通"
else
  echo "  ---- home 日志尾部 ----"; docker logs sim-nat-home 2>&1 | tail -20 | sed 's/^/    /'
  fail "STEP2 双 NAT 下 overlay 不通"
fi

# ---- direct / relay 判定(非关键信息项)-------------------------------------
# 判据:在 router-home 的 conntrack 上找"去往对端 router public IP(10.88.0.3)
#       且 4242"的【已回包(非 UNREPLIED)】UDP 流 => direct;否则 => relay。
info "判定 direct / relay(基于 router-home conntrack)..."
docker exec sim-nat-home ping -c 6 -i 0.2 -W 2 "${OVERLAY_COMPANY}" >/dev/null 2>&1 || true
CT="$(docker exec sim-nat-router-home sh -c 'cat /proc/net/nf_conntrack 2>/dev/null')"
DIRECT_FLOW="$(echo "${CT}" | grep -E "dst=${COMPANY_PUB}.*(dport=4242|sport=4242)" | grep -v UNREPLIED || true)"
LH_FLOW="$(echo "${CT}" | grep -E "10.88.0.10.*(dport=4242|sport=4242)" | grep -v UNREPLIED || true)"
if [[ -n "${DIRECT_FLOW}" ]]; then
  info "判定 = DIRECT(发现去往 ${COMPANY_PUB}:4242 的已回包 UDP 流):"
  echo "${DIRECT_FLOW}" | head -2 | sed 's/^/    /'
else
  info "判定 = RELAY(无直连 ${COMPANY_PUB}:4242 已回包流;仅 lighthouse 10.88.0.10 流活跃):"
  echo "${LH_FLOW}" | head -2 | sed 's/^/    /'
  info "  注:direct 打洞在本 docker 拓扑无法收敛,属已知局限(见 README),不计为 FAIL。"
fi

# =============================================================================
# STEP 3a — 阻断直连 UDP,强制 relay,验证 overlay 仍通
# =============================================================================
hdr "STEP 3a 阻断两 private 段直连 UDP(强制 relay)"
# 在两 router 的 FORWARD 上丢弃彼此 public IP 之间的 UDP;放行去 lighthouse 的 UDP。
docker exec sim-nat-router-home sh -c "iptables -A FORWARD -o eth1 -p udp -d ${COMPANY_PUB} -j DROP; iptables -A FORWARD -i eth1 -p udp -s ${COMPANY_PUB} -j DROP" >/dev/null 2>&1
docker exec sim-nat-router-company sh -c "iptables -A FORWARD -o eth1 -p udp -d ${HOME_PUB} -j DROP; iptables -A FORWARD -i eth1 -p udp -s ${HOME_PUB} -j DROP" >/dev/null 2>&1
info "已在 router 上阻断 ${HOME_PUB}<->${COMPANY_PUB} 的 UDP(只保留经 lighthouse 的 relay 路径)"
sleep 3
if docker exec sim-nat-home ping -c 5 -W 3 "${OVERLAY_COMPANY}" >/dev/null 2>&1; then
  echo "  ---- ping home -> company(阻断直连后,relay 兜底)----"
  docker exec sim-nat-home ping -c 5 -W 3 "${OVERLAY_COMPANY}" 2>&1 | sed 's/^/    /'
  pass "STEP3a 阻断直连后 overlay 仍通(relay 兜底)"
else
  fail "STEP3a 阻断直连后 overlay 不通(relay 兜底失败)"
fi

# =============================================================================
# STEP 3b — shared-sync 经 overlay 的 clone / push
# =============================================================================
hdr "STEP 3b shared-sync 经 overlay clone/push(relay 模式)"
# 关键:sharedsync-server 以 network_mode: service:home 复用 home 的 netns。
# 若上面没有重启过 home(本脚本不重启),server 与 home netns 一致即可直接用。
# 等待 server 的 nginx 就绪(home netns 内本地 :80)。
info "等待 shared-sync 服务端就绪 ..."
SRV_OK=0
for i in $(seq 1 20); do
  CODE="$(docker exec sim-nat-home sh -c 'curl -s -m3 -o /dev/null -w "%{http_code}" http://127.0.0.1:80/shared.git/info/refs?service=git-upload-pack 2>/dev/null' || echo 000)"
  [[ "${CODE}" == "200" ]] && { SRV_OK=1; break; }
  sleep 1
done
[[ "${SRV_OK}" == "1" ]] && info "服务端 nginx 就绪(home netns :80 -> 200)" || info "warn: 服务端本地探测未 200,继续尝试 overlay"

# company 经 overlay :8418 做 clone + commit + push + 复 clone 校验
GIT_OUT="$(docker exec sim-nat-company sh -c '
set -e
export GIT_TERMINAL_PROMPT=0
git config --global user.email sim@shared-sync.test
git config --global user.name sim
git config --global init.defaultBranch current
cd /tmp && rm -rf c1 c2
git clone "'"${REPO_URL}"'" c1 2>&1
cd c1
git checkout -B current 2>/dev/null || true
echo "hello-over-overlay $(date -u +%s)" > file-from-company.txt
git add -A && git commit -m "company over overlay" >/dev/null 2>&1
git push -u origin current 2>&1
cd /tmp && git clone "'"${REPO_URL}"'" c2 2>&1
test -f c2/file-from-company.txt && echo "VERIFY_FILE_OK" || echo "VERIFY_FILE_MISSING"
' 2>&1)"
echo "${GIT_OUT}" | sed 's/^/    /'
if echo "${GIT_OUT}" | grep -q 'VERIFY_FILE_OK' && echo "${GIT_OUT}" | grep -qE '\* \[new branch\]|->.*current'; then
  pass "STEP3b shared-sync 经 overlay clone/push 成功(同步流量跑在 overlay 上)"
else
  fail "STEP3b shared-sync 经 overlay clone/push 失败"
fi

# =============================================================================
# STEP 3c — 解除阻断,验证 overlay 仍通(本环境恒 relay)
# =============================================================================
hdr "STEP 3c 解除阻断(验证恢复后仍互通)"
docker exec sim-nat-router-home sh -c "iptables -D FORWARD -o eth1 -p udp -d ${COMPANY_PUB} -j DROP; iptables -D FORWARD -i eth1 -p udp -s ${COMPANY_PUB} -j DROP" >/dev/null 2>&1 || true
docker exec sim-nat-router-company sh -c "iptables -D FORWARD -o eth1 -p udp -d ${HOME_PUB} -j DROP; iptables -D FORWARD -i eth1 -p udp -s ${HOME_PUB} -j DROP" >/dev/null 2>&1 || true
info "已解除阻断"
sleep 3
if docker exec sim-nat-home ping -c 4 -W 3 "${OVERLAY_COMPANY}" >/dev/null 2>&1; then
  docker exec sim-nat-home ping -c 4 -W 3 "${OVERLAY_COMPANY}" 2>&1 | sed 's/^/    /'
  pass "STEP3c 解除阻断后 overlay 仍互通"
  info "  说明:真实环境此时应自动切回 direct;本 docker 拓扑恒走 relay(见 README 局限),"
  info "        connd 的 DIRECT⇄FALLBACK 切回逻辑属 v2 Phase1,本模拟只验证 relay 兜底链路。"
else
  fail "STEP3c 解除阻断后 overlay 不通"
fi

# =============================================================================
# 汇总
# =============================================================================
hdr "汇总"
echo "  PASS=${PASS}  FAIL=${FAIL}"
if [[ "${FAIL}" -eq 0 ]]; then
  echo "  ====> 全部关键断言 PASS"
  exit 0
else
  echo "  ====> 有 ${FAIL} 项 FAIL"
  exit 1
fi
