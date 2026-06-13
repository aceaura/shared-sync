#!/bin/bash
# test/e2e.sh — shared-sync 端到端验收脚本(DESIGN.md §7,对照需求 §19)
#
# 用法:
#   test/e2e.sh [--docker|--local]
#     --docker  docker compose 启动本工程 server,URL=http://localhost:8418/shared.git
#     --local   本地临时 bare 仓库(无 Docker 环境时用)
#   不传参数:docker info 可用则 --docker,否则 --local。
#
# 环境变量:
#   E2E_SETTLE_SECONDS  写文件后等待文件稳定的秒数(默认 3,须 > fileStableDelaySeconds=2)
#   E2E_KEEP_WORK=1     成功时也保留 /tmp 工作区
#
# 兼容 macOS 自带 bash 3.2(不使用关联数组/mapfile/${var^^} 等 4.x 特性)。
# 注意:故意不用 set -e —— 断言失败要计数后继续跑,最后统一汇总。

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

export PATH="/opt/homebrew/bin:$PATH"
export GIT_TERMINAL_PROMPT=0

# ---------- 全局状态 ----------
WORK="/tmp/shared-sync-e2e-$$"
PC_A="$WORK/pcA"
PC_B="$WORK/pcB"
LOG_DIR="$WORK/logs"
PROBE_GIT="$WORK/probe.git"          # 用于窥探远端 current 的本地裸仓库
CLI="$ROOT/client/engine/build/sync_cli"
COMPOSE_FILE="$ROOT/server/docker-compose.yml"

MODE=""
SERVER_URL=""
SERVER_REPO=""                        # 仅 local 模式
SERVER_STARTED=0                      # 仅 docker 模式:up 成功后置 1
COMPOSE_BIN=""                        # "docker"(compose v2 插件)或 "docker-compose"
COMPOSE_SERVICE=""
CONTAINER_ID=""

SETTLE_SECONDS="${E2E_SETTLE_SECONDS:-3}"
PASS_COUNT=0
FAIL_COUNT=0
FAILED_IDS=""
SYNC_SEQ=0
LAST_SYNC_LOG=""

# ---------- 参数解析 ----------
case "${1:-}" in
  --docker) MODE=docker ;;
  --local)  MODE=local ;;
  "")       ;;
  *) echo "用法: $0 [--docker|--local]" >&2; exit 2 ;;
esac
if [ -z "$MODE" ]; then
  if docker info >/dev/null 2>&1; then MODE=docker; else MODE=local; fi
fi

# ---------- 基础工具函数 ----------

pass() {
  local id="$1"; shift
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "[$id] PASS $*"
}

fail() {
  local id="$1"; shift
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_IDS="$FAILED_IDS $id"
  echo "[$id] FAIL $*"
  dump_state
}

# 致命错误:环境/前置条件不满足,无法继续跑任何断言。
fatal() {
  echo "FATAL: $*" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
  dump_state
  exit 1
}

section() {
  echo
  echo "==== $* ===="
}

print_tree() {
  local dir="$1" label="$2"
  echo "    ---- $label 目录树 ----"
  if [ -d "$dir" ]; then
    find "$dir" \( -name .sync -prune \) -o -print 2>/dev/null \
      | sed "s|^$dir|.|" | sed 's/^/    /'
  else
    echo "    (目录不存在: $dir)"
  fi
}

tail_sync_logs() {
  local dir="$1" label="$2" f
  f=$(ls -t "$dir/.sync/logs/"*.log 2>/dev/null | head -n 1)
  if [ -n "$f" ] && [ -f "$f" ]; then
    echo "    ---- $label .sync/logs 尾部 ($(basename "$f")) ----"
    tail -n 20 "$f" | sed 's/^/    /'
  fi
}

