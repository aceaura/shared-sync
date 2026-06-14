#!/usr/bin/env bash
# datacenter-entrypoint.sh —— Phase3 数据中心容器入口。
#
# 起三件套(都在同一容器):
#   1. git server —— 复用生产镜像入口 /opt/shared-sync/entrypoint.sh(nginx+git-http-backend,
#      serve shared.git/current,监听容器内 80)。后台运行。
#   2. nebula 节点(node-company=10.77.0.3),连真 lighthouse;让客户端 T0/T1 经 overlay 直达 git。
#   3. frpc(STCP 服务端),把本地 git(80)注册到 VPS frps;让客户端 visitor 经 T2(TCP)达同一 git。
#
# 环境变量:
#   NEBULA_ENABLED   是否起 nebula(默认 1;置 0 则只 git+frpc,纯 T2 验证)。
#   GIT_PORT         git server 容器内端口(生产镜像固定 80;frpc 转发它)。
set -euo pipefail

GIT_PORT="${GIT_PORT:-80}"

echo "[dc] 启动生产 git server(/opt/shared-sync/entrypoint.sh,监听容器内 80)"
/opt/shared-sync/entrypoint.sh &
GIT_PID=$!

echo "[dc] 等 git server 就绪(容器内 127.0.0.1:$GIT_PORT)"
for i in $(seq 1 30); do
  if git ls-remote "http://127.0.0.1:$GIT_PORT/shared.git" >/dev/null 2>&1; then
    echo "[dc] git server 就绪"
    break
  fi
  sleep 1
done

# 生产入口起的是【空】bare 仓库(HEAD 指向未出生的 refs/heads/current,无任何 ref)。
# 为让 e2e 的 git ls-remote 能列到真实 ref(证明内容经各层端到端送达,而非仅 TCP 通),
# 这里幂等地往 bare 仓库直接写一个初始提交到 refs/heads/current(纯 plumbing,无工作树)。
REPO="/srv/git/shared.git"
if [ -d "$REPO/objects" ] && [ -z "$(git --git-dir="$REPO" for-each-ref 2>/dev/null)" ]; then
  echo "[dc] 仓库为空,写入初始提交(refs/heads/current)以便 e2e 列 ref"
  BLOB="$(printf 'shared-sync v2 Phase3 T2 e2e seed\n' | git --git-dir="$REPO" hash-object -w --stdin)"
  TREE="$(printf '100644 blob %s\tREADME\n' "$BLOB" | git --git-dir="$REPO" mktree)"
  COMMIT="$(echo 'phase3 seed' | GIT_AUTHOR_NAME=ss GIT_AUTHOR_EMAIL=ss@local \
            GIT_COMMITTER_NAME=ss GIT_COMMITTER_EMAIL=ss@local \
            git --git-dir="$REPO" commit-tree "$TREE")"
  git --git-dir="$REPO" update-ref refs/heads/current "$COMMIT"
  # 修复属主(生产入口以 git 用户跑 http-backend)。
  chown -R git:git "$REPO" 2>/dev/null || true
fi
echo "[dc] 当前 refs:"
git ls-remote "http://127.0.0.1:$GIT_PORT/shared.git" | head -3 || true

# ---- nebula(可选;让 T0/T1 可达数据中心 overlay git)-----------------------
if [[ "${NEBULA_ENABLED:-1}" == "1" ]]; then
  echo "[dc] 启动 nebula 节点(node-company=10.77.0.3)"
  nebula -config /etc/nebula/node.yml &
  for i in $(seq 1 20); do
    ip -4 addr show nebula1 >/dev/null 2>&1 && break
    sleep 1
  done
  ip -4 addr show nebula1 2>/dev/null | awk '/inet /{print "[dc] overlay="$2}'
fi

# ---- frpc(STCP 服务端):把 git(80)暴露给 VPS frps ------------------------
echo "[dc] 启动 frpc(STCP 服务端 ss-git → 127.0.0.1:$GIT_PORT)"
exec frpc -c /etc/frp/frpc.toml
