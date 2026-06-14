#!/usr/bin/env bash
# =============================================================================
# run-datacenter.sh —— 在本机用一个【常驻容器】跑 v2 数据中心(开发/小规模用)。
#
# 一个容器即数据中心三件套(复用 v2/frp 的 Dockerfile.datacenter):
#   * git server(生产镜像,容器内 :80)—— 权威 current 分支。
#   * nebula 节点 datacenter=10.77.0.2 —— 客户端经 overlay 直达(T0/T1)。
#   * frpc(STCP 服务端)—— 把 git 注册到 VPS frps(客户端经 T2 也达)。
#
# 生产 Linux 节点请改用 v2/install/install-datacenter.sh(systemd)。本脚本是 macOS/本机便捷版。
#
# 前置:docker;v2/nebula/gen-certs.sh sign datacenter;v2/frp/secret.env。
# 用法:bash v2/deploy/run-datacenter.sh [lighthouse公网IP]   (默认 54.198.93.78)
#       bash v2/deploy/run-datacenter.sh --stop
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CERTS="$ROOT/v2/nebula/certs"
FRP_DIR="$ROOT/v2/frp"
SECRET_ENV="$FRP_DIR/secret.env"
LH_IP="${1:-54.198.93.78}"
GIT_PORT=80
FRP_VERSION="${FRP_VERSION:-0.69.1}"
DC=ss-datacenter
IMG=sharedsync/datacenter

if [[ "${1:-}" == "--stop" ]]; then
  docker rm -f "$DC" >/dev/null 2>&1 && echo "已停止数据中心容器 $DC" || echo "$DC 未在运行"
  exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "需要 docker"; exit 1; }
for f in ca.crt datacenter.crt datacenter.key; do
  [[ -f "$CERTS/$f" ]] || { echo "缺 $CERTS/$f —— 先跑 v2/nebula/gen-certs.sh sign datacenter"; exit 1; }
done
[[ -f "$SECRET_ENV" ]] || { echo "缺 $SECRET_ENV"; exit 1; }
# shellcheck source=/dev/null
source "$SECRET_ENV"; : "${FRP_AUTH_TOKEN:?}"; : "${FRP_STCP_SECRET:?}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dc"

case "$(uname -m)" in aarch64|arm64) GOARCH=arm64 ;; *) GOARCH=amd64 ;; esac
echo ">> 取 frpc linux/$GOARCH(容器内用)"
curl -fsSL -m 120 -o "$WORK/frp.tgz" "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${GOARCH}.tar.gz"
tar xzf "$WORK/frp.tgz" -C "$WORK"
cp "$WORK/frp_${FRP_VERSION}_linux_${GOARCH}/frpc" "$WORK/frpc"

echo ">> 渲染数据中心配置(datacenter=10.77.0.2,lighthouse=$LH_IP)"
sed -e "s#__NODE_CERT__#datacenter.crt#" -e "s#__NODE_KEY__#datacenter.key#" -e "s#__LIGHTHOUSE_IP__#$LH_IP#" \
  "$FRP_DIR/config/node-datacenter.yml.tmpl" > "$WORK/dc/node.yml"
sed -e "s#__FRP_SERVER_ADDR__#$LH_IP#" -e "s#__FRP_AUTH_TOKEN__#$FRP_AUTH_TOKEN#" \
    -e "s#__FRP_STCP_SECRET__#$FRP_STCP_SECRET#" -e "s#__GIT_LOCAL_ADDR__#127.0.0.1#" -e "s#__GIT_LOCAL_PORT__#$GIT_PORT#" \
  "$FRP_DIR/config/frpc-datacenter.toml" > "$WORK/dc/frpc.toml"
cp "$CERTS/ca.crt" "$CERTS/datacenter.crt" "$CERTS/datacenter.key" "$WORK/dc/"

echo ">> 构建数据中心镜像 $IMG"
cp "$FRP_DIR/Dockerfile.datacenter" "$FRP_DIR/datacenter-entrypoint.sh" "$WORK/"
docker build -t "$IMG" -f "$WORK/Dockerfile.datacenter" "$WORK" >/dev/null

echo ">> 启动常驻数据中心容器 $DC"
docker rm -f "$DC" >/dev/null 2>&1 || true
docker run -d --name "$DC" --restart unless-stopped \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -e NEBULA_ENABLED=1 -e GIT_PORT="$GIT_PORT" \
  -v "$WORK/dc:/etc/nebula:ro" -v "$WORK/dc:/etc/frp:ro" \
  "$IMG" >/dev/null

echo ">> 等就绪(nebula overlay + frpc STCP 注册)"
for i in $(seq 1 40); do
  docker logs "$DC" 2>&1 | grep -q "start proxy success" && break
  sleep 1
done
echo "--- 数据中心状态 ---"
docker exec "$DC" sh -c 'ip -4 addr show nebula1 2>/dev/null | awk "/inet /{print \"overlay=\"\$2}"' || true
docker logs "$DC" 2>&1 | grep -E "start proxy success|当前 refs|refs/heads/current" | tail -3
echo
echo "✅ 数据中心常驻(容器 $DC,--restart unless-stopped)。overlay 10.77.0.2,git=current 分支。"
echo "   客户端 server_url 经各自 connd 本地端点 → 同步到此。停止:bash v2/deploy/run-datacenter.sh --stop"