# 失败排查信息:两侧目录树 + .sync/logs 尾部 + 最近一次 sync 输出。
dump_state() {
  echo "    ======== 排查信息 ========"
  print_tree "$PC_A" pcA
  print_tree "$PC_B" pcB
  tail_sync_logs "$PC_A" pcA
  tail_sync_logs "$PC_B" pcB
  if [ -n "$LAST_SYNC_LOG" ] && [ -f "$LAST_SYNC_LOG" ]; then
    echo "    ---- 最近一次 sync 输出 ($LAST_SYNC_LOG) ----"
    tail -n 20 "$LAST_SYNC_LOG" | sed 's/^/    /'
  fi
  echo "    =========================="
}

write_file() {
  local file="$1" content="$2"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" > "$file"
}

# 等待新写入的文件越过 fileStableDelaySeconds 稳定窗口(否则 engine 冻结该路径不上传)。
settle() {
  sleep "$SETTLE_SECONDS"
}

run_sync() {
  local dir="$1" label="$2" log rc
  SYNC_SEQ=$((SYNC_SEQ + 1))
  log="$LOG_DIR/sync-$label-$(printf '%03d' "$SYNC_SEQ").log"
  "$CLI" sync --dir "$dir" >"$log" 2>&1
  rc=$?
  LAST_SYNC_LOG="$log"
  if [ "$rc" -ne 0 ]; then
    echo "    WARN: sync $label 退出码 $rc(见 $log)"
  fi
  return "$rc"
}

syncA() { run_sync "$PC_A" A; }
syncB() { run_sync "$PC_B" B; }

# ---------- 断言函数 ----------

assert_file_content() {
  local id="$1" file="$2" expected="$3" desc="$4"
  if [ -f "$file" ] && [ "$(cat "$file" 2>/dev/null)" = "$expected" ]; then
    pass "$id" "$desc"
  else
    fail "$id" "$desc(文件: $file)"
  fi
}

assert_absent() {
  local id="$1" file="$2" desc="$3"
  if [ ! -e "$file" ]; then
    pass "$id" "$desc"
  else
    fail "$id" "$desc(仍存在: $file)"
  fi
}

# 在目录(排除 .sync)的任意普通文件里查找完整字符串。
content_somewhere() {
  local dir="$1" needle="$2" f
  while IFS= read -r f; do
    if grep -qF -- "$needle" "$f" 2>/dev/null; then
      return 0
    fi
  done < <(find "$dir" \( -name .sync -prune \) -o -type f -print 2>/dev/null)
  return 1
}

assert_content_somewhere() {
  local id="$1" dir="$2" needle="$3" desc="$4"
  if content_somewhere "$dir" "$needle"; then
    pass "$id" "$desc"
  else
    fail "$id" "$desc(目录 $dir 中找不到内容: $needle)"
  fi
}

# ---------- 服务端 ----------

