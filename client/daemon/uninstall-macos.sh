#!/usr/bin/env bash
#
# uninstall-macos.sh — 卸载由 install-macos.sh 注册的 launchd LaunchAgent。
#
# 用法: ./uninstall-macos.sh <共享目录绝对路径>
#
# 幂等:目录/plist 不存在也正常退出(0)。
# label 生成规则必须与 install-macos.sh 完全一致。
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "用法: $0 <共享目录绝对路径>" >&2
  echo "  例: $0 \"$HOME/SharedWork\"" >&2
  exit 2
fi

RAW_DIR="$1"

# 目录可能已被删除:尽量规范化,删不掉就用原始字符串算 label。
if [[ -d "$RAW_DIR" ]]; then
  SHARED_DIR="$(cd "$RAW_DIR" && pwd -P)"
else
  # 去掉末尾斜杠,与 pwd -P 的无尾斜杠形式尽量对齐
  SHARED_DIR="${RAW_DIR%/}"
fi

# ---- 与 install-macos.sh 相同的 label 生成规则 ---------------------------
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

PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

# ---- 卸载 + 删除 plist(幂等)--------------------------------------------
if [[ -f "$PLIST_PATH" ]]; then
  launchctl unload -w "$PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  echo "✅ 已卸载并删除: $PLIST_PATH (Label: $LABEL)"
else
  # plist 不在,但守护进程可能仍以该 label 在册,尽力卸载一次。
  launchctl remove "$LABEL" >/dev/null 2>&1 || true
  echo "ℹ️  未找到 plist($PLIST_PATH),无需卸载(Label: $LABEL)。"
fi

exit 0
