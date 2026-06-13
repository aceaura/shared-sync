#!/usr/bin/env bash
#
# make-dmg.sh — 把已构建的 macOS .app 打包成可拖拽安装的 .dmg(无外部依赖,纯 hdiutil)。
#
# 前置:先在 client/app 下 `flutter build macos --release`。
# 用法:bash installer/macos/make-dmg.sh
# 可选:APP_VERSION 覆盖版本号(默认读 client/app/pubspec.yaml)。
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
APP_DIR="$ROOT/client/app"
APP="$APP_DIR/build/macos/Build/Products/Release/shared_sync_app.app"

[ -d "$APP" ] || { echo "未找到 $APP — 请先在 client/app 下 flutter build macos --release"; exit 1; }

VERSION="${APP_VERSION:-$(grep '^version:' "$APP_DIR/pubspec.yaml" | head -1 | sed -E 's/version:[[:space:]]*//; s/\+.*//')}"
OUT_DIR="$APP_DIR/build/macos"
OUT="$OUT_DIR/shared-sync-macos-$VERSION.dmg"

rm -f "$OUT"

# 暂存目录:.app + 指向 /Applications 的软链,得到熟悉的「拖入 Applications」安装窗口。
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "Shared Sync" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT" >/dev/null

echo "✅ 已生成: $OUT"
