#!/usr/bin/env bash
#
# release.sh — 发布触发脚本。更新版本号 → 打 tag → 推送,GitHub Actions 自动
# 构建 macOS .dmg / Windows 安装器 / 服务端镜像并发布到 Release 与 ghcr。
#
# 用法:  scripts/release.sh <版本号>      例如  scripts/release.sh 1.0.1
#
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "用法: $0 <版本号>   例如  $0 1.0.1"; exit 1; }
VERSION="${VERSION#v}"                       # 容忍带前缀 v1.0.1
TAG="v$VERSION"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "版本号需形如 X.Y.Z(收到: $VERSION)"; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "当前目录不是 git 仓库,请先 git init 并设置 origin 远端。"; exit 1; }

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag $TAG 已存在,请换一个版本号。"; exit 1
fi

# 同步桌面应用版本号(build 号取提交数,保证单调递增的整数)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP_PUBSPEC="client/app/pubspec.yaml"
sed -i.bak -E "s/^version:.*/version: $VERSION+$BUILD/" "$APP_PUBSPEC"
rm -f "$APP_PUBSPEC.bak"
echo "已设置 $APP_PUBSPEC -> version: $VERSION+$BUILD"

git add -A
git commit -m "release $TAG" || echo "(无改动可提交,继续打 tag)"
git tag -a "$TAG" -m "Shared Sync $TAG"

git push origin HEAD
git push origin "$TAG"

echo
echo "✅ 已推送 $TAG。GitHub Actions 正在构建并发布安装包。"
echo "   进度: https://github.com/aceaura/shared-sync/actions"
echo "   产物: https://github.com/aceaura/shared-sync/releases/tag/$TAG"
