#!/usr/bin/env bash
#
# run-integration.sh —— Phase2 真机集成验证。
#
# 在本机用 Docker 跑一个 Linux 容器(NET_ADMIN + /dev/net/tun),容器里:
#   1. connd 管理 nebula 子进程,连真 lighthouse(默认 54.198.93.78);
#   2. connd 起本地代理 127.0.0.1:8418,经 overlay 转发到数据中心 8418;
#   3. connd 经 nebula 控制 sshd(127.0.0.1:2222)查 hostmap 判 T0/T1;
#   4. 脚本断言:status 显示 tier、本地端点 git ls-remote 成功。
#
# 数据中心 peer:Phase2 暂以 lighthouse 节点充当(overlay 10.77.0.1,其上 ss-server
# git server 绑 10.77.0.1:8418)。connd 本地 127.0.0.1:8418 → 经 overlay → 10.77.0.1:8418。
#
# 用法:
#   bash run-integration.sh              # 跑验证并自动清理容器
#   KEEP=1 bash run-integration.sh       # 跑完保留容器(docker exec -it 进去排查)
#   bash run-integration.sh --cleanup    # 仅清理
#
# 依赖:docker、go、ssh-keygen(本机)。connd 用 GOOS=linux 交叉编译。
set -euo pipefail

LH_IP="${LH_IP:-54.198.93.78}"
DC_OVERLAY="${DC_OVERLAY:-10.77.0.1}"     # 数据中心 peer overlay(Phase2 用 lighthouse 节点)
DC_PORT="${DC_PORT:-8418}"
CONTAINER="${CONTAINER:-connd-p2}"
IMAGE="${IMAGE:-sharedsync/connd-p2}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONND_DIR="$ROOT/v2/connd"
NEBULA_DIR="$ROOT/v2/nebula"
CERTS="$NEBULA_DIR/certs"
# 持久工作目录(bind-mount 进容器):用 ~/.shared-sync-v2 下固定路径,
# 这样 KEEP=1 时容器在脚本退出后仍能读到证书/key(不会被 trap 清掉)。
WORK="$HOME/.shared-sync-v2/$CONTAINER"
rm -rf "$WORK"; mkdir -p "$WORK"
# 仅在「不保留」时随退出清理工作目录;KEEP=1 保留供容器继续读。
cleanup_work() { [[ "${KEEP:-0}" != "1" ]] && rm -rf "$WORK" || true; }
trap cleanup_work EXIT

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo ">> 已清理容器 $CONTAINER"
}
if [[ "${1:-}" == "--cleanup" ]]; then cleanup; exit 0; fi
cleanup  # 先清掉可能的残留

# ---- 0. 前置:证书在?-------------------------------------------------------
for f in ca.crt node-home.crt node-home.key; do
  [[ -f "$CERTS/$f" ]] || { echo "缺少 $CERTS/$f —— 先跑 v2/nebula/gen-certs.sh"; exit 1; }
done

# ---- 1. 控制 ssh 密钥 + sshd hostkey ---------------------------------------
echo ">> 生成 connd 控制 ssh 密钥 + nebula sshd hostkey"
ssh-keygen -t ed25519 -N "" -q -f "$WORK/ctl_key"
ssh-keygen -t ed25519 -N "" -q -f "$WORK/sshd_hostkey"
CTL_PUBKEY="$(cat "$WORK/ctl_key.pub")"

# ---- 2. 渲染 node 配置(含 sshd 块)----------------------------------------
echo ">> 渲染 node-home 配置(lighthouse=$LH_IP)"
sed -e "s#__NODE_CERT__#node-home.crt#" \
    -e "s#__NODE_KEY__#node-home.key#" \
    -e "s#__LIGHTHOUSE_IP__#$LH_IP#" \
    -e "s#__SSHD_HOSTKEY__#sshd_hostkey#" \
    -e "s#__CTL_PUBKEY__#$CTL_PUBKEY#" \
    "$NEBULA_DIR/config/node.yml.tmpl" > "$WORK/node.yml"
cp "$CERTS/ca.crt" "$CERTS/node-home.crt" "$CERTS/node-home.key" "$WORK/"

# ---- 3. connd 配置 ---------------------------------------------------------
cat > "$WORK/connd.yaml" <<YAML
peerOverlayIP: $DC_OVERLAY
dataCenterPort: $DC_PORT
localProxyAddr: 127.0.0.1:8418
lighthouseUnderlay: ""        # 留空:currentRemote 非空即判 T0(数据中心 peer 直连可达)
statusAddr: 127.0.0.1:4243
control:
  enabled: true
  host: 127.0.0.1
  port: 2222
  user: ctl
  keyPath: /etc/nebula/ctl_key
