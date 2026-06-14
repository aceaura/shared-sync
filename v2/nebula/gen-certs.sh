#!/usr/bin/env bash
#
# gen-certs.sh — 生成 Nebula CA 与各节点证书(幂等,角色化)
#
# 设计要点:
#   * 不要求本机安装 nebula/nebula-cert。全部通过官方镜像 nebulaoss/nebula 里的
#     nebula-cert 完成。该镜像是 distroless 风格(无 shell),二进制位于 /nebula-cert,
#     因此用 --entrypoint /nebula-cert 直接调用。
#   * 产物写到 v2/nebula/certs/,通过 docker -v 卷挂载映射到容器内 /out。
#   * 幂等:已存在的 ca.crt / <node>.crt 不会被覆盖(除非 FORCE=1)。
#
# ---------------------------------------------------------------------------
# 星型 IP 规划(DESIGN_v2 §3/§7,Phase4 采用「角色化」命名):
#   lighthouse        = 10.77.0.1      (VPS 公网中转中心)
#   datacenter        = 10.77.0.2      (唯一同步数据中心 / git 权威)
#   client-<名字>     = 10.77.0.11+    (N 个客户端,自动从 .11 起分配,或显式指定)
#
#   「新增客户端 = 跑一次签发(或 v2/deploy/enroll-client.sh),不动其他节点。」
#
# 兼容:保留旧名 node-home(10.77.0.2)/ node-company(10.77.0.3) 供 Phase2/3 脚本复用
#       (它们与新角色名解耦;datacenter 与 node-home 同为 .2,可任选其一当数据中心)。
# ---------------------------------------------------------------------------
#
# 用法:
#   # A) 幂等批量生成「基线」节点(lighthouse + datacenter + 旧名兼容)
#   bash v2/nebula/gen-certs.sh
#   FORCE=1 bash v2/nebula/gen-certs.sh        # 强制重建全部(先清空 certs/)
#
#   # B) 签发任意角色/名字的节点证书(幂等;已存在则跳过)
#   bash v2/nebula/gen-certs.sh sign lighthouse                 # 10.77.0.1
#   bash v2/nebula/gen-certs.sh sign datacenter                 # 10.77.0.2
#   bash v2/nebula/gen-certs.sh sign client-alice               # 自动分配 10.77.0.11+
#   bash v2/nebula/gen-certs.sh sign client-bob 10.77.0.12      # 显式指定 IP
#   bash v2/nebula/gen-certs.sh sign node-laptop 10.77.0.20     # 任意名字/IP
#
#   # C) 仅打印某证书 / 列出已签发节点
#   bash v2/nebula/gen-certs.sh print client-alice
#   bash v2/nebula/gen-certs.sh list
#
# 输出(给上层脚本消费):sign 子命令最后一行打印 "ASSIGNED <name> <ip>/24"。
#
# 注意:*.key 是私钥,已在根 .gitignore 忽略(v2/nebula/certs/),切勿入库。
#
set -euo pipefail

# ---- 可调参数 ----------------------------------------------------------------
IMAGE="${NEBULA_IMAGE:-nebulaoss/nebula:latest}"
NETWORK_CIDR="${NETWORK_CIDR:-10.77.0.0/24}"
CA_NAME="${CA_NAME:-shared-sync-v2 CA}"
CA_DURATION="${CA_DURATION:-87600h}"   # 10 年
NODE_DURATION="${NODE_DURATION:-43800h}" # 5 年

# overlay 网段前缀(用于自动分配客户端 IP)。固定 /24。
NET_PREFIX="${NET_PREFIX:-10.77.0}"
CLIENT_IP_START="${CLIENT_IP_START:-11}"   # 客户端从 .11 起分配

# 「基线」节点定义(无参运行时签发):"<name>:<overlay-ip>"。
#   角色化新名(datacenter)+ 旧名兼容(node-home/node-company)并存。
BASE_NODES=(
  "lighthouse:10.77.0.1"
  "datacenter:10.77.0.2"
  "node-home:10.77.0.2"
  "node-company:10.77.0.3"
)

# ---- 路径解析 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${CERTS_DIR:-${SCRIPT_DIR}/certs}"

# ---- 依赖检查 ----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 需要 docker(本脚本通过容器内 nebula-cert 生成证书,无需本机装 nebula)" >&2
  exit 1
fi

# nebula-cert 的容器封装。把 CERTS_DIR 挂到 /out,工作目录设为 /out。
nc() {
  docker run --rm \
    -v "${CERTS_DIR}:/out" \
    -w /out \
    --entrypoint /nebula-cert \
    "${IMAGE}" "$@"
}

mkdir -p "${CERTS_DIR}"

# ---- CA 确保存在(幂等)------------------------------------------------------
ensure_ca() {
  if [[ -f "${CERTS_DIR}/ca.crt" && -f "${CERTS_DIR}/ca.key" ]]; then
    return 0
  fi
  echo ">> 生成 CA: name='${CA_NAME}' duration=${CA_DURATION}" >&2
  nc ca \
    -name "${CA_NAME}" \
    -duration "${CA_DURATION}" \
    -networks "${NETWORK_CIDR}" \
    -out-crt ca.crt \
    -out-key ca.key
}

# ---- 从某证书读取它已绑定的 overlay IP(无 docker 也可:直接 grep 不行,证书是二进制) -
# 用 nebula-cert print -json 解析 networks 字段第一个地址的 IP 部分。
cert_ip() {
  local name="$1"
  [[ -f "${CERTS_DIR}/${name}.crt" ]] || return 1
  # print -json 输出含 "networks":["10.77.0.11/24"]。grep 出第一个 NET_PREFIX.x。
  nc print -json -path "${name}.crt" 2>/dev/null \
    | grep -oE "${NET_PREFIX//./\\.}\.[0-9]+/[0-9]+" | head -1 | cut -d/ -f1
}

