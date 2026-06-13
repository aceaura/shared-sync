#!/bin/bash
# shared-sync 历史压缩:把 refs/heads/current 重写为单个同树根提交(snapshot)。
# 用法:compress.sh [repo_path]   (默认 /srv/git/shared.git)
# 流程:maintenance.lock → 记录 old → commit-tree 同树新根提交 →
#       update-ref 带旧值原子更新 → 自校验新旧 tree 一致 → 写 snapshot-id → 删锁。
# 任何一步失败都不会破坏 current:update-ref 带旧值校验,校验失败原子回滚。
set -euo pipefail

REPO="${1:-/srv/git/shared.git}"
ROOT=$(dirname "$REPO")
LOCK="$ROOT/maintenance.lock"
SERVER_LOG="$ROOT/server.log"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [compress] $*" | tee -a "$SERVER_LOG"
}

[ -d "$REPO" ] || { echo "compress.sh: repository not found: $REPO" >&2; exit 1; }

# 容器内 docker exec 默认是 root;降权到仓库属主,避免产生 root 属主的对象
# 导致后续(以 git 用户运行的)receive-pack 写对象失败。
if [ "$(id -u)" = "0" ] && command -v su-exec >/dev/null 2>&1; then
    owner=$(stat -c %U "$REPO" 2>/dev/null || stat -f %Su "$REPO")
    if [ "$owner" != "root" ] && [ "$owner" != "UNKNOWN" ]; then
        exec su-exec "$owner" "$0" "$REPO"
    fi
fi

# 原子创建锁(noclobber);已存在说明有维护任务在跑,放弃本次压缩。
if ! (set -C; echo "compress pid $$ started $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK") 2>/dev/null; then
    log "ABORT: $LOCK already exists (another maintenance job running?)"
    exit 1
fi
trap 'rm -f "$LOCK"' EXIT

log "compress start: repo=$REPO"

old=$(git --git-dir="$REPO" rev-parse --verify --quiet refs/heads/current) || {
    log "compress skipped: refs/heads/current does not exist (empty repository)"
    exit 0
}
old_tree=$(git --git-dir="$REPO" rev-parse "$old^{tree}")
log "old current=$old tree=$old_tree"

new=$(git --git-dir="$REPO" commit-tree "$old_tree" -m "snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)")
log "new root snapshot commit=$new"

# 带旧值的原子更新:若期间 current 被并发改动(不应发生,锁已挡 push),此处直接失败。
git --git-dir="$REPO" update-ref refs/heads/current "$new" "$old"

# 自校验:压缩前后树必须完全一致,否则原子回滚。
new_tree=$(git --git-dir="$REPO" rev-parse "$new^{tree}")
if [ "$new_tree" != "$old_tree" ]; then
    git --git-dir="$REPO" update-ref refs/heads/current "$old" "$new"
    log "ERROR: tree mismatch after compress (old=$old_tree new=$new_tree), rolled back to $old"
    exit 1
fi

echo "$new" > "$ROOT/snapshot-id"
log "current updated: $old -> $new (tree unchanged: $old_tree); snapshot-id written"
log "compress done"
