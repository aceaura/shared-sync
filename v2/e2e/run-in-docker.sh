#!/usr/bin/env bash
# =============================================================================
# v2/e2e/run-in-docker.sh —— 在 macOS/任意宿主上一键跑 Phase5 e2e
#
# 把整套自洽世界(netns + 真 connd + nebula/frpc/frps + git)封进一个
# --privileged Linux 容器后调用 run.sh。便于在 Mac(无 netns)与未来 CI 复现,
# 全程不碰宿主网络、不连真 VPS、不动生产 nebula-lighthouse/frps/ss-server。
#
# 依赖:docker、go(交叉编译 connd)、nebulaoss/nebula 镜像(提取 nebula/nebula-cert)、
#       frp release tar(提取 frpc/frps;脚本自动下/用缓存)。
#
# 用法:
#   bash run-in-docker.sh            # 构建镜像并跑四场景,结束删容器
#   KEEP=1 bash run-in-docker.sh     # 容器内保留 netns 排查(进容器:docker exec -it ss-e2e bash)
#   bash run-in-docker.sh --cleanup  # 仅删容器/镜像
# =============================================================================
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"

FRP_VERSION="${FRP_VERSION:-0.69.1}"
NEBULA_IMAGE="${NEBULA_IMAGE:-nebulaoss/nebula:latest}"
IMAGE="${IMAGE:-sharedsync/e2e-p5}"
CONTAINER="${CONTAINER:-ss-e2e}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONND_DIR="$ROOT/v2/connd"
WORK="$HOME/.shared-sync-v2/p5"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo ">> 已清理容器 $CONTAINER(未动任何宿主网络/生产 VPS 组件)"
}
if [[ "${1:-}" == "--cleanup" ]]; then cleanup; docker rmi "$IMAGE" >/dev/null 2>&1 || true; rm -rf "$WORK"; exit 0; fi

cleanup
rm -rf "$WORK"; mkdir -p "$WORK/bin"

ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || echo aarch64)"
case "$ARCH" in aarch64|arm64) GOARCH=arm64 ;; x86_64|amd64) GOARCH=amd64 ;; *) GOARCH=arm64 ;; esac
echo ">> 目标架构 linux/$GOARCH"

# ---- 1. 提取 nebula / nebula-cert(从官方镜像;distroless,用 docker cp)------
echo ">> 提取 nebula / nebula-cert(linux/$GOARCH,从 $NEBULA_IMAGE)"
docker image inspect "$NEBULA_IMAGE" >/dev/null 2>&1 || docker pull --platform "linux/$GOARCH" "$NEBULA_IMAGE" >/dev/null
cid="$(docker create --platform "linux/$GOARCH" "$NEBULA_IMAGE")"
docker cp "$cid:/nebula"      "$WORK/bin/nebula"
docker cp "$cid:/nebula-cert" "$WORK/bin/nebula-cert"
docker rm "$cid" >/dev/null

# ---- 2. 准备 frpc / frps(linux release tar)--------------------------------
echo ">> 准备 frpc / frps(linux/$GOARCH v$FRP_VERSION)"
FRPDIR="/tmp/frp_${FRP_VERSION}_linux_${GOARCH}"
if [[ ! -x "$FRPDIR/frpc" || ! -x "$FRPDIR/frps" ]]; then
  curl -sL -m 180 -o /tmp/frp_dl.tgz \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${GOARCH}.tar.gz"
  tar xzf /tmp/frp_dl.tgz -C /tmp
fi
cp "$FRPDIR/frpc" "$WORK/bin/frpc"
cp "$FRPDIR/frps" "$WORK/bin/frps"

# ---- 3. 交叉编译 connd ------------------------------------------------------
echo ">> 交叉编译 connd(linux/$GOARCH)"
( cd "$CONND_DIR" && GOOS=linux GOARCH="$GOARCH" CGO_ENABLED=0 go build -o "$WORK/bin/connd" ./cmd/connd )

# ---- 4. 拷脚本 + Dockerfile,构建镜像 --------------------------------------
cp "$SCRIPT_DIR/lib.sh" "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/Dockerfile" "$WORK/"
echo ">> 构建 e2e 镜像 $IMAGE"
docker build --platform "linux/$GOARCH" -t "$IMAGE" "$WORK" >/dev/null

# ---- 5. 跑 e2e(privileged,内部全自洽)------------------------------------
echo ">> 启动 --privileged 容器跑四场景(KEEP=${KEEP:-0})"
set +e
docker run --name "$CONTAINER" --privileged \
  -e KEEP="${KEEP:-0}" \
  --device /dev/net/tun \
  "$IMAGE"
RC=$?
set -e

if [[ "${KEEP:-0}" == "1" ]]; then
  echo ">> KEEP=1:容器保留(docker exec -it $CONTAINER bash;手动清理 bash run-in-docker.sh --cleanup)"
else
  cleanup
fi
exit $RC
