#!/usr/bin/env bash
#
# run-e2e.sh —— Phase3 一键端到端验证:完整三层阶梯 + T2(frp STCP)终极兜底。
#
# 拓扑(真连真 VPS):
#   真 VPS 54.198.93.78
#     ├─ nebula-lighthouse(systemd,生产,只读复用)overlay 10.77.0.1
#     └─ frps(本脚本前置 deploy-frps.sh 已部署)bindPort 7000  ← T2 中继
#   本机 Docker 网络 ssnet:
#     ├─ 数据中心容器 ss-dc   : git 8418 + nebula node-company(10.77.0.3) + frpc(STCP 服务端)
#     └─ 客户端容器   ss-cli  : connd + nebula node-home(10.77.0.2) + frpc(STCP visitor)
#                               connd 代理 127.0.0.1:8418;t2BackendAddr=127.0.0.1:18418(visitor)
#
# 验证三态(每态贴 connd status JSON + git ls-remote):
#   1. 正常态     : T0/T1(overlay 直达),git 经本地端点通。
#   2. 封死 UDP   : 客户端 iptables DROP 出站 UDP → nebula 全 DOWN → connd 降级 T2(viaVps=true),
#                   git 经【同一本地端点】走 frp TCP 隧道仍成功 —— Phase3 核心证明。
#   3. 恢复 UDP   : 解除 DROP → 滞后窗口后升级回 T1/T0,git 仍通。
#
# 用法:
#   bash run-e2e.sh                 # 跑三态验证,结束清理容器/网络(不动 VPS frps/nebula/ss-server)
#   KEEP=1 bash run-e2e.sh          # 跑完保留容器供排查
#   bash run-e2e.sh --cleanup       # 仅清理本机容器/网络
#
# 依赖:docker、go(交叉编译 connd)、本机已下载 frpc linux 二进制(脚本会自动下)、
#       v2/nebula/certs/(gen-certs.sh 生成)、v2/frp/secret.env(secret.env.example 复制)。
set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.69.1}"
LH_IP="${LH_IP:-54.198.93.78}"
NET="${NET:-ssnet}"
DC="${DC:-ss-dc}"
CLI="${CLI:-ss-cli}"
DC_IMAGE="${DC_IMAGE:-sharedsync/dc-p3}"
CLI_IMAGE="${CLI_IMAGE:-sharedsync/cli-p3}"
DC_OVERLAY="10.77.0.3"          # 数据中心 overlay(node-company)
VISITOR_PORT="${VISITOR_PORT:-18418}"   # 客户端本地 visitor 口 = connd t2BackendAddr
GIT_PORT="${GIT_PORT:-80}"      # 数据中心 git 容器内端口(复用生产镜像,固定 80)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONND_DIR="$ROOT/v2/connd"
NEBULA_DIR="$ROOT/v2/nebula"
CERTS="$NEBULA_DIR/certs"
SECRET_ENV="${SECRET_ENV:-$SCRIPT_DIR/secret.env}"
WORK="$HOME/.shared-sync-v2/p3"

cleanup() {
  docker rm -f "$CLI" "$DC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  echo ">> 已清理容器 $DC/$CLI 与网络 $NET"
}
if [[ "${1:-}" == "--cleanup" ]]; then cleanup; rm -rf "$WORK"; exit 0; fi

# ---- 0. 前置 ----------------------------------------------------------------
[[ -f "$SECRET_ENV" ]] || { echo "缺少 $SECRET_ENV(cp secret.env.example secret.env)"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$SECRET_ENV"; set +a
: "${FRP_AUTH_TOKEN:?}"; : "${FRP_STCP_SECRET:?}"
for f in ca.crt node-home.crt node-home.key node-company.crt node-company.key; do
  [[ -f "$CERTS/$f" ]] || { echo "缺少 $CERTS/$f —— 跑 v2/nebula/gen-certs.sh"; exit 1; }
done

cleanup
rm -rf "$WORK"; mkdir -p "$WORK/dc" "$WORK/cli"
trap '[[ "${KEEP:-0}" == "1" ]] || rm -rf "$WORK"' EXIT

ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null)"
case "$ARCH" in aarch64|arm64) GOARCH=arm64 ;; x86_64|amd64) GOARCH=amd64 ;; *) GOARCH=arm64 ;; esac

