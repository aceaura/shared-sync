#!/usr/bin/env bash
#
# run-node.sh — 在本机以容器方式拉起一个 Nebula 节点(home/company),接入指定 lighthouse。
# 用于开发/验证:容器自带 ping/git/curl,可在其中验证 overlay 连通与 shared-sync。
# (生产形态由 connd 原生管理 nebula 进程;本脚本是 Phase1 的便捷验证工具。)
#
# 前置:已用 v2/nebula/gen-certs.sh 生成 certs;本机 docker 可用。
#
# 用法:
#   v2/deploy/run-node.sh <home|company> <lighthouse公网IP>
#   例:v2/deploy/run-node.sh home 54.198.93.78
#
set -euo pipefail

NODE="${1:-}"
LH_IP="${2:-}"
[ -n "$NODE" ] && [ -n "$LH_IP" ] || { echo "用法: $0 <home|company> <lighthouse公网IP>"; exit 1; }
case "$NODE" in home|company) ;; *) echo "节点名只能是 home 或 company"; exit 1;; esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NEBULA_DIR="$ROOT/v2/nebula"
CERTS="$NEBULA_DIR/certs"
CN="node-$NODE"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in ca.crt "$CN.crt" "$CN.key"; do
  [ -f "$CERTS/$f" ] || { echo "缺少 $CERTS/$f —— 先跑 v2/nebula/gen-certs.sh"; exit 1; }
done

# 渲染节点配置
sed -e "s/__NODE_CERT__/$CN.crt/" -e "s/__NODE_KEY__/$CN.key/" -e "s/__LIGHTHOUSE_IP__/$LH_IP/" \
  "$NEBULA_DIR/config/node.yml.tmpl" > "$WORK/$CN.yml"
cp "$CERTS/ca.crt" "$CERTS/$CN.crt" "$CERTS/$CN.key" "$WORK/"

# 构建带工具的镜像(若不存在)
if ! docker image inspect sharedsync/nb-tools >/dev/null 2>&1; then
  echo "构建 sharedsync/nb-tools 镜像 ..."
  BUILDCTX="$(mktemp -d)"; cp "$ROOT/v2/deploy/Dockerfile.nbtools" "$BUILDCTX/Dockerfile"
  docker build -t sharedsync/nb-tools "$BUILDCTX" >/dev/null
  rm -rf "$BUILDCTX"
fi

CONTAINER="nb-$NODE"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --cap-add NET_ADMIN --device /dev/net/tun \
  -v "$WORK:/etc/nebula:ro" sharedsync/nb-tools -config "/etc/nebula/$CN.yml" >/dev/null

# 注意:容器以 ro 挂载临时目录;容器存活期间 trap 不能删它,故复制到持久位置
PERSIST="$HOME/.shared-sync-v2/$CONTAINER"
mkdir -p "$PERSIST"; cp "$WORK"/* "$PERSIST/"
docker rm -f "$CONTAINER" >/dev/null 2>&1
docker run -d --name "$CONTAINER" --cap-add NET_ADMIN --device /dev/net/tun \
  -v "$PERSIST:/etc/nebula:ro" sharedsync/nb-tools -config "/etc/nebula/$CN.yml" >/dev/null

sleep 5
OVERLAY=$(docker exec "$CONTAINER" ip -4 addr show nebula1 2>/dev/null | awk '/inet /{print $2}')
echo "✅ $CONTAINER 已启动,overlay=$OVERLAY"
echo "   验证连通: docker exec $CONTAINER ping -c3 10.77.0.1"
echo "   进容器:   docker exec -it $CONTAINER bash"
