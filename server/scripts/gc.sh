#!/bin/bash
# shared-sync 垃圾回收:过期 reflog + aggressive gc,带宽限期保护正在 fetch 的客户端。
# 用法:gc.sh [repo_path] [grace_hours=24]
set -euo pipefail

REPO="${1:-/srv/git/shared.git}"
GRACE_HOURS="${2:-24}"
ROOT=$(dirname "$REPO")
SERVER_LOG="$ROOT/server.log"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [gc] $*" | tee -a "$SERVER_LOG"
}

[ -d "$REPO" ] || { echo "gc.sh: repository not found: $REPO" >&2; exit 1; }

# 同 compress.sh:root 执行时降权到仓库属主,避免留下 root 属主文件。
if [ "$(id -u)" = "0" ] && command -v su-exec >/dev/null 2>&1; then
    owner=$(stat -c %U "$REPO" 2>/dev/null || stat -f %Su "$REPO")
    if [ "$owner" != "root" ] && [ "$owner" != "UNKNOWN" ]; then
        exec su-exec "$owner" "$0" "$REPO" "$GRACE_HOURS"
    fi
fi

size_before=$(du -sh "$REPO" | awk '{print $1}')
log "gc start: repo=$REPO grace=${GRACE_HOURS}h size_before=$size_before"

git --git-dir="$REPO" reflog expire --expire=now --all
git --git-dir="$REPO" \
    -c gc.reflogExpire=now \
    -c gc.reflogExpireUnreachable=now \
    gc --aggressive --prune="$GRACE_HOURS hours ago"

size_after=$(du -sh "$REPO" | awk '{print $1}')
log "gc done: size $size_before -> $size_after"
