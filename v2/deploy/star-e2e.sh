#!/usr/bin/env bash
#
# star-e2e.sh —— Phase4 星型多客户端真机联调:1 数据中心 + N(≥2)客户端,都真连真 VPS。
#
# 证明的事(DESIGN_v2 §1/§3/§7):
#   * N→1 星型传输:每个客户端经【各自本地端点 127.0.0.1:8418】对【同一数据中心】做 git
#     clone/push,客户端之间互不通信。
#   * 共享同一数据中心:客户端 A push 一个文件 → 客户端 B clone/pull 能看到(经数据中心中转)。
#   * 每条隧道独立:两客户端各自 connd status 显示其所在层(T0/T1);可选地只封一个客户端的
#     UDP,验证它独立降级 T2 而不影响另一个客户端的层。
#   * 接入工具闭环:客户端配置包由 v2/deploy/enroll-client.sh 真实产出(类比 v1 安装器),
#     「新增客户端 = 跑一次 enroll-client.sh」。
#
# 拓扑(真连真 VPS 54.198.93.78):
#   真 VPS:nebula-lighthouse(systemd,overlay 10.77.0.1)+ frps(systemd,bindPort 7000)
#   本机 Docker 网络 starnet:
#     数据中心 ss-dc      git(80)+ nebula datacenter(10.77.0.2)+ frpc(STCP 服务端 ss-git)
#     客户端   ss-alice   connd + nebula client-alice(10.77.0.11)+ frpc visitor(127.0.0.1:18418)
#     客户端   ss-bob     connd + nebula client-bob  (10.77.0.12)+ frpc visitor(127.0.0.1:18418)
#   每个客户端 connd 固定本地端点 127.0.0.1:8418;引擎 server_url 永远指它(切层透明)。
#
# 客户端配置全部由 enroll-client.sh 产出的 dist/<名字>/ 直接挂载(node.yml/frpc-visitor.toml/
# connd.yaml/证书/控制密钥),证明接入工具产物可直接跑。
#
# 用法:
#   bash star-e2e.sh                # 跑星型联调,结束清理容器/网络(不动 VPS)
#   KEEP=1 bash star-e2e.sh         # 跑完保留容器供排查
#   FREEZE_UDP=1 bash star-e2e.sh   # 额外做「封一个客户端 UDP,验证隧道独立」一节
#   bash star-e2e.sh --cleanup      # 仅清理本机容器/网络
#
# 依赖:docker、go(交叉编译 connd)、frpc linux 二进制(脚本自动下)、
#       v2/nebula/certs/(gen-certs.sh:datacenter + client-alice + client-bob)、
#       v2/frp/secret.env(secret.env.example 复制并填 frps 端到端口令)。
set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.69.1}"
LH_IP="${LH_IP:-54.198.93.78}"
NET="${NET:-starnet}"
DC="${DC:-ss-dc}"
DC_IMAGE="${DC_IMAGE:-sharedsync/dc-p4}"
CLI_IMAGE="${CLI_IMAGE:-sharedsync/cli-p4}"
DC_OVERLAY="${DC_OVERLAY:-10.77.0.2}"   # 数据中心 overlay(datacenter 角色化命名)
GIT_PORT="${GIT_PORT:-80}"
VISITOR_PORT="${VISITOR_PORT:-18418}"

# 客户端清单:"<容器名>:<enroll 名字>"。enroll 名字 → dist/<名字>/ 与证书 client-<名字>。
CLIENTS=("ss-alice:alice" "ss-bob:bob")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONND_DIR="$ROOT/v2/connd"
NEBULA_DIR="$ROOT/v2/nebula"
CERTS="$NEBULA_DIR/certs"
FRP_DIR="$ROOT/v2/frp"
SECRET_ENV="${SECRET_ENV:-$FRP_DIR/secret.env}"
DIST="$SCRIPT_DIR/dist"
WORK="$HOME/.shared-sync-v2/p4"

cleanup() {
  for c in "${CLIENTS[@]}"; do docker rm -f "${c%%:*}" >/dev/null 2>&1 || true; done
  docker rm -f "$DC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  echo ">> 已清理数据中心/客户端容器与网络 $NET(VPS 上的 lighthouse/frps/ss-server 未动)"
}
if [[ "${1:-}" == "--cleanup" ]]; then cleanup; rm -rf "$WORK"; exit 0; fi