# ---- 1. 准备 frpc linux 二进制 ---------------------------------------------
FRPC_BIN="$WORK/frpc"
echo ">> 准备 frpc linux/$GOARCH 二进制"
CACHE="/tmp/frp_${FRP_VERSION}_linux_${GOARCH}/frpc"
if [[ -x "$CACHE" ]]; then cp "$CACHE" "$FRPC_BIN"; else
  curl -sL -m 120 -o /tmp/frp_dl.tgz "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${GOARCH}.tar.gz"
  tar xzf /tmp/frp_dl.tgz -C /tmp
  cp "/tmp/frp_${FRP_VERSION}_linux_${GOARCH}/frpc" "$FRPC_BIN"
fi
chmod +x "$FRPC_BIN"

# ---- 2. 交叉编译 connd ------------------------------------------------------
echo ">> 交叉编译 connd (linux/$GOARCH)"
( cd "$CONND_DIR" && GOOS=linux GOARCH="$GOARCH" CGO_ENABLED=0 go build -o "$WORK/connd" ./cmd/connd )

# ---- 3. 控制 ssh 密钥(客户端 connd 查 hostmap 用)--------------------------
echo ">> 生成客户端控制 ssh 密钥 + nebula sshd hostkey"
ssh-keygen -t ed25519 -N "" -q -f "$WORK/cli/ctl_key"
ssh-keygen -t ed25519 -N "" -q -f "$WORK/cli/sshd_hostkey"
CTL_PUBKEY="$(cat "$WORK/cli/ctl_key.pub")"
chmod 600 "$WORK/cli/ctl_key"

# ---- 4. 渲染数据中心(nebula + frpc + 证书)--------------------------------
echo ">> 渲染数据中心配置(node-company=$DC_OVERLAY)"
sed -e "s#__NODE_CERT__#node-company.crt#" \
    -e "s#__NODE_KEY__#node-company.key#" \
    -e "s#__LIGHTHOUSE_IP__#$LH_IP#" \
    "$SCRIPT_DIR/config/node-datacenter.yml.tmpl" > "$WORK/dc/node.yml"
sed -e "s#__FRP_SERVER_ADDR__#$LH_IP#" \
    -e "s#__FRP_AUTH_TOKEN__#$FRP_AUTH_TOKEN#" \
    -e "s#__FRP_STCP_SECRET__#$FRP_STCP_SECRET#" \
    -e "s#__GIT_LOCAL_ADDR__#127.0.0.1#" \
    -e "s#__GIT_LOCAL_PORT__#$GIT_PORT#" \
    "$SCRIPT_DIR/config/frpc-datacenter.toml" > "$WORK/dc/frpc.toml"
cp "$CERTS/ca.crt" "$CERTS/node-company.crt" "$CERTS/node-company.key" "$WORK/dc/"

# ---- 5. 渲染客户端(nebula + frpc visitor + connd 配置 + 证书)-------------
echo ">> 渲染客户端配置(node-home=10.77.0.2;t2BackendAddr=127.0.0.1:$VISITOR_PORT)"
sed -e "s#__NODE_CERT__#node-home.crt#" \
    -e "s#__NODE_KEY__#node-home.key#" \
    -e "s#__LIGHTHOUSE_IP__#$LH_IP#" \
    -e "s#__SSHD_HOSTKEY__#sshd_hostkey#" \
    -e "s#__CTL_PUBKEY__#$CTL_PUBKEY#" \
    "$NEBULA_DIR/config/node.yml.tmpl" > "$WORK/cli/node.yml"
sed -e "s#__FRP_SERVER_ADDR__#$LH_IP#" \
    -e "s#__FRP_AUTH_TOKEN__#$FRP_AUTH_TOKEN#" \
    -e "s#__FRP_STCP_SECRET__#$FRP_STCP_SECRET#" \
    -e "s#__VISITOR_BIND_ADDR__#127.0.0.1#" \
    -e "s#__VISITOR_PORT__#$VISITOR_PORT#" \
    "$SCRIPT_DIR/config/frpc-visitor.toml.tmpl" > "$WORK/cli/frpc-visitor.toml"
