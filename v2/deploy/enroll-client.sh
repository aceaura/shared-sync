#!/usr/bin/env bash
#
# enroll-client.sh — 一条命令把一台新客户端接入星型网络(DESIGN_v2 §7)
#
#   enroll-client.sh <客户端名> <lighthouse公网IP> [datacenter-overlay-ip]
#
# 做的事(类比 v1 的 client/daemon 安装器体验):
#   1. 经 gen-certs.sh 给该客户端签发一张 Nebula 证书(自动分配 10.77.0.11+ 的 overlay IP)。
#   2. 生成客户端专属的「控制 ssh 密钥对」(connd 查 nebula hostmap 判 T0/T1 用)。
#   3. 渲染该客户端的全部运行配置:
#        - node.yml         nebula 节点(连真 lighthouse,撑 T0/T1)
#        - frpc-visitor.toml frpc STCP visitor(本地 127.0.0.1:<VISITOR_PORT> = connd t2BackendAddr)
#        - connd.yaml        三层阶梯 + 固定本地端点 127.0.0.1:8418
#   4. 拷入 ca.crt + 该客户端 crt/key,产出一个【可直接跑的客户端配置包】:
#        v2/deploy/dist/<客户端名>/
#
# >>> 新增一台客户端 = 跑一次这个脚本。不动 lighthouse / 数据中心 / 其他客户端。<<<
#
# 产物目录可直接喂给:
#   * 容器联调(v2/deploy/star-e2e.sh 就是这么用的);
#   * 真机部署(把目录拷到目标机,装 nebula/frpc/connd 后按 README 起三件套)。
#
# 依赖:docker(签证书)、ssh-keygen。frps 端到端口令从 v2/frp/secret.env 读取
#       (与数据中心 frpc 同 token/secret;不入库)。
#
# 用法示例:
#   v2/deploy/enroll-client.sh alice 54.198.93.78
#   v2/deploy/enroll-client.sh bob   54.198.93.78
#   CLIENT_NAME 自动加前缀 client-(证书名 client-alice);产物目录用裸名 alice。
#
set -euo pipefail

NAME_RAW="${1:?用法: enroll-client.sh <客户端名> <lighthouse公网IP> [datacenter-overlay-ip]}"
LH_IP="${2:?用法: enroll-client.sh <客户端名> <lighthouse公网IP> [datacenter-overlay-ip]}"
DC_OVERLAY="${3:-10.77.0.2}"   # 数据中心 overlay(角色化命名,默认 datacenter=.2)

# 证书名加 client- 前缀(触发 gen-certs.sh 的自动 IP 分配),产物目录用裸名。
CERT_NAME="client-${NAME_RAW#client-}"   # 去重前缀再补,允许传 alice 或 client-alice
SHORT="${CERT_NAME#client-}"

# ---- 可调参数 ----------------------------------------------------------------
GIT_PORT="${GIT_PORT:-80}"               # 数据中心 git 容器内端口(生产镜像固定 80)
VISITOR_PORT="${VISITOR_PORT:-18418}"    # frpc visitor 本地口 = connd t2BackendAddr
LOCAL_PROXY="${LOCAL_PROXY:-127.0.0.1:8418}"  # connd 固定本地端点(引擎 server_url 指它)
STATUS_ADDR="${STATUS_ADDR:-127.0.0.1:4243}"
SSHD_PORT="${SSHD_PORT:-2222}"           # nebula 控制 sshd(仅回环)

# ---- 路径解析 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NEBULA_DIR="$ROOT/v2/nebula"
CERTS_DIR="$NEBULA_DIR/certs"
FRP_DIR="$ROOT/v2/frp"
SECRET_ENV="${SECRET_ENV:-$FRP_DIR/secret.env}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/dist/$SHORT}"

# ---- 依赖检查 ----------------------------------------------------------------
command -v ssh-keygen >/dev/null 2>&1 || { echo "ERROR: 需要 ssh-keygen" >&2; exit 1; }
[[ -f "$SECRET_ENV" ]] || {
  echo "ERROR: 缺少 $SECRET_ENV(cp $FRP_DIR/secret.env.example secret.env 并填 frps 端到端口令)" >&2
  exit 1
}
# shellcheck disable=SC1090
set -a; source "$SECRET_ENV"; set +a
: "${FRP_AUTH_TOKEN:?secret.env 需含 FRP_AUTH_TOKEN}"
: "${FRP_STCP_SECRET:?secret.env 需含 FRP_STCP_SECRET}"