# ---- 0. 前置 ----------------------------------------------------------------
[[ -f "$SECRET_ENV" ]] || { echo "缺少 $SECRET_ENV(cp $FRP_DIR/secret.env.example secret.env)"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$SECRET_ENV"; set +a
: "${FRP_AUTH_TOKEN:?}"; : "${FRP_STCP_SECRET:?}"
for f in ca.crt datacenter.crt datacenter.key; do
  [[ -f "$CERTS/$f" ]] || { echo "缺少 $CERTS/$f —— 跑 v2/nebula/gen-certs.sh"; exit 1; }
done

cleanup
rm -rf "$WORK"; mkdir -p "$WORK/dc"
trap '[[ "${KEEP:-0}" == "1" ]] || rm -rf "$WORK"' EXIT

ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null)"
case "$ARCH" in aarch64|arm64) GOARCH=arm64 ;; x86_64|amd64) GOARCH=amd64 ;; *) GOARCH=arm64 ;; esac

# ---- 1. frpc linux 二进制 ---------------------------------------------------
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

# ---- 3. 渲染数据中心(datacenter=10.77.0.2 + frpc STCP 服务端)-------------
echo ">> 渲染数据中心(datacenter overlay=$DC_OVERLAY)"
sed -e "s#__NODE_CERT__#datacenter.crt#" \
    -e "s#__NODE_KEY__#datacenter.key#" \
    -e "s#__LIGHTHOUSE_IP__#$LH_IP#" \
    "$FRP_DIR/config/node-datacenter.yml.tmpl" > "$WORK/dc/node.yml"
sed -e "s#__FRP_SERVER_ADDR__#$LH_IP#" \
    -e "s#__FRP_AUTH_TOKEN__#$FRP_AUTH_TOKEN#" \
    -e "s#__FRP_STCP_SECRET__#$FRP_STCP_SECRET#" \
    -e "s#__GIT_LOCAL_ADDR__#127.0.0.1#" \
    -e "s#__GIT_LOCAL_PORT__#$GIT_PORT#" \
    "$FRP_DIR/config/frpc-datacenter.toml" > "$WORK/dc/frpc.toml"
cp "$CERTS/ca.crt" "$CERTS/datacenter.crt" "$CERTS/datacenter.key" "$WORK/dc/"

# ---- 4. 接入工具产出每个客户端配置包(enroll-client.sh)---------------------
# 这就是 Phase4 接入工具的真实闭环:客户端配置不是脚本临时拼的,而是 enroll-client.sh
# 产出的 dist/<名字>/ 直接挂载进容器。每跑一次 enroll = 新增一台客户端,不动其他节点。
echo ">> 经 enroll-client.sh 产出客户端配置包(dist/<名字>/)"
for entry in "${CLIENTS[@]}"; do
  short="${entry##*:}"
  echo "   --- enroll $short ---"
  OUT_DIR="$DIST/$short" VISITOR_PORT="$VISITOR_PORT" GIT_PORT="$GIT_PORT" \
    bash "$SCRIPT_DIR/enroll-client.sh" "$short" "$LH_IP" "$DC_OVERLAY" >/dev/null
  [[ -f "$DIST/$short/connd.yaml" ]] || { echo "ERROR: enroll 未产出 $DIST/$short/connd.yaml"; exit 1; }
done

# ---- 5. 构建镜像(复用 Phase3 的 Dockerfile/entrypoint)---------------------
echo ">> 构建数据中心镜像 $DC_IMAGE"
cp "$FRP_DIR/Dockerfile.datacenter" "$FRP_DIR/datacenter-entrypoint.sh" "$WORK/"
docker build -t "$DC_IMAGE" -f "$WORK/Dockerfile.datacenter" "$WORK" >/dev/null
echo ">> 构建客户端镜像 $CLI_IMAGE"
cp "$FRP_DIR/Dockerfile.client" "$FRP_DIR/client-entrypoint.sh" "$WORK/"
docker build -t "$CLI_IMAGE" -f "$WORK/Dockerfile.client" "$WORK" >/dev/null

# ---- 6. 起网络 + 数据中心 ---------------------------------------------------
docker network create "$NET" >/dev/null 2>&1 || true
echo ">> 启动数据中心容器 $DC(git + nebula $DC_OVERLAY + frpc STCP 服务端)"
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
docker logs "$DC" 2>&1 | grep -iE "overlay=|当前 refs|start proxy success" | tail -6 || true