cp "$CERTS/ca.crt" "$CERTS/node-home.crt" "$CERTS/node-home.key" "$WORK/cli/"

# connd 配置:peer=数据中心 overlay(T0/T1),t2BackendAddr=本地 visitor(T2)。
cat > "$WORK/cli/connd.yaml" <<YAML
peerOverlayIP: $DC_OVERLAY
dataCenterPort: $GIT_PORT
localProxyAddr: 127.0.0.1:8418
t2BackendAddr: 127.0.0.1:$VISITOR_PORT     # ← frpc visitor 本地口 = T2 上游 + T2 探测
lighthouseUnderlay: ""
statusAddr: 127.0.0.1:4243
control:
  enabled: true
  host: 127.0.0.1
  port: 2222
  user: ctl
  keyPath: /etc/nebula/ctl_key
heartbeat: 3s
tUp: 8s
n: 3
p: 10s
probeTimeout: 2s
nebula:
  binPath: nebula
  configPath: /etc/nebula/node.yml
  dryRun: false
YAML

# ---- 6. 构建镜像 ------------------------------------------------------------
# 注意:frpc(=$FRPC_BIN)与 connd 已落在 $WORK/ 下(build context),无需也不能再 cp
# 到自身(cp 同名文件会报 "are identical" 并在 set -e 下中断)。这里只补 Dockerfile/entrypoint。
echo ">> 构建数据中心镜像 $DC_IMAGE"
cp "$SCRIPT_DIR/Dockerfile.datacenter" "$SCRIPT_DIR/datacenter-entrypoint.sh" "$WORK/"
docker build -t "$DC_IMAGE" -f "$WORK/Dockerfile.datacenter" "$WORK" >/dev/null
echo ">> 构建客户端镜像 $CLI_IMAGE"
cp "$SCRIPT_DIR/Dockerfile.client" "$SCRIPT_DIR/client-entrypoint.sh" "$WORK/"
docker build -t "$CLI_IMAGE" -f "$WORK/Dockerfile.client" "$WORK" >/dev/null

# ---- 7. 起网络 + 数据中心 + 客户端 -----------------------------------------
docker network create "$NET" >/dev/null 2>&1 || true
echo ">> 启动数据中心容器 $DC"
docker run -d --name "$DC" --network "$NET" \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -e NEBULA_ENABLED=1 -e GIT_PORT="$GIT_PORT" \
  -v "$WORK/dc:/etc/nebula:ro" -v "$WORK/dc:/etc/frp:ro" \
  "$DC_IMAGE" >/dev/null

echo ">> 等数据中心 git + frpc(STCP 服务端)就绪"
for i in $(seq 1 40); do
  docker logs "$DC" 2>&1 | grep -q "start proxy success" && break
  sleep 1
done
docker logs "$DC" 2>&1 | grep -iE "overlay=|ls-remote|start proxy success|err" | tail -8 || true

echo ">> 启动客户端容器 $CLI"
docker run -d --name "$CLI" --network "$NET" \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -e VISITOR_PORT="$VISITOR_PORT" \
  -v "$WORK/cli:/etc/nebula:ro" -v "$WORK/cli:/etc/frp:ro" \
  "$CLI_IMAGE" >/dev/null

# 等 nebula overlay + frpc visitor + connd 状态端点
echo ">> 等客户端 overlay + frpc visitor + connd 起来"
for i in $(seq 1 50); do
  if docker exec "$CLI" ip -4 addr show nebula1 >/dev/null 2>&1 \
     && docker exec "$CLI" sh -c "nc -z 127.0.0.1 $VISITOR_PORT" 2>/dev/null \
     && docker exec "$CLI" sh -c "nc -z 127.0.0.1 4243" 2>/dev/null; then
    break
  fi
  sleep 1
done
docker exec "$CLI" ip -4 addr show nebula1 2>/dev/null | awk '/inet /{print "   client overlay="$2}'

# ===========================================================================
# 三态验证
# ===========================================================================
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