compose() {
  if [ "$COMPOSE_BIN" = "docker-compose" ]; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

wait_server_ready() {
  local deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if git ls-remote "$SERVER_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_server_docker() {
  command -v docker >/dev/null 2>&1 || fatal "docker 不可用,请改用 --local"
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN=docker
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_BIN=docker-compose
  else
    fatal "docker compose / docker-compose 均不可用"
  fi
  [ -f "$COMPOSE_FILE" ] || fatal "缺少 $COMPOSE_FILE"
  echo "清理可能残留的旧容器/卷 ..."
  compose down -v >/dev/null 2>&1
  echo "启动服务端容器(docker compose up -d --build)..."
  if ! compose up -d --build >"$LOG_DIR/compose-up.log" 2>&1; then
    tail -n 30 "$LOG_DIR/compose-up.log"
    fatal "docker compose up 失败(见 $LOG_DIR/compose-up.log)"
  fi
  SERVER_STARTED=1
  SERVER_URL="http://localhost:8418/shared.git"
  echo "等待服务端就绪: $SERVER_URL ..."
  wait_server_ready || fatal "等待服务端就绪超时(120s)"
  COMPOSE_SERVICE=$(compose ps --services 2>/dev/null | head -n 1 | tr -d '\r')
  CONTAINER_ID=$(compose ps -q 2>/dev/null | head -n 1 | tr -d '\r')
  echo "服务端就绪(service=${COMPOSE_SERVICE:-?} container=${CONTAINER_ID:-?})"
}

start_server_local() {
  SERVER_REPO="$WORK/server/shared.git"
  mkdir -p "$WORK/server"
  git init --bare -q "$SERVER_REPO" || fatal "git init --bare 失败"
  git --git-dir="$SERVER_REPO" config receive.denyNonFastForwards true
  git --git-dir="$SERVER_REPO" config receive.denyDeletes true
  if [ -f "$ROOT/server/hooks/pre-receive" ]; then
    mkdir -p "$SERVER_REPO/hooks"
    cp "$ROOT/server/hooks/pre-receive" "$SERVER_REPO/hooks/pre-receive"
    chmod +x "$SERVER_REPO/hooks/pre-receive"
  else
    echo "    提示:server/hooks/pre-receive 不存在,local 模式跳过钩子安装"
  fi
  SERVER_URL="$SERVER_REPO"   # 本地路径形式的 git URL
  echo "本地 bare 仓库就绪: $SERVER_REPO"
}

# 在服务端容器内执行命令(仅 docker 模式)。
server_exec() {
  if [ -n "$COMPOSE_SERVICE" ]; then
    compose exec -T "$COMPOSE_SERVICE" "$@"
  elif [ -n "$CONTAINER_ID" ]; then
    docker exec -i "$CONTAINER_ID" "$@"
  else
    echo "server_exec: 未找到服务端容器" >&2
    return 1
  fi
}

server_compress() {
  local log="$LOG_DIR/compress.log"
  if [ "$MODE" = docker ]; then
    # 镜像把脚本装在 /opt/shared-sync/scripts 并软链到 /usr/local/bin(见 server/Dockerfile)
    server_exec compress.sh /srv/git/shared.git >"$log" 2>&1
  else
    if [ ! -f "$ROOT/server/scripts/compress.sh" ]; then
      echo "server/scripts/compress.sh 不存在" >"$log"
      return 1
    fi
    bash "$ROOT/server/scripts/compress.sh" "$SERVER_REPO" >"$log" 2>&1
  fi
}

server_gc() {
  local log="$LOG_DIR/gc.log"
  # grace_hours=0:立即修剪压缩产生的不可达对象,便于断言体积下降
  if [ "$MODE" = docker ]; then
    server_exec gc.sh /srv/git/shared.git 0 >"$log" 2>&1
  else
    if [ ! -f "$ROOT/server/scripts/gc.sh" ]; then
      echo "server/scripts/gc.sh 不存在" >"$log"
      return 1
    fi
    bash "$ROOT/server/scripts/gc.sh" "$SERVER_REPO" 0 >"$log" 2>&1
  fi
}

objects_size_kb() {
  if [ "$MODE" = docker ]; then
    server_exec du -sk /srv/git/shared.git/objects 2>/dev/null | awk '{print $1}' | tr -d '\r'
  else
    du -sk "$SERVER_REPO/objects" 2>/dev/null | awk '{print $1}'
  fi
}

loose_object_count() {
  if [ "$MODE" = docker ]; then
    server_exec git --git-dir=/srv/git/shared.git count-objects -v 2>/dev/null \
      | awk '$1=="count:"{print $2}' | tr -d '\r'
  else
    git --git-dir="$SERVER_REPO" count-objects -v 2>/dev/null | awk '$1=="count:"{print $2}'
  fi
}

# ---------- 远端 current 窥探(probe 仓库,两种模式统一) ----------

remote_head() {
  git ls-remote "$SERVER_URL" refs/heads/current 2>/dev/null | awk '{print $1}'
}

remote_fetch() {
  # 强制 refspec:历史压缩重写后也能更新 probe 的 current
  git --git-dir="$PROBE_GIT" fetch -q -f "$SERVER_URL" \
    "+refs/heads/current:refs/heads/current" >/dev/null 2>&1
}

remote_tree_hash() {
  remote_fetch || return 1
  git --git-dir="$PROBE_GIT" rev-parse 'current^{tree}' 2>/dev/null
}

remote_ls_names() {
  remote_fetch || return 1
  git --git-dir="$PROBE_GIT" ls-tree -r --name-only current 2>/dev/null
}

# ---------- 准备 ----------

build_cli() {
  if [ -x "$CLI" ]; then
    echo "复用已编译 CLI: $CLI"
    return 0
  fi
  command -v dart >/dev/null 2>&1 || fatal "dart 不在 PATH(已尝试 /opt/homebrew/bin)"
  echo "编译 sync_cli ..."
  if ! ( cd "$ROOT/client/engine" \
         && mkdir -p build \
         && dart pub get \
         && dart compile exe bin/sync_cli.dart -o build/sync_cli ) \
       >"$LOG_DIR/build.log" 2>&1; then
    tail -n 30 "$LOG_DIR/build.log"
    fatal "sync_cli 编译失败(见 $LOG_DIR/build.log)"
  fi
}

client_init() {
  local dir="$1" id="$2" log="$LOG_DIR/init-$2.log"
  if ! "$CLI" init --dir "$dir" --server "$SERVER_URL" --client-id "$id" >"$log" 2>&1; then
    tail -n 20 "$log"
    fatal "sync_cli init $id 失败(见 $log)"
  fi
}

cleanup() {
  if [ "$MODE" = docker ] && [ "$SERVER_STARTED" = 1 ]; then
    echo "清理:docker compose down -v"
    compose down -v >/dev/null 2>&1
  fi
  if [ "$FAIL_COUNT" -eq 0 ] && [ "${E2E_KEEP_WORK:-0}" != "1" ]; then
    rm -rf "$WORK"
  else
    echo "工作区保留于: $WORK(日志: $LOG_DIR)"
  fi
}
trap cleanup EXIT

# ============================================================
# 主流程
# ============================================================

section "准备(mode=$MODE,工作区=$WORK)"
mkdir -p "$PC_A" "$PC_B" "$LOG_DIR" || fatal "无法创建工作区 $WORK"
build_cli
if [ "$MODE" = docker ]; then
  start_server_docker
else
  start_server_local
fi
git init --bare -q "$PROBE_GIT" || fatal "无法创建 probe 仓库"
client_init "$PC_A" PC-A
client_init "$PC_B" PC-B
echo "客户端初始化完成(PC-A / PC-B)"

# ------------------------------------------------------------
section "19.1 基础同步"
# ------------------------------------------------------------

# 19.1.1 A 新建文件,B 可见
write_file "$PC_A/hello.txt" "hello from A"
settle; syncA; syncB
assert_file_content 19.1.1 "$PC_B/hello.txt" "hello from A" "A 新建文件,B 同步可见"

# 19.1.2 A 修改文件,B 可见
write_file "$PC_A/hello.txt" "hello v2 from A"
settle; syncA; syncB
assert_file_content 19.1.2 "$PC_B/hello.txt" "hello v2 from A" "A 修改文件,B 同步可见"

# 19.1.3 A 删除文件,B 同步删除
# B 侧 hello.txt 刚被上一步 syncB 下载,mtime 在稳定窗口内会被冻结(DESIGN §2 步骤 4:
# 冻结路径不执行删除),与 19.2.2 一致需先 settle 让其越过 fileStableDelaySeconds。
rm -f "$PC_A/hello.txt"
syncA; settle; syncB
assert_absent 19.1.3 "$PC_B/hello.txt" "A 删除文件,B 同步删除"

# 19.1.4 目录 + 子文件完整结构
write_file "$PC_A/docs/sub/notes.txt" "notes in subdir"
write_file "$PC_A/docs/readme.md" "readme in docs"
settle; syncA; syncB
assert_file_content 19.1.4 "$PC_B/docs/sub/notes.txt" "notes in subdir" "子目录文件同步到 B"
assert_file_content 19.1.4 "$PC_B/docs/readme.md" "readme in docs" "目录结构完整同步到 B"

# ------------------------------------------------------------
section "19.2 冲突处理"
# ------------------------------------------------------------

# 19.2.1 双方修改同一文件不同内容 → 冲突副本,两份内容都不丢
write_file "$PC_A/conflict.txt" "conflict base"
settle; syncA; syncB
write_file "$PC_A/conflict.txt" "A version of conflict"
write_file "$PC_B/conflict.txt" "B version of conflict"
settle; syncA; syncB
assert_file_content 19.2.1 "$PC_B/conflict.txt" "A version of conflict" "冲突原路径为远端(A)内容"
assert_content_somewhere 19.2.1 "$PC_B" "B version of conflict" "B 的内容保存于冲突副本"
copyfile=$(find "$PC_B" \( -name .sync -prune \) -o -type f -name "conflict (conflict from PC-B*" -print 2>/dev/null | head -n 1)
if [ -n "$copyfile" ]; then
  pass 19.2.1 "冲突副本命名符合模板: $(basename "$copyfile")"
else
  fail 19.2.1 "未找到符合命名模板的冲突副本(conflict (conflict from PC-B...).txt)"
fi

# 19.2.4(其一)冲突副本随后同步到对端
syncA
assert_content_somewhere 19.2.4 "$PC_A" "B version of conflict" "修改冲突副本同步回 A"

# 19.2.2 A 删除,B 离线修改(不 sync 即离线),恢复后修改内容不丢
write_file "$PC_A/offline-edit.txt" "offline base"
settle; syncA; syncB
write_file "$PC_B/offline-edit.txt" "B offline edit"   # B 离线修改,先不 sync
rm -f "$PC_A/offline-edit.txt"
syncA                                                   # A 的删除已推送
settle; syncB                                           # B 恢复同步
assert_content_somewhere 19.2.2 "$PC_B" "B offline edit" "B 离线修改内容未丢失(冲突副本)"
assert_absent 19.2.2 "$PC_B/offline-edit.txt" "原路径接受删除(本地内容已改名为冲突副本)"
syncA
assert_content_somewhere 19.2.2 "$PC_A" "B offline edit" "B 的修改内容最终同步到 A"

# 19.2.3 双方新建同路径不同内容 → 路径冲突副本
write_file "$PC_A/newsame.txt" "created on A"
write_file "$PC_B/newsame.txt" "created on B"
settle; syncA; syncB
assert_file_content 19.2.3 "$PC_B/newsame.txt" "created on A" "同路径新建:原路径为远端(A)内容"
assert_content_somewhere 19.2.3 "$PC_B" "created on B" "B 的新建内容保存为路径冲突副本"

# 19.2.4(其二)路径冲突副本继续同步到对端
syncA
assert_content_somewhere 19.2.4 "$PC_A" "created on B" "路径冲突副本同步回 A"

# ------------------------------------------------------------
section "19.3 历史压缩"
# ------------------------------------------------------------

# 制造历史垃圾:同一大文件推送多个版本(压缩 + GC 后旧 blob 不可达可修剪)
i=1
while [ "$i" -le 3 ]; do
  { head -c 262144 /dev/urandom; echo "big version $i"; } > "$PC_A/big.bin"
  settle; syncA
  i=$((i + 1))
done
syncB

# 19.3.4 前置:压缩发生时 PC-B 有未同步的本地新文件
write_file "$PC_B/unsynced-local.txt" "survives compression on B"

head_before=$(remote_head)
tree_before=$(remote_tree_hash)
server_compress
compress_rc=$?
head_after=$(remote_head)
tree_after=$(remote_tree_hash)

# 19.3.1 压缩后 current 树与压缩前完全一致(且 head 确实被重写)
if [ "$compress_rc" -ne 0 ]; then
  fail 19.3.1 "compress.sh 执行失败 rc=$compress_rc(见 $LOG_DIR/compress.log)"
elif [ -z "$tree_before" ] || [ -z "$tree_after" ]; then
  fail 19.3.1 "无法读取压缩前后的远端树(before=$tree_before after=$tree_after)"
elif [ "$tree_before" = "$tree_after" ] && [ "$head_before" != "$head_after" ]; then
  pass 19.3.1 "压缩后树一致($tree_before)且 head 已重写($head_before -> $head_after)"
else
  fail 19.3.1 "tree: $tree_before -> $tree_after;head: $head_before -> $head_after"
fi

# 19.3.2 客户端识别历史压缩(日志含识别记录)
syncA
if grep -qi "compress" "$LAST_SYNC_LOG" 2>/dev/null \
   || grep -qsi "compress" "$PC_A"/.sync/logs/*.log 2>/dev/null; then
  pass 19.3.2 "PC-A 日志含历史压缩识别记录"
else
  fail 19.3.2 "PC-A 输出与 .sync/logs 中均未找到压缩识别记录(grep -i compress)"
fi

# 19.3.4 压缩期间 B 的未同步本地文件不丢,且最终到达 A
settle; syncB
assert_file_content 19.3.4 "$PC_B/unsynced-local.txt" "survives compression on B" "压缩后 B 的未同步文件仍在 B"
syncA
assert_file_content 19.3.4 "$PC_A/unsynced-local.txt" "survives compression on B" "B 的未同步文件最终到达 A"

# 19.3.3 压缩后仍能继续正常同步
write_file "$PC_A/post-compress.txt" "created after compression"
settle; syncA; syncB
assert_file_content 19.3.3 "$PC_B/post-compress.txt" "created after compression" "压缩后 A→B 同步仍正常"

# 19.3.5 GC 后仓库体积下降或松散对象减少
size_before=$(objects_size_kb)
count_before=$(loose_object_count)
server_gc
gc_rc=$?
size_after=$(objects_size_kb)
count_after=$(loose_object_count)
echo "    objects 体积: ${size_before:-?}KB -> ${size_after:-?}KB;松散对象: ${count_before:-?} -> ${count_after:-?}"
if [ "$gc_rc" -ne 0 ]; then
  fail 19.3.5 "gc.sh 执行失败 rc=$gc_rc(见 $LOG_DIR/gc.log)"
elif [ -z "$size_before" ] || [ -z "$size_after" ] || [ -z "$count_before" ] || [ -z "$count_after" ]; then
  fail 19.3.5 "无法读取 objects 统计"
elif [ "$size_after" -lt "$size_before" ] || [ "$count_after" -lt "$count_before" ]; then
  pass 19.3.5 "GC 后体积下降或松散对象减少"
else
  fail 19.3.5 "体积与松散对象数均未下降"
fi

# ------------------------------------------------------------
section "19.4 安全性"
# ------------------------------------------------------------

# 19.4.2 / 19.4.3 构造 push 竞争:A、B 各有新文件且修改同一文件,先 syncA 再 syncB
write_file "$PC_A/common.txt" "common base"
settle; syncA; syncB
write_file "$PC_A/race-a.txt" "race file from A"
write_file "$PC_A/common.txt" "A common edit"
write_file "$PC_B/race-b.txt" "race file from B"
write_file "$PC_B/common.txt" "B common edit"
settle
syncA; syncB; syncA; syncB

assert_file_content 19.4.2 "$PC_A/race-a.txt" "race file from A" "push 竞争后 A 的新文件未丢(A 侧)"
assert_file_content 19.4.2 "$PC_B/race-a.txt" "race file from A" "A 的新文件到达 B"
assert_file_content 19.4.2 "$PC_B/race-b.txt" "race file from B" "push 竞争后 B 的新文件未丢(B 侧)"
assert_file_content 19.4.2 "$PC_A/race-b.txt" "race file from B" "B 的新文件到达 A"

assert_content_somewhere 19.4.3 "$PC_A" "A common edit" "merge 后 A 的修改内容未被覆盖丢失"
assert_content_somewhere 19.4.3 "$PC_A" "B common edit" "B 的修改内容在 A 侧可见"
assert_content_somewhere 19.4.3 "$PC_B" "B common edit" "merge 后 B 的修改内容未被覆盖丢失"
assert_content_somewhere 19.4.3 "$PC_B" "A common edit" "A 的修改内容在 B 侧可见"

# 19.4.4 服务端 current 树不含 .sync
names=$(remote_ls_names)
if [ -z "$names" ]; then
  fail 19.4.4 "无法读取远端 current 树(remote_ls_names 为空)"
elif printf '%s\n' "$names" | grep -Eq '(^|/)\.sync(/|$)'; then
  fail 19.4.4 "远端 current 树包含 .sync 路径:$(printf '%s\n' "$names" | grep -E '(^|/)\.sync(/|$)' | head -n 3)"
else
  pass 19.4.4 "远端 current 树不含 .sync"
fi

# ------------------------------------------------------------
section "15. 维护锁(需求 §15:维护窗口内 push 必须被拒,数据无损)"
# ------------------------------------------------------------

# [15.1] maintenance.lock 存在时 pre-receive 拒绝全部 push;删锁后恢复。
maintenance_lock_create() {
  if [ "$MODE" = docker ]; then
    server_exec touch /srv/git/maintenance.lock
  else
    touch "$(dirname "$SERVER_REPO")/maintenance.lock"
  fi
}

maintenance_lock_remove() {
  if [ "$MODE" = docker ]; then
    server_exec rm -f /srv/git/maintenance.lock
  else
    rm -f "$(dirname "$SERVER_REPO")/maintenance.lock"
  fi
}

if maintenance_lock_create; then
  write_file "$PC_A/during-maintenance.txt" "written during maintenance window"
  settle
  syncA
  sync_rc=$?

  # push 必须失败(退出码非 0 或输出含 error)
  if [ "$sync_rc" -ne 0 ] || grep -qi "error" "$LAST_SYNC_LOG" 2>/dev/null; then
    pass 15.1 "维护锁存在时 sync 报错(rc=$sync_rc)"
  else
    fail 15.1 "维护锁存在时 sync 竟然成功(rc=$sync_rc)"
  fi

  # 远端树不得包含新文件
  names=$(remote_ls_names)
  if printf '%s\n' "$names" | grep -qx "during-maintenance.txt"; then
    fail 15.1 "维护锁存在时新文件仍被推到远端"
  else
    pass 15.1 "维护锁存在时远端树不含新文件"
  fi

  # 本地文件必须完好无损
  assert_file_content 15.1 "$PC_A/during-maintenance.txt" \
    "written during maintenance window" "维护锁拒绝期间本地文件完好"

  maintenance_lock_remove || fail 15.1 "无法删除 maintenance.lock"
  syncA
  if [ $? -eq 0 ]; then
    pass 15.1 "删除维护锁后 sync 恢复成功"
  else
    fail 15.1 "删除维护锁后 sync 仍失败"
  fi
  names=$(remote_ls_names)
  if printf '%s\n' "$names" | grep -qx "during-maintenance.txt"; then
    pass 15.1 "删除维护锁后文件到达远端"
  else
    fail 15.1 "删除维护锁后文件未到达远端"
  fi
  syncB
  assert_file_content 15.1 "$PC_B/during-maintenance.txt" \
    "written during maintenance window" "删除维护锁后文件同步到 B"
else
  fail 15.1 "无法创建 maintenance.lock"
fi

# ------------------------------------------------------------
section "汇总"
# ------------------------------------------------------------
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "失败条目:$FAILED_IDS"
  exit 1
fi
echo "全部断言通过。"
exit 0
