#!/usr/bin/env bash
# =============================================================================
# node-entrypoint.sh — nebula 节点容器入口(home / company / lighthouse 复用)
#
# 职责:
#   1) (可选)把默认路由改走本私网的 router,模拟"节点只能经 NAT 出网"。
#      —— 平面拓扑(第一步)不设 ROUTER_IP,跳过这步。
#   2) (可选,仅 home 节点)把 overlay 上到达 :8418 的 TCP 重定向到本机 :80,
#      因为 shared-sync 服务端镜像内部监听 80,而设计约定 overlay 用 8418。
#   3) 渲染 nebula 配置(把模板里的 __LIGHTHOUSE_IP__ 等占位符替换为本拓扑实参)。
#   4) 前台拉起 nebula。SIGUSR1 可让 nebula 打印 hostmap(判定 direct/relay)。
#
# 环境变量:
#   ROLE            lighthouse | node          (必填)
#   NEBULA_CONFIG   容器内配置文件路径          (必填,已挂载)
#   ROUTER_IP       本私网 router 的网关 IP     (选填;设了就改默认路由)
#   REDIRECT_8418   "1" 时启用 8418->80 重定向  (选填;仅 home 节点需要)
#
# 说明:lighthouse.yml 已是成品(无占位符),node 配置由 compose 用环境变量
#       LIGHTHOUSE_PUB_IP 渲染。证书/配置都通过卷挂载进来,本脚本只做运行期编排。
# =============================================================================
set -euo pipefail

log() { echo "[node-entrypoint $(hostname)] $*" >&2; }

# ---- 1. 默认路由走 router(模拟 NAT 出网) -----------------------------------
if [[ -n "${ROUTER_IP:-}" ]]; then
  log "改默认路由 -> ${ROUTER_IP}(经本私网 router 出网,模拟 NAT)"
  # 删除 docker 注入的默认路由(指向 docker 网桥),改指向 router。
  ip route del default 2>/dev/null || true
  ip route add default via "${ROUTER_IP}"
  log "当前路由表:"
  ip route show >&2
fi

# ---- 2. overlay :8418 -> 本机 :80 重定向(仅 home 节点) ----------------------
# shared-sync-server 与本容器共享网络命名空间(network_mode: service:node-home),
# 它监听 0.0.0.0:80。overlay 对端访问 http://10.77.0.2:8418/ 时,
# 数据包从 nebula tun 进入本机协议栈,PREROUTING 阶段把 8418 改写到 80。
if [[ "${REDIRECT_8418:-0}" == "1" ]]; then
  log "启用 overlay :8418 -> :80 重定向(DNAT,供 shared-sync 服务端)"
  # nat 表内核模块在 alpine 上需要时会自动加载;REDIRECT 作用于到达本机的流量。
  iptables -t nat -A PREROUTING -p tcp --dport 8418 -j REDIRECT --to-ports 80
  # 同机自访问(127.0.0.1 不走 PREROUTING),这里不需要,验证从对端发起。
fi

# ---- 3. 渲染 nebula 配置(普通节点) ------------------------------------------
# lighthouse.yml 无占位符,直接用;node 模板里有 __LIGHTHOUSE_IP__。
CFG="${NEBULA_CONFIG:?need NEBULA_CONFIG}"
RUNTIME_CFG=/tmp/nebula-runtime.yml
if grep -q '__LIGHTHOUSE_IP__' "${CFG}" 2>/dev/null; then
  : "${LIGHTHOUSE_PUB_IP:?node 配置需要 LIGHTHOUSE_PUB_IP}"
  : "${NODE_CERT:?need NODE_CERT}"
  : "${NODE_KEY:?need NODE_KEY}"
  log "渲染 node 配置: LIGHTHOUSE_PUB_IP=${LIGHTHOUSE_PUB_IP} cert=${NODE_CERT}"
  sed -e "s/__LIGHTHOUSE_IP__/${LIGHTHOUSE_PUB_IP}/g" \
      -e "s/__NODE_CERT__/${NODE_CERT}/g" \
      -e "s/__NODE_KEY__/${NODE_KEY}/g" \
      "${CFG}" > "${RUNTIME_CFG}"
else
  log "配置无占位符(lighthouse),直接使用"
  cp "${CFG}" "${RUNTIME_CFG}"
fi

# ---- 4. 拉起 nebula ----------------------------------------------------------
log "启动 nebula(config=${RUNTIME_CFG})"
exec /usr/local/bin/nebula -config "${RUNTIME_CFG}"
