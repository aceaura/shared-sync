#!/usr/bin/env bash
# =============================================================================
# install-client.sh —— 角色3:同步客户端(Linux / macOS)一键安装器
#
# 在【客户端机器】上,用 enroll-client.sh 产出的配置包,把三件套装好并起好常驻:
#   * nebula(由 connd 托管为子进程)—— 撑 T0/T1。
#   * frpc(STCP visitor)—— 本地暴露 t2BackendAddr —— 撑 T2。
#   * connd —— 三层阶梯 + 固定本地端点 127.0.0.1:8418(引擎 server_url 永远指它)。
# 并(可选)把 v1 同步引擎的 server_url 指向该本地端点。
#
# 服务管理:Linux=systemd / macOS=launchd(均开机自启 + 崩溃重启)。
#
# 前置:把操作机上 v2/deploy/enroll-client.sh 产出的 dist/<名字>/ 整个目录拷到本机。
#
# 用法:
#   sudo bash v2/install/install-client.sh <配置包目录> [共享目录]
#     例:sudo bash v2/install/install-client.sh ./alice ~/SharedWork
#   sudo bash v2/install/install-client.sh --status
#   sudo bash v2/install/install-client.sh --uninstall
#
# 设计纪律:幂等;v1 引擎只读复用(仅 init 指向本地端点);私钥不落库。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ETC_NEBULA=/etc/nebula
ETC_FRP=/etc/frp
ETC_CONND=/etc/connd
BIN_DIR=/usr/local/bin
LOG_DIR=/var/log/shared-sync
LOCAL_ENDPOINT="http://127.0.0.1:8418/shared.git"
STATUS_URL="http://127.0.0.1:4243/status"

# 平台相关的服务名 / 单元模板(systemd: shared-sync-<role> / launchd: com.shared-sync.<role>)。
svc_name()  { if [[ "$(detect_svc_kind)" == systemd ]]; then echo "shared-sync-$1"; else echo "com.shared-sync.$1"; fi; }
unit_tmpl() { if [[ "$(detect_svc_kind)" == systemd ]]; then echo "$SCRIPT_DIR/units/shared-sync-$1.service.tmpl"; else echo "$SCRIPT_DIR/units/com.shared-sync.$1.plist.tmpl"; fi; }

MODE=install
BUNDLE=""
SHARED_DIR=""
for a in "$@"; do
  case "$a" in
    --status)    MODE=status ;;
    --uninstall) MODE=uninstall ;;
    -h|--help)   usage; exit 0 ;;
    *) if [[ -z "$BUNDLE" ]]; then BUNDLE="$a"; else SHARED_DIR="$a"; fi ;;
  esac
done

case "$MODE" in
  status)
    echo "--- connd ---"; svc_status "$(svc_name connd)"
    echo "--- frpc ---";  svc_status "$(svc_name frpc)"
    echo "--- 连接状态($STATUS_URL)---"
    if command -v curl >/dev/null 2>&1; then curl -fsS -m 5 "$STATUS_URL" 2>/dev/null || echo "(connd 未就绪)"; fi
    echo; exit 0 ;;
  uninstall)
    need_root
    svc_uninstall "$(svc_name connd)"
    svc_uninstall "$(svc_name frpc)"
    ok "客户端服务已移除(证书/配置保留在 $ETC_NEBULA、$ETC_CONND)"
    exit 0 ;;
esac

[[ -n "$BUNDLE" && -d "$BUNDLE" ]] || die "用法: $0 <配置包目录> [共享目录]   (enroll-client.sh 产出的 dist/<名字>)"
BUNDLE="$(cd "$BUNDLE" && pwd)"
for f in node.yml frpc-visitor.toml connd.yaml ca.crt ctl_key sshd_hostkey; do
  [[ -f "$BUNDLE/$f" ]] || die "配置包缺少 $f($BUNDLE 不是合法 enroll 产物?)"
done
CLIENT_CRT="$(ls "$BUNDLE"/client-*.crt 2>/dev/null | head -1)"
[[ -n "$CLIENT_CRT" ]] || die "配置包缺少 client-*.crt"
CERT_NAME="$(basename "$CLIENT_CRT" .crt)"      # client-alice
SHORT="${CERT_NAME#client-}"                     # alice
need_root

log "===== 客户端安装:$SHORT(证书 $CERT_NAME)====="

