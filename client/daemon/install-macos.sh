#!/usr/bin/env bash
#
# install-macos.sh — 把 sync_cli watch 注册为 macOS launchd LaunchAgent,
# 实现无人值守的进程级保活(登录自启 + 崩溃/被 kill 自动拉起)。
#
# 用法:  ./install-macos.sh <共享目录绝对路径>
# 卸载:  ./uninstall-macos.sh <共享目录绝对路径>
#
# ┌──────────────────────────────────────────────────────────────────────┐
# │  ⚠️  安全警告:GUI 应用与本守护进程绝不能管理同一个共享目录!            │
# │  二者会争抢同一个 <dir>/.sync/lock 文件,后启动者会因拿不到锁而失败。   │
# │  • 桌面交互场景:用 GUI 应用,本脚本不要碰同一目录。                    │
# │  • 无人值守 / 纯后台机器(无人登录 GUI):才用本脚本。                   │
# └──────────────────────────────────────────────────────────────────────┘
set -euo pipefail

# ---- 参数校验 -------------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "用法: $0 <共享目录绝对路径>" >&2
  echo "  例: $0 \"$HOME/SharedWork\"" >&2
  exit 2
fi

RAW_DIR="$1"

# 解析为绝对、规范化路径(目录必须已存在)
if [[ ! -d "$RAW_DIR" ]]; then
  echo "错误: 共享目录不存在: $RAW_DIR" >&2
  exit 1
fi
SHARED_DIR="$(cd "$RAW_DIR" && pwd -P)"

# ---- 校验该目录已经 init(存在 .sync/config.json)------------------------
CONFIG_JSON="$SHARED_DIR/.sync/config.json"
if [[ ! -f "$CONFIG_JSON" ]]; then
  echo "错误: 该目录尚未初始化(缺少 $CONFIG_JSON)。" >&2
  echo "      请先运行:  sync_cli init --dir \"$SHARED_DIR\" --server <url> --client-id <id>" >&2
  exit 1
fi

# ---- 定位 sync_cli 可执行文件 --------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# 仓库布局: client/daemon/ 与 client/engine/ 同级
DEFAULT_BIN="$SCRIPT_DIR/../engine/build/sync_cli"

if [[ -x "$DEFAULT_BIN" ]]; then
  SYNC_CLI="$(cd "$(dirname "$DEFAULT_BIN")" && pwd -P)/$(basename "$DEFAULT_BIN")"
elif command -v sync_cli >/dev/null 2>&1; then
  SYNC_CLI="$(command -v sync_cli)"
else
  echo "错误: 未找到 sync_cli 可执行文件。" >&2
  echo "      期望位置: $DEFAULT_BIN" >&2
  echo "      请先编译:  cd \"$SCRIPT_DIR/../engine\" && dart compile exe bin/sync_cli.dart -o build/sync_cli" >&2
  exit 1
fi

# ---- 由共享目录生成稳定 label --------------------------------------------
# 规则: com.sharedsync.client.<slug>-<hash8>
#   slug : 目录名小写、非字母数字转 '-'、压缩连续 '-'、去首尾 '-'
#   hash8: 绝对路径 sha256 的前 8 位十六进制,保证不同目录(同名)不冲突,
#          且同一目录每次计算结果稳定。
# uninstall-macos.sh 必须用完全相同的规则反算 label。
slugify() {
  local s
  s="$(basename "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
  [[ -n "$s" ]] || s="dir"
  printf '%s' "$s"
}
path_hash8() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-8
}

SLUG="$(slugify "$SHARED_DIR")"
HASH8="$(path_hash8 "$SHARED_DIR")"
LABEL="com.sharedsync.client.${SLUG}-${HASH8}"

# ---- 路径准备 -------------------------------------------------------------
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$AGENTS_DIR/${LABEL}.plist"
LOG_DIR="$SHARED_DIR/.sync/logs"
STDOUT_LOG="$LOG_DIR/launchd.out.log"
STDERR_LOG="$LOG_DIR/launchd.err.log"
TEMPLATE="$SCRIPT_DIR/com.sharedsync.client.plist.template"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "错误: 找不到 plist 模板: $TEMPLATE" >&2
  exit 1
fi

mkdir -p "$AGENTS_DIR" "$LOG_DIR"

# ---- 渲染模板 -> plist ----------------------------------------------------
# 用 sed 逐占位符替换;先把含 '&' '/' 等特殊字符的值转义,避免 sed 误解。
sed_escape() { printf '%s' "$1" | sed -e 's/[&/\]/\\&/g'; }

sed \
  -e "s/__LABEL__/$(sed_escape "$LABEL")/g" \
  -e "s/__BIN__/$(sed_escape "$SYNC_CLI")/g" \
  -e "s/__DIR__/$(sed_escape "$SHARED_DIR")/g" \
  -e "s/__LOG__/$(sed_escape "$STDOUT_LOG")/g" \
  -e "s/__ERRLOG__/$(sed_escape "$STDERR_LOG")/g" \
  "$TEMPLATE" > "$PLIST_PATH"

# 合法性自检(plutil 是 macOS 自带)
if command -v plutil >/dev/null 2>&1; then
  if ! plutil -lint "$PLIST_PATH" >/dev/null; then
    echo "错误: 生成的 plist 不合法: $PLIST_PATH" >&2
    exit 1
  fi
fi

# ---- 重新加载 -------------------------------------------------------------
# 先卸载旧的(若存在,忽略错误),再以 -w 加载(写入 disabled=false)。
launchctl unload -w "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl load  -w "$PLIST_PATH"

# ---- 完成提示 -------------------------------------------------------------
cat <<EOF

✅ 已安装并启动 launchd 守护进程。
   Label   : $LABEL
   共享目录 : $SHARED_DIR
   可执行   : $SYNC_CLI
   plist    : $PLIST_PATH
   日志     : $STDOUT_LOG
              $STDERR_LOG

⚠️  互斥提醒:不要再用 GUI 应用打开同一个目录($SHARED_DIR),
   否则会和守护进程争抢 .sync/lock 导致其一启动失败。

查看状态: launchctl list | grep '$LABEL'
查看日志: tail -f "$STDOUT_LOG"
卸    载: "$SCRIPT_DIR/uninstall-macos.sh" "$SHARED_DIR"
EOF
