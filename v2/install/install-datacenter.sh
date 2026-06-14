#!/usr/bin/env bash
# =============================================================================
# install-datacenter.sh —— 角色2:数据中心(私网节点)一键安装器
#
# 在【数据中心节点】(Linux + systemd + docker)上把三件套装好并起好常驻:
#   * nebula 节点  —— overlay 10.77.0.2,让客户端经 overlay 直达本机 git(撑 T0/T1)。
#   * frpc(STCP 服务端)—— 把本地 git 注册到 VPS frps,客户端经 VPS 隧道抵达(撑 T2)。
#   * git 服务端   —— v1 shared-sync-server 镜像,持有权威 current 分支(:8418)。
#
# 在【数据中心节点本机】运行(从一个仓库 checkout,需 certs/ 与 secret.env 在位)。
#
# 前置:
#   1) v2/nebula/gen-certs.sh sign datacenter   生成 certs/datacenter.crt/.key(10.77.0.2)。
#   2) v2/frp/secret.env(从 secret.env.example 复制,填与中转中心同一套口令)。
#   3) docker 可用;数据中心在 NAT 后(git 不暴露公网,只经 overlay/frp 可达)。
#
# 用法:
#   bash v2/install/install-datacenter.sh <lighthouse公网IP>
#   bash v2/install/install-datacenter.sh --status
#   bash v2/install/install-datacenter.sh --uninstall
#
# 设计纪律:幂等;只装本角色三件套;私钥/密钥不落库。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CERTS="$ROOT/v2/nebula/certs"
SECRET_ENV="$ROOT/v2/frp/secret.env"
NEBULA_TMPL="$ROOT/v2/frp/config/node-datacenter.yml.tmpl"
FRPC_TMPL="$ROOT/v2/frp/config/frpc-datacenter.toml"
GIT_IMAGE="${GIT_IMAGE:-ghcr.io/aceaura/shared-sync-server:latest}"

ETC_NEBULA=/etc/nebula
ETC_FRP=/etc/frp
BIN_DIR=/usr/local/bin

MODE=install
LH_IP=""
for a in "$@"; do
  case "$a" in
    --status)    MODE=status ;;
    --uninstall) MODE=uninstall ;;
    -h|--help)   usage; exit 0 ;;
    *)           LH_IP="$a" ;;
  esac
done

case "$MODE" in
  status)
    echo "--- nebula(overlay 10.77.0.2)---"; svc_status shared-sync-nebula
    echo "--- frpc(T2 STCP 服务端)---";      svc_status shared-sync-frpc
    echo "--- git 服务端 ---"; docker ps --filter name=shared-sync-dc --format '{{.Status}}' 2>/dev/null || true
    exit 0 ;;
  uninstall)
    need_root
    svc_uninstall shared-sync-nebula
    svc_uninstall shared-sync-frpc
    $SUDO docker rm -f shared-sync-dc >/dev/null 2>&1 || true
    ok "数据中心服务已移除(证书/配置保留在 $ETC_NEBULA、$ETC_FRP)"
    exit 0 ;;
esac

[[ -n "$LH_IP" ]] || die "用法: $0 <lighthouse公网IP>   例如 54.198.93.78"
[[ "$(detect_os)" == linux ]] || die "数据中心安装器仅支持 Linux(需 docker + systemd)"
command -v docker >/dev/null 2>&1 || die "数据中心需要 docker(跑 git 服务端)"
[[ -f "$CERTS/ca.crt" && -f "$CERTS/datacenter.crt" && -f "$CERTS/datacenter.key" ]] \
  || die "缺少数据中心证书 —— 先跑: v2/nebula/gen-certs.sh sign datacenter"