# ---- 7. 起各客户端(挂载 enroll 产物)--------------------------------------
for entry in "${CLIENTS[@]}"; do
  cname="${entry%%:*}"; short="${entry##*:}"
  echo ">> 启动客户端容器 $cname(挂载 dist/$short;connd 本地端点 127.0.0.1:8418)"
  docker run -d --name "$cname" --network "$NET" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -e VISITOR_PORT="$VISITOR_PORT" \
    -v "$DIST/$short:/etc/nebula:ro" -v "$DIST/$short:/etc/frp:ro" \
    "$CLI_IMAGE" >/dev/null
done

echo ">> 等各客户端 overlay + frpc visitor + connd 起来"
for entry in "${CLIENTS[@]}"; do
  cname="${entry%%:*}"
  for i in $(seq 1 50); do
    if docker exec "$cname" ip -4 addr show nebula1 >/dev/null 2>&1 \
       && docker exec "$cname" sh -c "nc -z 127.0.0.1 $VISITOR_PORT" 2>/dev/null \
       && docker exec "$cname" sh -c "nc -z 127.0.0.1 4243" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  docker exec "$cname" ip -4 addr show nebula1 2>/dev/null | awk -v c="$cname" '/inet /{print "   "c" overlay="$2}'
done

# ===========================================================================
# 验证
# ===========================================================================
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