echo ">> [enroll] 客户端=$SHORT (证书名 $CERT_NAME)  lighthouse=$LH_IP  数据中心 overlay=$DC_OVERLAY"

# ---- 1. 签发该客户端证书(自动分配 .11+;幂等)------------------------------
echo ">> [1/4] 签发 Nebula 证书(经 gen-certs.sh,自动分配 overlay IP)"
ASSIGN_LINE="$(bash "$NEBULA_DIR/gen-certs.sh" sign "$CERT_NAME" | grep '^ASSIGNED ')"
# ASSIGNED <name> <ip>/24
CLIENT_CIDR="$(awk '{print $3}' <<<"$ASSIGN_LINE")"
CLIENT_IP="${CLIENT_CIDR%/*}"
echo "   overlay IP = $CLIENT_CIDR"
for f in ca.crt "${CERT_NAME}.crt" "${CERT_NAME}.key"; do
  [[ -f "$CERTS_DIR/$f" ]] || { echo "ERROR: 证书缺失 $CERTS_DIR/$f" >&2; exit 1; }
done

# ---- 2. 控制 ssh 密钥 + nebula sshd hostkey --------------------------------
echo ">> [2/4] 生成控制 ssh 密钥(connd 查 hostmap)+ nebula sshd hostkey"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
ssh-keygen -t ed25519 -N "" -q -f "$OUT_DIR/ctl_key"
ssh-keygen -t ed25519 -N "" -q -f "$OUT_DIR/sshd_hostkey"
chmod 600 "$OUT_DIR/ctl_key"
CTL_PUBKEY="$(cat "$OUT_DIR/ctl_key.pub")"

# ---- 3. 渲染配置 ------------------------------------------------------------
echo ">> [3/4] 渲染 node.yml / frpc-visitor.toml / connd.yaml"

# nebula 节点(复用 v2/nebula/config/node.yml.tmpl 模板)
sed -e "s#__NODE_CERT__#${CERT_NAME}.crt#" \
    -e "s#__NODE_KEY__#${CERT_NAME}.key#" \
    -e "s#__LIGHTHOUSE_IP__#$LH_IP#" \
    -e "s#__SSHD_HOSTKEY__#sshd_hostkey#" \
    -e "s#__CTL_PUBKEY__#$CTL_PUBKEY#" \
    "$NEBULA_DIR/config/node.yml.tmpl" > "$OUT_DIR/node.yml"
# 控制 sshd 端口模板里固定 2222;若改了 SSHD_PORT 则替换。
[[ "$SSHD_PORT" != "2222" ]] && sed -i.bak "s#127.0.0.1:2222#127.0.0.1:$SSHD_PORT#" "$OUT_DIR/node.yml" && rm -f "$OUT_DIR/node.yml.bak"

# frpc visitor(复用 v2/frp/config/frpc-visitor.toml.tmpl 模板)
sed -e "s#__FRP_SERVER_ADDR__#$LH_IP#" \
    -e "s#__FRP_AUTH_TOKEN__#$FRP_AUTH_TOKEN#" \
    -e "s#__FRP_STCP_SECRET__#$FRP_STCP_SECRET#" \
    -e "s#__VISITOR_BIND_ADDR__#127.0.0.1#" \
    -e "s#__VISITOR_PORT__#$VISITOR_PORT#" \
    "$FRP_DIR/config/frpc-visitor.toml.tmpl" > "$OUT_DIR/frpc-visitor.toml"

