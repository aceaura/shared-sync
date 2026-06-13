#!/usr/bin/env bash
#
# gen-certs.sh — 生成 Nebula CA 与各节点证书(幂等)
#
# 设计要点:
#   * 不要求本机安装 nebula/nebula-cert。全部通过官方镜像 nebulaoss/nebula 里的
#     nebula-cert 完成。该镜像是 distroless 风格(无 shell),二进制位于 /nebula-cert,
#     因此用 --entrypoint /nebula-cert 直接调用。
#   * 产物写到 v2/nebula/certs/,通过 docker -v 卷挂载映射到容器内 /out。
#   * 幂等:已存在的 ca.crt / <node>.crt 不会被覆盖(除非 FORCE=1)。
#   * overlay 网段 10.77.0.0/24:
#       lighthouse   = 10.77.0.1
#       node-home    = 10.77.0.2
#       node-company = 10.77.0.3
#
# 用法:
#   bash v2/nebula/gen-certs.sh           # 幂等生成缺失的证书
#   FORCE=1 bash v2/nebula/gen-certs.sh   # 强制重新生成全部(会先清空 certs/)
#
# 注意:*.key 是私钥,已在根 .gitignore 忽略,切勿入库。
#
set -euo pipefail

# ---- 可调参数 ----------------------------------------------------------------
IMAGE="${NEBULA_IMAGE:-nebulaoss/nebula:latest}"
NETWORK_CIDR="${NETWORK_CIDR:-10.77.0.0/24}"
CA_NAME="${CA_NAME:-shared-sync-v2 CA}"
# CA 与节点证书有效期(nebula-cert 默认 CA 8760h=1y;这里放宽,便于长期开发)
CA_DURATION="${CA_DURATION:-87600h}"   # 10 年
# 节点证书有效期不填时默认为「比 CA 早 1 秒过期」,这里显式给一个较长值
NODE_DURATION="${NODE_DURATION:-43800h}" # 5 年

# 节点定义:"<name>:<overlay-ip>"
NODES=(
  "lighthouse:10.77.0.1"
  "node-home:10.77.0.2"
  "node-company:10.77.0.3"
)

# ---- 路径解析 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/certs"

# ---- 依赖检查 ----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 需要 docker(本脚本通过容器内 nebula-cert 生成证书,无需本机装 nebula)" >&2
  exit 1
fi

# nebula-cert 的容器封装。把 CERTS_DIR 挂到 /out,工作目录设为 /out。
# --entrypoint /nebula-cert 覆盖默认的 /nebula 入口。
nc() {
  docker run --rm \
    -v "${CERTS_DIR}:/out" \
    -w /out \
    --entrypoint /nebula-cert \
    "${IMAGE}" "$@"
}

mkdir -p "${CERTS_DIR}"

if [[ "${FORCE:-0}" == "1" ]]; then
  echo ">> FORCE=1:清空 ${CERTS_DIR}"
  rm -f "${CERTS_DIR}"/*.crt "${CERTS_DIR}"/*.key 2>/dev/null || true
fi

# ---- 1. CA ------------------------------------------------------------------
if [[ -f "${CERTS_DIR}/ca.crt" && -f "${CERTS_DIR}/ca.key" ]]; then
  echo ">> CA 已存在,跳过(FORCE=1 可重建):${CERTS_DIR}/ca.crt"
else
  echo ">> 生成 CA: name='${CA_NAME}' duration=${CA_DURATION}"
  # -networks 限制后续子证书只能落在该网段内(cert format v2)。
  nc ca \
    -name "${CA_NAME}" \
    -duration "${CA_DURATION}" \
    -networks "${NETWORK_CIDR}" \
    -out-crt ca.crt \
    -out-key ca.key
fi

# ---- 2. 各节点证书 -----------------------------------------------------------
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"
  crt="${CERTS_DIR}/${name}.crt"
  key="${CERTS_DIR}/${name}.key"

  if [[ -f "${crt}" && -f "${key}" ]]; then
    echo ">> 节点 ${name} 证书已存在,跳过:${crt}"
    continue
  fi

  # overlay IP 必须带网段掩码(/24),nebula 据此配置 tun 网卡路由。
  echo ">> 签发节点证书 ${name} -> ${ip}/24"
  nc sign \
    -ca-crt ca.crt \
    -ca-key ca.key \
    -name "${name}" \
    -networks "${ip}/24" \
    -duration "${NODE_DURATION}" \
    -out-crt "${name}.crt" \
    -out-key "${name}.key"
done

# ---- 3. 收尾 / 校验 ----------------------------------------------------------
echo
echo ">> 产物清单(${CERTS_DIR}):"
ls -la "${CERTS_DIR}"

echo
echo ">> CA 证书摘要:"
nc print -path ca.crt

echo
echo ">> 验证各节点证书由该 CA 签发:"
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  echo "--- ${name} ---"
  nc print -path "${name}.crt"
  nc verify -ca ca.crt -crt "${name}.crt" && echo "verify: OK (${name})"
done

echo
echo ">> 完成。提醒:*.key 为私钥,已被 .gitignore 忽略,请勿提交。"