# 1) 二进制(Release 下载或本地编译/官方 release)
acquire_connd  "$BIN_DIR/connd"
acquire_frpc   "$BIN_DIR/frpc"
acquire_nebula "$BIN_DIR/nebula"

# 2) nebula 证书/配置 + 控制密钥(node.yml 内路径已是绝对 /etc/nebula/*)
$SUDO mkdir -p "$ETC_NEBULA" "$ETC_FRP" "$ETC_CONND" "$LOG_DIR"
$SUDO install -m 0644 "$BUNDLE/ca.crt"            "$ETC_NEBULA/ca.crt"
$SUDO install -m 0644 "$CLIENT_CRT"               "$ETC_NEBULA/$CERT_NAME.crt"
$SUDO install -m 0600 "$BUNDLE/$CERT_NAME.key"    "$ETC_NEBULA/$CERT_NAME.key"
$SUDO install -m 0644 "$BUNDLE/node.yml"          "$ETC_NEBULA/node.yml"
$SUDO install -m 0600 "$BUNDLE/ctl_key"           "$ETC_NEBULA/ctl_key"
$SUDO install -m 0600 "$BUNDLE/sshd_hostkey"      "$ETC_NEBULA/sshd_hostkey"
[[ -f "$BUNDLE/ctl_key.pub" ]]      && $SUDO install -m 0644 "$BUNDLE/ctl_key.pub"      "$ETC_NEBULA/ctl_key.pub"      || true
[[ -f "$BUNDLE/sshd_hostkey.pub" ]] && $SUDO install -m 0644 "$BUNDLE/sshd_hostkey.pub" "$ETC_NEBULA/sshd_hostkey.pub" || true

# 3) frpc visitor 配置(含 STCP secret → 0600)
$SUDO install -m 0600 "$BUNDLE/frpc-visitor.toml" "$ETC_FRP/frpc-visitor.toml"

# 4) connd 配置(把 nebula.binPath 绝对化为已安装路径)
tmp="$(mktemp)"
sed "s#^  binPath: .*#  binPath: $BIN_DIR/nebula#" "$BUNDLE/connd.yaml" > "$tmp"
$SUDO install -m 0644 "$tmp" "$ETC_CONND/connd.yaml"; rm -f "$tmp"

# 5) 服务:frpc(先)→ connd(后;connd 托管 nebula)
tmp="$(mktemp)"
render "$(unit_tmpl frpc)" "$tmp" FRPC_BIN="$BIN_DIR/frpc" FRPC_CONFIG="$ETC_FRP/frpc-visitor.toml" LOG_DIR="$LOG_DIR"
svc_install "$(svc_name frpc)" "$tmp"; rm -f "$tmp"
tmp="$(mktemp)"
render "$(unit_tmpl connd)" "$tmp" CONND_BIN="$BIN_DIR/connd" CONND_CONFIG="$ETC_CONND/connd.yaml" LOG_DIR="$LOG_DIR"
svc_install "$(svc_name connd)" "$tmp"; rm -f "$tmp"

svc_enable "$(svc_name frpc)"
svc_enable "$(svc_name connd)"

# 6)(可选)把 v1 同步引擎指向固定本地端点
if [[ -n "$SHARED_DIR" ]]; then
  if command -v sync_cli >/dev/null 2>&1; then
    log "初始化 v1 引擎:$SHARED_DIR → $LOCAL_ENDPOINT"
    sync_cli init --dir "$SHARED_DIR" --server "$LOCAL_ENDPOINT" --client-id "$SHORT" || \
      warn "sync_cli init 失败(可能已 init);手动确认 server_url=$LOCAL_ENDPOINT"
  else
    warn "未找到 sync_cli;请把你的客户端(GUI 或 CLI)server_url 指向 $LOCAL_ENDPOINT"
  fi
fi

# 7) 验证
sleep 3
echo
ok "客户端装好:frpc + connd 常驻(connd 托管 nebula),固定本地端点 127.0.0.1:8418。"
echo "引擎接入: server_url = $LOCAL_ENDPOINT"
echo "连接状态: bash v2/install/install-client.sh --status   (或 connd status)"
if command -v curl >/dev/null 2>&1; then
  echo "--- 当前连接 ---"; curl -fsS -m 5 "$STATUS_URL" 2>/dev/null || echo "(connd 启动中,稍后再查)"
fi
