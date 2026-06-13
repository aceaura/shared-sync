#!/bin/bash
# shared-sync 服务端入口:幂等初始化 bare 仓库 + 渲染 nginx 配置 + 启动 fcgiwrap/nginx。
set -euo pipefail

GIT_ROOT=/srv/git
REPO="$GIT_ROOT/shared.git"
SERVER_LOG="$GIT_ROOT/server.log"
TEMPLATE=/opt/shared-sync/nginx.conf.template
HOOK_SRC=/opt/shared-sync/hooks/pre-receive

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [entrypoint] $*" | tee -a "$SERVER_LOG" >&2
}

mkdir -p "$GIT_ROOT"
touch "$SERVER_LOG"

# ---- 仓库初始化(幂等:每次启动都校正配置与钩子) ----
if [ ! -d "$REPO/objects" ]; then
    git init --bare --initial-branch=current "$REPO"
    log "initialized bare repository $REPO"
fi
git --git-dir="$REPO" config receive.denyNonFastForwards true
git --git-dir="$REPO" config receive.denyDeletes true
git --git-dir="$REPO" config http.receivepack true
# 空仓库被 clone 时让客户端默认分支为 current
git --git-dir="$REPO" symbolic-ref HEAD refs/heads/current
install -m 0755 "$HOOK_SRC" "$REPO/hooks/pre-receive"

# 残留的维护锁会拒绝所有 push;不自动删除(可能确有压缩在跑),只告警。
if [ -e "$GIT_ROOT/maintenance.lock" ]; then
    log "WARNING: maintenance.lock exists, all pushes are rejected; remove it manually if no compress job is running"
fi

# ---- Basic Auth(GIT_AUTH_USER/GIT_AUTH_PASSWORD 均非空才启用) ----
if [ -n "${GIT_AUTH_USER:-}" ] && [ -n "${GIT_AUTH_PASSWORD:-}" ]; then
    htpasswd -bc /etc/nginx/.htpasswd "$GIT_AUTH_USER" "$GIT_AUTH_PASSWORD" >/dev/null 2>&1
    chown root:nginx /etc/nginx/.htpasswd
    chmod 0640 /etc/nginx/.htpasswd
    AUTH_DIRECTIVES=$'auth_basic "shared-sync";\n            auth_basic_user_file /etc/nginx/.htpasswd;'
    log "basic auth enabled for user '$GIT_AUTH_USER'"
else
    AUTH_DIRECTIVES='auth_basic off;'
    log "basic auth disabled (anonymous read/write)"
fi
export AUTH_DIRECTIVES
# 只替换 AUTH_DIRECTIVES,保留 $uri 等 nginx 变量
envsubst '${AUTH_DIRECTIVES}' < "$TEMPLATE" > /etc/nginx/nginx.conf
nginx -t

# 仓库由 git 用户(fcgiwrap 运行身份)持有;同时修复 docker exec 以 root 误操作留下的文件
chown -R git:git "$GIT_ROOT"

# ---- fcgiwrap(以 git 用户跑 git-http-backend)+ nginx ----
rm -f /run/fcgiwrap.socket
# HOME 必须指向 git 用户家目录,否则 git-http-backend 会去读 root 的 ~/.config 并告警
spawn-fcgi -s /run/fcgiwrap.socket -M 0666 -u git -g git -P /run/fcgiwrap.pid \
    -- /usr/bin/env HOME=/home/git /usr/bin/fcgiwrap
log "fcgiwrap started, starting nginx"
exec nginx -g 'daemon off;'