heartbeat: 3s
tUp: 6s
n: 3
p: 15s
probeTimeout: 2s
nebula:
  binPath: nebula
  configPath: /etc/nebula/node.yml
  dryRun: false
YAML
chmod 600 "$WORK/ctl_key"   # ctl_key 已在 WORK,会随 -v 挂进容器 /etc/nebula/ctl_key

# ---- 4. 交叉编译 connd(Linux,容器架构)-----------------------------------
ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null)"
case "$ARCH" in
  aarch64|arm64) GOARCH=arm64 ;;
  x86_64|amd64)  GOARCH=amd64 ;;
  *) GOARCH=arm64 ;;
esac
echo ">> 交叉编译 connd (linux/$GOARCH)"
( cd "$CONND_DIR" && GOOS=linux GOARCH="$GOARCH" CGO_ENABLED=0 go build -o "$WORK/connd" ./cmd/connd )

# ---- 5. 构建镜像 -----------------------------------------------------------
echo ">> 构建镜像 $IMAGE"
cp "$CONND_DIR/integration/Dockerfile.connd" "$WORK/Dockerfile"
docker build -t "$IMAGE" "$WORK" >/dev/null

# ---- 6. 起容器,connd run ---------------------------------------------------
echo ">> 启动容器 $CONTAINER(connd run)"
docker run -d --name "$CONTAINER" \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v "$WORK:/etc/nebula:ro" \
  "$IMAGE" -c "connd run -config /etc/nebula/connd.yaml" >/dev/null

# ---- 7. 等 nebula overlay 起来 + 链路就绪 -----------------------------------
echo ">> 等待 overlay 接口与到数据中心连通 ..."
ok=0
for i in $(seq 1 40); do
  if docker exec "$CONTAINER" ip -4 addr show nebula1 >/dev/null 2>&1; then
    if docker exec "$CONTAINER" ping -c1 -W2 "$DC_OVERLAY" >/dev/null 2>&1; then
      ok=1; break
    fi
  fi
  sleep 1
done
OVERLAY="$(docker exec "$CONTAINER" ip -4 addr show nebula1 2>/dev/null | awk '/inet /{print $2}')"
echo "   overlay=$OVERLAY  数据中心可达=$([ $ok = 1 ] && echo yes || echo no)"

PASS=0; FAIL=0
check() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

echo
echo "===== 断言 ====="

# (a) overlay 接口存在且为 10.77.0.2
check "connd 起的 nebula overlay = 10.77.0.2" '[[ "$OVERLAY" == 10.77.0.2/* ]]'

# (b) 到数据中心 overlay 连通
check "overlay 内 ping 数据中心 $DC_OVERLAY 通" '[ $ok = 1 ]'

# 给 connd 几拍探测 + 状态稳定
sleep 6

# (c) connd status 可查,且 tier 是 T0/T1(非 RECONNECTING)
STATUS_JSON="$(docker exec "$CONTAINER" connd status -json 2>/dev/null || true)"
echo "----- connd status -----"
echo "$STATUS_JSON" | (docker exec -i "$CONTAINER" jq . 2>/dev/null || echo "$STATUS_JSON")
TIER="$(echo "$STATUS_JSON" | docker exec -i "$CONTAINER" jq -r '.tier' 2>/dev/null || echo '?')"
check "connd status 当前层为 T0 或 T1(已建链)" '[[ "$TIER" == "T0" || "$TIER" == "T1" ]]'

# (d) 本地固定端点 git ls-remote 成功(经 connd 代理 → overlay → 数据中心 8418)
echo "----- git ls-remote via 本地端点 127.0.0.1:8418 -----"
LS="$(docker exec "$CONTAINER" git ls-remote http://127.0.0.1:8418/shared.git 2>&1 || true)"
echo "$LS" | head -5
check "git ls-remote 经本地端点成功(看到 ref / HEAD)" 'echo "$LS" | grep -qiE "HEAD|refs/"'

echo
echo "===== 汇总: PASS=$PASS FAIL=$FAIL ====="

if [[ "${KEEP:-0}" != "1" ]]; then
  cleanup
else
  echo ">> KEEP=1:容器 $CONTAINER 保留。进容器:docker exec -it $CONTAINER bash"
fi

[[ $FAIL -eq 0 ]]
