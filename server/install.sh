#!/usr/bin/env bash
#
# install.sh — shared-sync 服务端一键部署。
# 拉取 CI 构建好的镜像(ghcr.io/aceaura/shared-sync-server)并启动容器。
#
# 用法(任选其一):
#   1) 一行远程安装:
#      curl -fsSL https://raw.githubusercontent.com/aceaura/shared-sync/main/server/install.sh | bash
#   2) 本地执行:
#      bash server/install.sh [安装目录]    # 默认 ./shared-sync-server
#
# 可选环境变量(启用 HTTP Basic Auth,留空则匿名,仅建议可信局域网):
#   GIT_AUTH_USER=xxx GIT_AUTH_PASSWORD=yyy bash server/install.sh
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/aceaura/shared-sync/main"
INSTALL_DIR="${1:-./shared-sync-server}"
COMPOSE_FILE="docker-compose.prod.yml"

err() { echo "错误: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || err "未找到 docker,请先安装 Docker。"
docker compose version >/dev/null 2>&1 || err "未找到 docker compose(v2),请升级 Docker。"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 取得生产 compose 文件:本地仓库内执行时直接复用,否则从 GitHub 下载。
if [ -f "$(dirname "$0")/$COMPOSE_FILE" ] 2>/dev/null; then
  cp "$(dirname "$0")/$COMPOSE_FILE" "./$COMPOSE_FILE"
else
  echo "下载 $COMPOSE_FILE …"
  curl -fsSL "$REPO_RAW/server/$COMPOSE_FILE" -o "./$COMPOSE_FILE" \
    || err "下载 compose 文件失败。"
fi

# 可选认证写入 .env(docker compose 自动读取)
if [ -n "${GIT_AUTH_USER:-}" ] && [ -n "${GIT_AUTH_PASSWORD:-}" ]; then
  cat > .env <<EOF
GIT_AUTH_USER=$GIT_AUTH_USER
GIT_AUTH_PASSWORD=$GIT_AUTH_PASSWORD
EOF
  echo "已启用 HTTP Basic Auth(凭据写入 $INSTALL_DIR/.env)。"
fi

echo "拉取镜像并启动 …"
docker compose -f "$COMPOSE_FILE" pull
docker compose -f "$COMPOSE_FILE" up -d

echo
echo "✅ 服务端已启动。"
echo "   仓库地址: http://<本机IP>:8418/shared.git"
echo "   查看状态: (cd $INSTALL_DIR && docker compose -f $COMPOSE_FILE ps)"
echo "   查看日志: (cd $INSTALL_DIR && docker compose -f $COMPOSE_FILE logs -f)"
echo "   停止服务: (cd $INSTALL_DIR && docker compose -f $COMPOSE_FILE down)"
echo "   历史压缩: docker compose -f $COMPOSE_FILE exec shared-sync-server compress.sh"