# ---- 自动分配下一个空闲客户端 IP(.11+)--------------------------------------
# 扫描 certs/ 下所有已签发证书占用的 IP,返回第一个未被占用的 .CLIENT_IP_START+。
next_client_ip() {
  local used=() c ip
  shopt -s nullglob
  for c in "${CERTS_DIR}"/*.crt; do
    [[ "$(basename "$c")" == "ca.crt" ]] && continue
    ip="$(cert_ip "$(basename "$c" .crt)" || true)"
    [[ -n "$ip" ]] && used+=("$ip")
  done
  shopt -u nullglob
  local n="$CLIENT_IP_START"
  while :; do
    local cand="${NET_PREFIX}.${n}"
    local taken=0 u
    for u in "${used[@]:-}"; do [[ "$u" == "$cand" ]] && taken=1 && break; done
    [[ "$taken" == "0" ]] && { echo "$cand"; return 0; }
    n=$((n+1))
    [[ "$n" -gt 254 ]] && { echo "ERROR: ${NET_PREFIX}.0/24 客户端 IP 段已满" >&2; return 1; }
  done
}

# ---- 签发单个节点证书(幂等)。echo "ASSIGNED <name> <ip>/24" 给上层消费 --------
sign_node() {
  local name="$1" ip="${2:-}"
  [[ -n "$name" ]] || { echo "ERROR: sign 需要 <name>" >&2; return 2; }
  ensure_ca

  local crt="${CERTS_DIR}/${name}.crt"
  local key="${CERTS_DIR}/${name}.key"

  if [[ -f "${crt}" && -f "${key}" ]]; then
    # 已存在:回读它的 IP,保证幂等且向上层报告真实分配值。
    local existing; existing="$(cert_ip "$name" || true)"
    echo ">> 节点 ${name} 证书已存在,跳过(IP=${existing:-?})" >&2
    echo "ASSIGNED ${name} ${existing:-?}/24"
    return 0
  fi

  # 未指定 IP:若名字像 client-* 则自动分配 .11+;否则报错要求显式 IP。
  if [[ -z "$ip" ]]; then
    if [[ "$name" == client-* ]]; then
      ip="$(next_client_ip)"
    else
      echo "ERROR: 非 client-* 节点需显式给 IP,如:sign ${name} ${NET_PREFIX}.20" >&2
      return 2
    fi
  fi

  echo ">> 签发节点证书 ${name} -> ${ip}/24" >&2
  nc sign \
    -ca-crt ca.crt \
    -ca-key ca.key \
    -name "${name}" \
    -networks "${ip}/24" \
    -duration "${NODE_DURATION}" \
    -out-crt "${name}.crt" \
    -out-key "${name}.key"
  echo "ASSIGNED ${name} ${ip}/24"
}

# ---- list:列出 certs/ 下已签发节点及其 IP -----------------------------------
list_nodes() {
  echo ">> 已签发节点(${CERTS_DIR}):"
  printf '   %-20s %s\n' "NAME" "OVERLAY-IP"
  shopt -s nullglob
  local c name ip
  for c in "${CERTS_DIR}"/*.crt; do
    name="$(basename "$c" .crt)"
    [[ "$name" == "ca" ]] && continue
    ip="$(cert_ip "$name" || echo '?')"
    printf '   %-20s %s\n' "$name" "${ip}/24"
  done
  shopt -u nullglob
}

# =============================================================================
# 子命令分发
# =============================================================================
CMD="${1:-baseline}"
case "$CMD" in
  sign)
    shift
    sign_node "${1:-}" "${2:-}"
    exit 0
    ;;
  print)
    shift
    name="${1:?用法: gen-certs.sh print <name>}"
    nc print -path "${name}.crt"
    exit 0
    ;;
  list)
    list_nodes
    exit 0
    ;;
  baseline)
    : # 落到下方批量基线逻辑
    ;;
  *)
    echo "ERROR: 未知子命令 '$CMD'。用法见脚本头部注释(baseline|sign|print|list)。" >&2
    exit 2
    ;;
esac

# =============================================================================
# baseline:无参 / FORCE 时,批量幂等生成 CA + 基线节点
# =============================================================================
if [[ "${FORCE:-0}" == "1" ]]; then
  echo ">> FORCE=1:清空 ${CERTS_DIR}"
  rm -f "${CERTS_DIR}"/*.crt "${CERTS_DIR}"/*.key 2>/dev/null || true
fi

if [[ -f "${CERTS_DIR}/ca.crt" && -f "${CERTS_DIR}/ca.key" ]]; then
  echo ">> CA 已存在,跳过(FORCE=1 可重建):${CERTS_DIR}/ca.crt"
else
  ensure_ca
fi

for entry in "${BASE_NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"
  sign_node "$name" "$ip" >/dev/null
done

# ---- 收尾 / 校验 ------------------------------------------------------------
echo
echo ">> 产物清单(${CERTS_DIR}):"
ls -la "${CERTS_DIR}"

echo
echo ">> CA 证书摘要:"
nc print -path ca.crt

echo
echo ">> 验证各基线节点证书由该 CA 签发:"
for entry in "${BASE_NODES[@]}"; do
  name="${entry%%:*}"
  echo "--- ${name} ---"
  nc verify -ca ca.crt -crt "${name}.crt" && echo "verify: OK (${name})"
done

echo
list_nodes
echo
echo ">> 完成。提醒:*.key 为私钥,已被 .gitignore 忽略(v2/nebula/certs/),请勿提交。"
echo ">> 新增客户端:bash $(basename "$0") sign client-<名字>   或   v2/deploy/enroll-client.sh <名字> <lighthouse公网IP>"
