#!/usr/bin/env bash
#
# deploy-frps.sh —— 把 frps(frp 中继服务器)部署到公网 VPS,作为 T2 兜底层的 VPS 侧。
#
# 做了什么:
#   1. 读取 v2/frp/secret.env(口令/密钥;gitignored)。
#   2. 把 frps 官方二进制(指定版本)下载到 VPS /usr/local/bin/frps。
#   3. 渲染 frps.toml(注入 auth.token / dashboard 口令)到 VPS /etc/frp/frps.toml。
#   4. 安装 frps.service systemd 单元,enable + start,常驻。
#   5. 校验:frps 监听 7000,且不占用 nebula(4242)/ss-server(8418)端口。
#
# 设计纪律:
#   * 【绝不触碰】 nebula-lighthouse(systemd)与 ss-server 容器 —— 它们是生产部署。
#   * frps 只新增 TCP 7000(撮合口)+ 本地回环 7500(dashboard);避开 4242/8418/22。
#   * AWS 安全组当前已放行入站 TCP(实测任意 TCP 端口可建连),故无需改 SG 即可达 7000。
#     若你的 VPS 有入站防火墙,请自行放行 TCP 7000。
#
# 用法:
#   bash v2/frp/deploy-frps.sh                       # 部署到默认 VPS(secret.env 的 FRP_SERVER_ADDR)
#   VPS=root@1.2.3.4 bash v2/frp/deploy-frps.sh      # 指定 VPS ssh 目标
#   bash v2/frp/deploy-frps.sh --status              # 查看 VPS 上 frps 状态
#   bash v2/frp/deploy-frps.sh --uninstall           # 停止并移除 frps(不动 nebula/ss-server)
#
# 依赖:本机 ssh 到 VPS 免密;VPS 有 curl/tar/systemd。
set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.69.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_ENV="${SECRET_ENV:-$SCRIPT_DIR/secret.env}"

# ---- 0. 读取 secret.env ------------------------------------------------------
if [[ ! -f "$SECRET_ENV" ]]; then
  echo "缺少 $SECRET_ENV —— 先 cp secret.env.example secret.env 并填随机值" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$SECRET_ENV"; set +a

: "${FRP_AUTH_TOKEN:?secret.env 缺 FRP_AUTH_TOKEN}"
: "${FRP_DASHBOARD_PWD:?secret.env 缺 FRP_DASHBOARD_PWD}"
: "${FRP_SERVER_ADDR:?secret.env 缺 FRP_SERVER_ADDR}"

# ssh 目标:优先环境变量 VPS,否则 root@FRP_SERVER_ADDR。
VPS="${VPS:-root@$FRP_SERVER_ADDR}"
SSH=(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$VPS")

# ---- 子命令:--status / --uninstall -----------------------------------------
case "${1:-}" in
  --status)
    "${SSH[@]}" 'systemctl is-active frps 2>/dev/null; echo "--- ss -tlnp | 7000/7500 ---"; ss -tlnp | grep -E "7000|7500" || echo "(无监听)"; echo "--- 最近日志 ---"; tail -n 15 /var/log/frps.log 2>/dev/null || journalctl -u frps -n 15 --no-pager 2>/dev/null'
    exit 0 ;;
  --uninstall)
    echo ">> 停止并移除 frps(不动 nebula-lighthouse / ss-server)"
    "${SSH[@]}" 'systemctl disable --now frps 2>/dev/null || true; rm -f /etc/systemd/system/frps.service /usr/local/bin/frps; rm -rf /etc/frp; systemctl daemon-reload; echo "frps 已移除"; echo "--- 确认 nebula/ss-server 仍在 ---"; systemctl is-active nebula-lighthouse; docker ps --format "{{.Names}}" | grep -E "ss-server" || echo "ss-server?"'
    exit 0 ;;
esac

# ---- 1. 探测 VPS 架构,选 frp 二进制 -----------------------------------------
echo ">> 探测 VPS 架构"
ARCH="$("${SSH[@]}" 'uname -m')"
case "$ARCH" in
  x86_64|amd64) FRP_ARCH=amd64 ;;
  aarch64|arm64) FRP_ARCH=arm64 ;;
  *) echo "未知架构 $ARCH" >&2; exit 1 ;;
esac
TARBALL="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TARBALL}"
echo "   VPS arch=$ARCH → frp $FRP_VERSION linux/$FRP_ARCH"

# ---- 2. 渲染 frps.toml(注入 secret)----------------------------------------
echo ">> 渲染 frps.toml(注入 auth.token / dashboard 口令)"
TMP_TOML="$(mktemp)"
trap 'rm -f "$TMP_TOML"' EXIT
sed -e "s#__FRP_AUTH_TOKEN__#${FRP_AUTH_TOKEN}#" \
    -e "s#__FRP_DASHBOARD_PWD__#${FRP_DASHBOARD_PWD}#" \
    "$SCRIPT_DIR/config/frps.toml" > "$TMP_TOML"

# ---- 3. 在 VPS 上下载 frps 二进制 + 安装配置 + systemd ----------------------
echo ">> VPS:下载 frps 二进制 + 安装配置"
"${SSH[@]}" "set -e
  mkdir -p /etc/frp /tmp/frp-install
  cd /tmp/frp-install
  if [ ! -x /usr/local/bin/frps ] || ! /usr/local/bin/frps --version 2>/dev/null | grep -q '${FRP_VERSION}'; then
    echo '   下载 ${URL}'
    curl -fsSL -o frp.tgz '${URL}'
    tar xzf frp.tgz
    install -m 0755 frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps /usr/local/bin/frps
  else
    echo '   /usr/local/bin/frps 已是 ${FRP_VERSION},跳过下载'
  fi
  rm -rf /tmp/frp-install
  /usr/local/bin/frps --version"

echo ">> VPS:写入 /etc/frp/frps.toml + systemd 单元"
"${SSH[@]}" 'cat > /etc/frp/frps.toml' < "$TMP_TOML"
"${SSH[@]}" 'chmod 600 /etc/frp/frps.toml'
"${SSH[@]}" 'cat > /etc/systemd/system/frps.service' < "$SCRIPT_DIR/frps.service"

echo ">> VPS:校验配置合法性(frps verify)"
"${SSH[@]}" '/usr/local/bin/frps verify -c /etc/frp/frps.toml && echo "  frps.toml OK"'

echo ">> VPS:enable + (re)start frps"
"${SSH[@]}" 'systemctl daemon-reload; systemctl enable frps >/dev/null 2>&1; systemctl restart frps; sleep 1; systemctl is-active frps'

# ---- 4. 校验:监听 7000、未碰 nebula/ss-server ------------------------------
echo ">> 校验"
"${SSH[@]}" 'echo "  --- frps 监听 ---"; ss -tlnp | grep -E "7000|7500" || { echo "  ERROR: frps 未监听 7000"; exit 1; }
  echo "  --- 生产组件仍在(只读确认,未触碰)---"
  echo "  nebula-lighthouse: $(systemctl is-active nebula-lighthouse)"
  echo "  ss-server: $(docker ps --format "{{.Names}}" | grep -c ss-server) 个在跑"
  echo "  udp 4242(nebula)仍在: $(ss -ulnp | grep -c ":4242")"'

echo
echo ">> frps 部署完成。客户端/数据中心 frpc 用 serverAddr=${FRP_SERVER_ADDR} serverPort=7000 接入。"
echo "   dashboard(仅 VPS 本地):ssh -L 7500:127.0.0.1:7500 ${VPS} 后访问 http://127.0.0.1:7500"