[[ -f "$SECRET_ENV" ]] || die "缺少 $SECRET_ENV(cp v2/frp/secret.env.example 并填口令)"
[[ -f "$NEBULA_TMPL" && -f "$FRPC_TMPL" ]] || die "缺少配置模板(node-datacenter/frpc-datacenter)"
need_root
# shellcheck source=/dev/null
source "$SECRET_ENV"
: "${FRP_AUTH_TOKEN:?secret.env 缺 FRP_AUTH_TOKEN}"
: "${FRP_STCP_SECRET:?secret.env 缺 FRP_STCP_SECRET}"

log "===== 数据中心安装:lighthouse=$LH_IP,git 镜像=$GIT_IMAGE ====="

# 1) 二进制(Release 下载或官方 release)
acquire_nebula "$BIN_DIR/nebula"
acquire_frpc   "$BIN_DIR/frpc"

# 2) 证书 + nebula 节点配置(overlay 10.77.0.2)
$SUDO mkdir -p "$ETC_NEBULA" "$ETC_FRP"
$SUDO install -m 0644 "$CERTS/ca.crt"         "$ETC_NEBULA/ca.crt"
$SUDO install -m 0644 "$CERTS/datacenter.crt" "$ETC_NEBULA/datacenter.crt"
$SUDO install -m 0600 "$CERTS/datacenter.key" "$ETC_NEBULA/datacenter.key"
tmp="$(mktemp)"
render "$NEBULA_TMPL" "$tmp" NODE_CERT=datacenter.crt NODE_KEY=datacenter.key LIGHTHOUSE_IP="$LH_IP"
$SUDO install -m 0644 "$tmp" "$ETC_NEBULA/node.yml"; rm -f "$tmp"

# 3) frpc 配置(STCP 服务端:把本地 git 127.0.0.1:8418 注册给 frps;不在 VPS 开公网口)
tmp="$(mktemp)"
render "$FRPC_TMPL" "$tmp" \
  FRP_SERVER_ADDR="$LH_IP" \
  FRP_AUTH_TOKEN="$FRP_AUTH_TOKEN" \
  FRP_STCP_SECRET="$FRP_STCP_SECRET" \
  GIT_LOCAL_ADDR=127.0.0.1 \
  GIT_LOCAL_PORT=8418
$SUDO install -m 0600 "$tmp" "$ETC_FRP/frpc-datacenter.toml"; rm -f "$tmp"

# 4) git 服务端(v1 镜像;数据中心在 NAT 后,绑 8418 不暴露公网)
log "拉起 git 服务端容器 shared-sync-dc(:8418)"
$SUDO docker pull "$GIT_IMAGE" >/dev/null 2>&1 || warn "docker pull 失败,尝试用本地镜像"
$SUDO docker rm -f shared-sync-dc >/dev/null 2>&1 || true
$SUDO docker run -d --name shared-sync-dc --restart unless-stopped -p 8418:80 "$GIT_IMAGE" >/dev/null

# 5) systemd 服务:nebula + frpc
tmp="$(mktemp)"
render "$SCRIPT_DIR/units/shared-sync-nebula.service.tmpl" "$tmp" \
  NEBULA_BIN="$BIN_DIR/nebula" NEBULA_CONFIG="$ETC_NEBULA/node.yml"
svc_install shared-sync-nebula "$tmp"; rm -f "$tmp"
tmp="$(mktemp)"
render "$SCRIPT_DIR/units/shared-sync-frpc.service.tmpl" "$tmp" \
  FRPC_BIN="$BIN_DIR/frpc" FRPC_CONFIG="$ETC_FRP/frpc-datacenter.toml"
svc_install shared-sync-frpc "$tmp"; rm -f "$tmp"

svc_enable shared-sync-nebula
svc_enable shared-sync-frpc

echo
ok "数据中心装好:nebula(overlay 10.77.0.2)+ frpc(T2)+ git 服务端(:8418)均常驻。"
echo "验证:   bash v2/install/install-datacenter.sh --status"
echo "接客户端:操作机跑 v2/deploy/enroll-client.sh <名字> $LH_IP,把 dist/<名字> 拷到客户端跑 install-client.sh"