status_json() { docker exec "$CLI" connd status -json 2>/dev/null; }
show_status() {
  local j; j="$(status_json)"
  echo "$j" | docker exec -i "$CLI" jq '{tier, viaVps, upstream, currentRemote, tiersHealth, reconnecting, nebula}' 2>/dev/null || echo "$j"
}
git_ls() { docker exec "$CLI" git ls-remote http://127.0.0.1:8418/shared.git 2>&1; }
# git_ok:经固定本地端点列到真实 ref(current/HEAD)即视为成功。
# 注意:不能写 `git_ls | grep -q ...` —— set -o pipefail 下 grep -q 命中即关管,
# git 收到 SIGPIPE 退出非零,会让整条管道非零,把【成功】误判成失败。故先抓输出再 grep。
git_ok() { local o; o="$(git_ls)"; printf '%s\n' "$o" | grep -qiE "HEAD|refs/heads/current"; }

wait_tier() { # $1=期望 tier(正则), $2=最多等几拍
  local want="$1" max="${2:-40}" t
  for i in $(seq 1 "$max"); do
    t="$(status_json | docker exec -i "$CLI" jq -r '.tier' 2>/dev/null || echo '?')"
    [[ "$t" =~ $want ]] && return 0
    sleep 2
  done
  return 1
}

echo; echo "================= 态1:正常态(overlay 直达 T0/T1)================="
wait_tier '^T0$|^T1$' 30 || true
echo "----- connd status -----"; show_status
echo "----- git ls-remote(经本地端点 127.0.0.1:8418)-----"; git_ls | head -4 || true
T1_TIER="$(status_json | docker exec -i "$CLI" jq -r '.tier')"
ck "态1 当前层为 T0 或 T1(overlay,未封 UDP)" '[[ "$T1_TIER" == "T0" || "$T1_TIER" == "T1" ]]'
ck "态1 git ls-remote 成功(看到 current/HEAD)" 'git_ok'

echo; echo "================= 态2:封死 UDP → 降级 T2(frp TCP)================="
echo ">> 客户端容器 iptables DROP 所有出站 UDP(含 lighthouse 4242)"
docker exec "$CLI" iptables -A OUTPUT -p udp -j DROP
echo "   (等 connd 探测 nebula 失联 + 降级到 T2 ...)"
wait_tier '^T2$' 40 || true
echo "----- connd status -----"; show_status
echo "----- git ls-remote(同一本地端点,此时走 frp TCP 隧道)-----"; git_ls | head -4 || true
T2_TIER="$(status_json | docker exec -i "$CLI" jq -r '.tier')"
T2_VIA="$(status_json | docker exec -i "$CLI" jq -r '.viaVps')"
ck "态2 connd 降级到 T2" '[[ "$T2_TIER" == "T2" ]]'
ck "态2 viaVps=true(经 VPS frps)" '[[ "$T2_VIA" == "true" ]]'
ck "态2 git ls-remote 仍成功(走 frp TCP 隧道)" 'git_ok'
# 真兜底证据:此刻直连 overlay 8418 应不通(UDP 封死),但本地端点 git 仍通。
ck "态2 overlay 直达数据中心已断(ping 10.77.0.3 失败)" '! docker exec "$CLI" ping -c1 -W2 10.77.0.3 >/dev/null 2>&1'

echo; echo "================= 态3:恢复 UDP → 升级回 T1/T0 ================="
echo ">> 解除 iptables UDP DROP"
docker exec "$CLI" iptables -D OUTPUT -p udp -j DROP
echo "   (等 nebula 重新握手 + connd 滞后窗口后升级 ...)"
wait_tier '^T0$|^T1$' 50 || true
echo "----- connd status -----"; show_status
echo "----- git ls-remote -----"; git_ls | head -4 || true
T3_TIER="$(status_json | docker exec -i "$CLI" jq -r '.tier')"
ck "态3 升级回 T0 或 T1(UDP 恢复)" '[[ "$T3_TIER" == "T0" || "$T3_TIER" == "T1" ]]'
ck "态3 git ls-remote 仍成功" 'git_ok'

echo; echo "================= 汇总: PASS=$PASS FAIL=$FAIL ================="
if [[ "${KEEP:-0}" == "1" ]]; then
  echo ">> KEEP=1:容器保留。docker exec -it $CLI sh / docker exec -it $DC sh"
else
  cleanup
fi
[[ $FAIL -eq 0 ]]