# connd.yaml(peer=数据中心 overlay → T0/T1;t2BackendAddr=本地 visitor → T2)
cat > "$OUT_DIR/connd.yaml" <<YAML
# connd.yaml —— 客户端 $SHORT(overlay $CLIENT_IP)。enroll-client.sh 生成。
# 引擎 server_url 永远填:http://$LOCAL_PROXY/shared.git(切层透明,见 DESIGN_v2 §2.1)。
peerOverlayIP: $DC_OVERLAY          # 数据中心 overlay(T0/T1 直达后端)
dataCenterPort: $GIT_PORT           # 数据中心 git 端口(overlay 内)
localProxyAddr: $LOCAL_PROXY        # 固定本地端点(引擎只连它)
t2BackendAddr: 127.0.0.1:$VISITOR_PORT   # frpc visitor 本地口 = T2 上游 + T2 探测
lighthouseUnderlay: ""              # 留空=真实判定 T0/T1(填 LH 公网可强制视作 relay 调试)
statusAddr: $STATUS_ADDR
control:
  enabled: true
  host: 127.0.0.1
  port: $SSHD_PORT
  user: ctl
  keyPath: /etc/nebula/ctl_key      # 容器/部署内路径(下方 README 说明)
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

# 证书 / CA
cp "$CERTS_DIR/ca.crt" "$CERTS_DIR/${CERT_NAME}.crt" "$CERTS_DIR/${CERT_NAME}.key" "$OUT_DIR/"

# ---- 4. 客户端包 README -----------------------------------------------------
echo ">> [4/4] 写客户端包 README + 清单"
cat > "$OUT_DIR/README.md" <<MD
# 客户端配置包:$SHORT

由 \`v2/deploy/enroll-client.sh $NAME_RAW $LH_IP $DC_OVERLAY\` 生成。

| 项 | 值 |
|---|---|
| 客户端名(证书) | \`$CERT_NAME\` |
| overlay IP | \`$CLIENT_IP\` |
| lighthouse 公网 | \`$LH_IP:4242\` |
| 数据中心 overlay | \`$DC_OVERLAY:$GIT_PORT\` |
| frps(T2)中继 | \`$LH_IP:7000\` |
| 引擎 server_url(永不变) | \`http://$LOCAL_PROXY/shared.git\` |
| connd 状态端点 | \`http://$STATUS_ADDR/status\` |

## 包内文件
- \`ca.crt\`                Nebula CA(公钥,验证 overlay 成员)
- \`$CERT_NAME.crt/.key\`   本客户端证书 + 私钥(**私钥勿外泄/勿入库**)
- \`node.yml\`             nebula 节点配置(连真 lighthouse,撑 T0/T1)
- \`frpc-visitor.toml\`    frpc STCP visitor(本地 127.0.0.1:$VISITOR_PORT = connd t2BackendAddr)
- \`connd.yaml\`           三层阶梯 + 固定本地端点 $LOCAL_PROXY
- \`ctl_key/.pub\`         connd 查 nebula hostmap 的控制 ssh 密钥
- \`sshd_hostkey/.pub\`    nebula 控制 sshd 的 host key

## 起三件套(部署目标机;把本目录挂到 /etc/nebula 与 /etc/frp)
\`\`\`bash
# 1) frpc visitor(常驻 sidecar;本地暴露 127.0.0.1:$VISITOR_PORT)
frpc -c /etc/frp/frpc-visitor.toml &
# 2) connd(管 nebula 子进程 + 三层阶梯 + 代理 $LOCAL_PROXY)
connd run -config /etc/nebula/connd.yaml
# 3) 引擎:server_url=http://$LOCAL_PROXY/shared.git(对走哪一层零感知)
\`\`\`

新增另一台客户端 = 再跑一次 enroll-client.sh,不动本机与其他节点。
MD

cat > "$OUT_DIR/MANIFEST.txt" <<TXT
client=$SHORT cert=$CERT_NAME overlay=$CLIENT_IP lighthouse=$LH_IP datacenter=$DC_OVERLAY
$(cd "$OUT_DIR" && ls -1 | sort)
TXT

echo
echo ">> 完成。客户端配置包:$OUT_DIR"
ls -la "$OUT_DIR"
echo
echo ">> overlay IP = $CLIENT_IP  |  引擎 server_url = http://$LOCAL_PROXY/shared.git"
echo ">> 提醒:${CERT_NAME}.key / ctl_key / sshd_hostkey 为私钥,勿入库(dist/ 已被忽略)。"