status_json() { docker exec "$1" connd status -json 2>/dev/null; }
show_status() {
  local j; j="$(status_json "$1")"
  echo "$j" | docker exec -i "$1" jq '{tier, viaVps, upstream, peer, currentRemote, tiersHealth, reconnecting, nebula}' 2>/dev/null || echo "$j"
}
tier_of() { status_json "$1" | docker exec -i "$1" jq -r '.tier' 2>/dev/null || echo '?'; }
# git_ok:经【该客户端自己的】固定本地端点列到真实 ref(current/HEAD)即视为成功。
# 不用 `git_ls | grep -q`:pipefail 下 grep -q 命中即关管,git 收 SIGPIPE 退出非零会误判。
git_ls() { docker exec "$1" git ls-remote http://127.0.0.1:8418/shared.git 2>&1; }
git_ok() { local o; o="$(git_ls "$1")"; printf '%s\n' "$o" | grep -qiE "HEAD|refs/heads/current"; }

wait_tier() { # $1=容器 $2=期望 tier 正则 $3=最多等几拍
  local c="$1" want="$2" max="${3:-40}" t
  for i in $(seq 1 "$max"); do
    t="$(tier_of "$c")"
    [[ "$t" =~ $want ]] && return 0
    sleep 2
  done
  return 1
}

C1="${CLIENTS[0]%%:*}"; S1="${CLIENTS[0]##*:}"
C2="${CLIENTS[1]%%:*}"; S2="${CLIENTS[1]##*:}"

echo; echo "================= 1) 两客户端各自经本地端点 git ls-remote(N→1 星型)================="
for entry in "${CLIENTS[@]}"; do
  cname="${entry%%:*}"
  wait_tier "$cname" '^T0$|^T1$|^T2$' 30 || true
done
for entry in "${CLIENTS[@]}"; do
  cname="${entry%%:*}"; short="${entry##*:}"
  echo "----- $short($cname) connd status -----"; show_status "$cname"
  echo "----- $short git ls-remote(经本地端点 127.0.0.1:8418)-----"; git_ls "$cname" | head -3 || true
  t="$(tier_of "$cname")"
  ck "$short 当前层 ∈ {T0,T1,T2}(自适应已选定)" '[[ "$t" =~ ^T[012]$ ]]'
  ck "$short git ls-remote 成功(经各自本地端点达同一数据中心)" 'git_ok "$cname"'
done

echo; echo "================= 2) A push 一个文件 → B clone/pull 看到(共享同一数据中心)================="
STAMP="$(date -u +%Y%m%d%H%M%S)"
FNAME="from-${S1}-${STAMP}.txt"
echo ">> $S1($C1)clone → 新增 $FNAME → push(经 $S1 本地端点 → 数据中心 refs/heads/current)"
PUSH_OUT="$(docker exec "$C1" sh -c "
  set -e
  rm -rf /tmp/work && git clone -q http://127.0.0.1:8418/shared.git /tmp/work
  cd /tmp/work
  git config user.email a@local; git config user.name $S1
  # 服务端 pre-receive 只收 refs/heads/current,且要快进:在 current 上加提交。
  git checkout -q -B current origin/current 2>/dev/null || git checkout -q current
  echo 'hello from $S1 @ $STAMP' > '$FNAME'
  git add '$FNAME'
  git commit -q -m 'add $FNAME by $S1'
  git push -q origin current 2>&1
  echo PUSH_DONE
" 2>&1)"
echo "$PUSH_OUT" | tail -4
ck "$S1 push 成功(refs/heads/current 快进)" 'printf "%s" "$PUSH_OUT" | grep -q PUSH_DONE'

echo ">> $S2($C2)clone(全新)→ 应看到 $S1 push 的 $FNAME(经数据中心中转)"
SEE_OUT="$(docker exec "$C2" sh -c "
  rm -rf /tmp/work2 && git clone -q http://127.0.0.1:8418/shared.git /tmp/work2 2>&1
  ls /tmp/work2
" 2>&1)"
echo "----- $S2 clone 后工作树文件 -----"; echo "$SEE_OUT"
ck "$S2 clone 到 $S1 push 的文件 $FNAME(N 客户端共享数据中心)" 'printf "%s\n" "$SEE_OUT" | grep -qF "$FNAME"'

# 进一步:B 已有的工作树做 pull 也应增量看到(模拟长驻客户端)。
echo ">> $S2 增量 pull(已有工作树)再确认 $FNAME"
PULL_OUT="$(docker exec "$C2" sh -c "
  rm -rf /tmp/work3 && git clone -q http://127.0.0.1:8418/shared.git /tmp/work3 >/dev/null 2>&1
  cd /tmp/work3 && git pull -q origin current >/dev/null 2>&1
  test -f '$FNAME' && cat '$FNAME'
" 2>&1)"
echo "----- $S2 pull 后读到 $FNAME 内容 -----"; echo "$PULL_OUT"
ck "$S2 pull 后能读到 $S1 写入的内容" 'printf "%s" "$PULL_OUT" | grep -q "hello from $S1"'

echo; echo "================= 3) 两客户端 connd status 各显其层(每条隧道独立)================="
T_A="$(tier_of "$C1")"; T_B="$(tier_of "$C2")"
echo "   $S1 tier=$T_A   |   $S2 tier=$T_B"
ck "$S1 status 报告一个有效层" '[[ "$T_A" =~ ^T[012]$ ]]'
ck "$S2 status 报告一个有效层" '[[ "$T_B" =~ ^T[012]$ ]]'

# ---- 4) 可选:封一个客户端 UDP,验证隧道独立(只它降级 T2,另一个不受影响)----
if [[ "${FREEZE_UDP:-0}" == "1" ]]; then
  echo; echo "================= 4) 封 $S1 的 UDP → 只 $S1 降级 T2,$S2 层不变(隧道独立)================="
  B_BEFORE="$(tier_of "$C2")"
  echo ">> $S1($C1)iptables DROP 出站 UDP(封死 nebula 4242);不动 $S2"
  docker exec "$C1" iptables -A OUTPUT -p udp -j DROP
  echo "   (等 $S1 降级到 T2 ...)"
  wait_tier "$C1" '^T2$' 40 || true
  echo "----- $S1 status(应 T2/viaVps=true)-----"; show_status "$C1"
  echo "----- $S2 status(应不受影响,仍 overlay)-----"; show_status "$C2"
  A_AFTER="$(tier_of "$C1")"; B_AFTER="$(tier_of "$C2")"
  ck "$S1 独立降级到 T2" '[[ "$A_AFTER" == "T2" ]]'
  ck "$S1 封 UDP 后 git 仍通(经 frp TCP 隧道)" 'git_ok "$C1"'
  ck "$S2 未受 $S1 故障影响(仍走 overlay,非 T2)" '[[ "$B_AFTER" != "T2" && "$B_AFTER" =~ ^T[01]$ ]]'
  ck "$S2 git 仍通(隧道独立)" 'git_ok "$C2"'
  echo ">> 解除 $S1 UDP DROP(恢复)"
  docker exec "$C1" iptables -D OUTPUT -p udp -j DROP || true
  wait_tier "$C1" '^T0$|^T1$' 50 || true
  echo "----- $S1 恢复后 status -----"; show_status "$C1"
  ck "$S1 UDP 恢复后升回 overlay(T0/T1)" '[[ "$(tier_of "$C1")" =~ ^T[01]$ ]]'
fi

echo; echo "================= 汇总: PASS=$PASS FAIL=$FAIL ================="
if [[ "${KEEP:-0}" == "1" ]]; then
  echo ">> KEEP=1:容器保留。docker exec -it $C1 sh / $C2 sh / $DC sh"
else
  cleanup
fi
[[ $FAIL -eq 0 ]]
