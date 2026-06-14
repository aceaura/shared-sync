#!/usr/bin/env bash
#
# deploy-lighthouse.sh — 把 Nebula lighthouse+relay 部署到一台公网 VPS。
# 这是 v2 的"公网跳板":只做打洞协调(rendezvous)+ 中继兜底(relay),不承载明文数据。
#
# 前置:
#   1) 已用 v2/nebula/gen-certs.sh 生成 v2/nebula/certs/(ca.crt + lighthouse.crt/.key)。
#   2) VPS 安全组/防火墙放行 UDP 4242 入站。
#   3) 本机能 ssh 免密登录该 VPS(root 或可 sudo 用户)。
#
# 用法:
#   v2/deploy/deploy-lighthouse.sh <ssh目标>
#   例:v2/deploy/deploy-lighthouse.sh root@54.198.93.78
#
set -euo pipefail

SSH_TARGET="${1:-}"
[ -n "$SSH_TARGET" ] || { echo "用法: $0 <ssh目标>  例如 root@1.2.3.4"; exit 1; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NEBULA_DIR="$ROOT/v2/nebula"
CERTS="$NEBULA_DIR/certs"
SVC="$ROOT/v2/deploy/nebula-lighthouse.service"
NEBULA_VER="${NEBULA_VER:-1.10.3}"

for f in ca.crt lighthouse.crt lighthouse.key; do
  [ -f "$CERTS/$f" ] || { echo "缺少 $CERTS/$f —— 先跑 v2/nebula/gen-certs.sh"; exit 1; }
done

SSH() { ssh -o BatchMode=yes "$SSH_TARGET" "$@"; }

echo "[1/4] 安装 nebula v$NEBULA_VER ..."
SSH "command -v nebula >/dev/null 2>&1 && nebula -version || (
  cd /tmp &&
  curl -fsSL -o nebula.tar.gz https://github.com/slackhq/nebula/releases/download/v${NEBULA_VER}/nebula-linux-amd64.tar.gz &&
  tar xzf nebula.tar.gz && install -m755 nebula nebula-cert /usr/local/bin/ &&
  nebula -version )"

echo "[2/4] 上传证书与配置到 /etc/nebula ..."
SSH "mkdir -p /etc/nebula"
scp -o BatchMode=yes "$CERTS/ca.crt" "$CERTS/lighthouse.crt" "$CERTS/lighthouse.key" \
  "$NEBULA_DIR/config/lighthouse.yml" "$SSH_TARGET:/etc/nebula/"
SSH "chmod 600 /etc/nebula/*.key"

echo "[3/4] 安装 systemd 服务 ..."
scp -o BatchMode=yes "$SVC" "$SSH_TARGET:/etc/systemd/system/nebula-lighthouse.service"
SSH "systemctl daemon-reload && systemctl enable --now nebula-lighthouse && sleep 2"

echo "[4/4] 验证 ..."
SSH '
  echo "  服务: $(systemctl is-active nebula-lighthouse)"
  echo "  overlay: $(ip -4 addr show nebula1 2>/dev/null | awk "/inet /{print \$2}")"
  echo "  监听: $(ss -ulnp 2>/dev/null | awk "/:4242 /{print \$5; exit}")"
'
echo
echo "✅ lighthouse 已部署。节点接入:v2/deploy/run-node.sh <home|company> <本VPS公网IP>"
