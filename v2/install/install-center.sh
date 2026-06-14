#!/usr/bin/env bash
# =============================================================================
# install-center.sh —— 角色1:中转中心(公网 VPS)一键安装器
#
# 在一台公网 VPS 上把【星型中转中心】两件套装好并起好(都是 systemd 常驻):
#   * nebula lighthouse  —— overlay 10.77.0.1,打洞协调 + UDP 中继(撑 T0/T1)。
#   * frps               —— frp 中继服务器 7000,TCP 隧道兜底 VPS 侧(撑 T2)。
#
# 本脚本是【编排器】:直接复用并调用现有两个已验证脚本(不重造逻辑):
#   v2/deploy/deploy-lighthouse.sh  + v2/frp/deploy-frps.sh
# 两者都对 VPS 幂等(重复跑 = 校正配置 + 重启服务),故本脚本天然幂等。
#
# 在【本机】运行(经 ssh 推到 VPS);不需要在 VPS 上跑。
#
# 前置:
#   1) v2/nebula/gen-certs.sh 已生成 certs/(ca.crt + lighthouse.crt/.key)。
#   2) v2/frp/secret.env 已从 secret.env.example 复制并填随机口令。
#   3) 本机 ssh 免密登录 VPS;VPS 放行 UDP 4242(nebula)+ TCP 7000(frps)。
#
# 用法:
#   bash v2/install/install-center.sh root@<VPS公网IP>
#   bash v2/install/install-center.sh --status   root@<VPS公网IP>
#   bash v2/install/install-center.sh --uninstall root@<VPS公网IP>   # 仅移除 frps;lighthouse 用下方提示手动停
#
# 设计纪律:只新增/校正 lighthouse + frps;不动 VPS 上任何其他服务。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_LH="$ROOT/v2/deploy/deploy-lighthouse.sh"
DEPLOY_FRPS="$ROOT/v2/frp/deploy-frps.sh"

# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=install
SSH_TARGET=""
for a in "$@"; do
  case "$a" in
    --status)    MODE=status ;;
    --uninstall) MODE=uninstall ;;
    -h|--help)   usage; exit 0 ;;
    *)           SSH_TARGET="$a" ;;
  esac
done
[[ -n "$SSH_TARGET" ]] || { echo "用法: $0 [--status|--uninstall] <ssh目标>  例如 root@54.198.93.78" >&2; exit 1; }

[[ -f "$DEPLOY_LH" ]]   || die "找不到 $DEPLOY_LH"
[[ -f "$DEPLOY_FRPS" ]] || die "找不到 $DEPLOY_FRPS"

case "$MODE" in
  status)
    log "中转中心状态(VPS=$SSH_TARGET)"
    echo "--- nebula-lighthouse ---"
    ssh -o BatchMode=yes "$SSH_TARGET" 'systemctl is-active nebula-lighthouse 2>/dev/null; ip -4 addr show nebula1 2>/dev/null | awk "/inet /{print \"  overlay \"\$2}"; ss -ulnp 2>/dev/null | awk "/:4242 /{print \"  udp \"\$5; exit}"' || true
    echo "--- frps ---"
    VPS="$SSH_TARGET" bash "$DEPLOY_FRPS" --status || true
    exit 0 ;;
  uninstall)
    warn "移除 frps(deploy-frps.sh --uninstall);lighthouse 如需停用请手动:"
    warn "  ssh $SSH_TARGET 'systemctl disable --now nebula-lighthouse'"
    VPS="$SSH_TARGET" bash "$DEPLOY_FRPS" --uninstall || true
    exit 0 ;;
esac

# ---- 安装:先 lighthouse(T0/T1),再 frps(T2)----------------------------
log "===== 中转中心安装开始:VPS=$SSH_TARGET ====="

log "[1/2] 部署 nebula lighthouse(overlay 10.77.0.1,UDP 4242)"
bash "$DEPLOY_LH" "$SSH_TARGET"

log "[2/2] 部署 frps(TCP 7000,T2 中继 VPS 侧)"
# deploy-frps.sh 用 secret.env 的 FRP_SERVER_ADDR 默认 VPS;这里显式用同一 ssh 目标更稳。
VPS="$SSH_TARGET" bash "$DEPLOY_FRPS"

echo
ok "中转中心装好:nebula-lighthouse + frps 均为 systemd 常驻。"
echo "下一步:在数据中心节点跑 install-datacenter.sh,再给每台客户端 enroll + install-client.sh。"
echo "状态:bash v2/install/install-center.sh --status $SSH_TARGET"
