#!/usr/bin/env bash
# =============================================================================
# lib-common.sh —— v2/install/ 三角色安装器共享函数库(被 source,自身不可执行)
#
# 提供:
#   * 日志 / 错误 helper
#   * OS / arch 探测(linux|darwin × amd64|arm64)
#   * 服务管理器抽象(systemd on Linux / launchd on macOS):
#       svc_install / svc_enable / svc_disable / svc_status / svc_uninstall
#   * connd 二进制就位:acquire_connd()
#       —— Release 优先(下载 connd-<os>-<arch>),回退本地 go build。
#   * frpc 二进制就位:acquire_frpc()(官方 release)。
#   * nebula 二进制就位:acquire_nebula()(官方 release)。
#
# 设计纪律:只读/幂等;不触碰 v1 业务代码;私钥/密钥不落库。
# =============================================================================

# 防重复 source。
[[ -n "${_SS_LIB_COMMON_LOADED:-}" ]] && return 0
_SS_LIB_COMMON_LOADED=1

# ---- 版本固定(与现有脚本一致)---------------------------------------------
NEBULA_VER="${NEBULA_VER:-1.10.3}"
FRP_VERSION="${FRP_VERSION:-0.69.1}"
# connd Release 资产命名:connd-<os>-<arch>(由 release.yml 的 connd job 产出)。
# 仓库 owner/repo 用于拼 GitHub Release 下载地址。
GH_REPO="${GH_REPO:-aceaura/shared-sync}"
# 允许显式指定一个本地 connd 二进制(跳过下载/编译);最高优先级。
CONND_BIN_OVERRIDE="${CONND_BIN_OVERRIDE:-}"
# connd 期望版本(对应 Release tag,如 v2.0.0);留空=latest。
CONND_RELEASE_TAG="${CONND_RELEASE_TAG:-}"

# ---- 日志 -------------------------------------------------------------------
_c_blue=$'\033[34m'; _c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_off=$'\033[0m'
log()  { echo "${_c_blue}>>${_c_off} $*"; }
ok()   { echo "${_c_green}OK${_c_off} $*"; }
warn() { echo "${_c_yellow}WARN${_c_off} $*" >&2; }
die()  { echo "${_c_red}ERROR${_c_off} $*" >&2; exit 1; }

# 用 sudo 若非 root(Linux 装服务/写 /etc 需要)。
SUDO=""
need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    command -v sudo >/dev/null 2>&1 || die "需要 root 或 sudo 来安装系统服务"
    SUDO="sudo"
  fi
}

# ---- OS / arch 探测 ---------------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    Linux)  echo linux ;;
    Darwin) echo darwin ;;
    *) die "不支持的 OS: $(uname -s)(仅 linux/darwin;Windows 见 README NSSM 章节)" ;;
  esac
}
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

# ---- HTTP 下载(curl 优先,回退 wget)--------------------------------------
fetch() { # fetch <url> <out>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -m 180 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 180 -O "$out" "$url"
  else
    die "需要 curl 或 wget 才能下载 $url"
  fi
}

# ---- connd 就位:Release 优先,回退本地 go build ----------------------------
# 产出可执行的 connd 到 $1(目标绝对路径)。返回 0/非 0。
acquire_connd() { # acquire_connd <dest_path>
  local dest="$1" os arch asset url tag
  os="$(detect_os)"; arch="$(detect_arch)"

  # 0) 显式 override 最高优先。
  if [[ -n "$CONND_BIN_OVERRIDE" ]]; then
    [[ -x "$CONND_BIN_OVERRIDE" ]] || die "CONND_BIN_OVERRIDE=$CONND_BIN_OVERRIDE 不可执行"
    log "connd:用 CONND_BIN_OVERRIDE=$CONND_BIN_OVERRIDE"
    install -m 0755 "$CONND_BIN_OVERRIDE" "$dest"; return 0
  fi

  # 1) Release 资产 connd-<os>-<arch>。
  asset="connd-${os}-${arch}"
  if [[ -n "$CONND_RELEASE_TAG" ]]; then
    tag="$CONND_RELEASE_TAG"
    url="https://github.com/${GH_REPO}/releases/download/${tag}/${asset}"
  else
    url="https://github.com/${GH_REPO}/releases/latest/download/${asset}"
  fi
  log "connd:尝试从 Release 下载 $asset"
  if fetch "$url" "$dest.tmp" 2>/dev/null && [[ -s "$dest.tmp" ]]; then
    chmod 0755 "$dest.tmp"; mv "$dest.tmp" "$dest"
    ok "connd 来自 Release($asset)"
    return 0
  fi
  rm -f "$dest.tmp"
  warn "Release 下载失败($url),回退本地 go build"

  # 2) 本地 go build(开发机/未发版时)。
  acquire_connd_local "$dest"
}

# 本地编译 connd(目标 OS/arch 与当前机相同;若交叉编译需自行设 GOOS/GOARCH)。
acquire_connd_local() { # acquire_connd_local <dest_path>
  local dest="$1" conndsrc
  command -v go >/dev/null 2>&1 || die "未找到 go;无法本地编译 connd(Release 也不可达)"
  # lib-common.sh 在 v2/install/,connd 源码在 ../connd。
  conndsrc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../connd" && pwd)"
  [[ -d "$conndsrc/cmd/connd" ]] || die "找不到 connd 源码:$conndsrc/cmd/connd"
  log "connd:本地编译 $conndsrc -> $dest"
  ( cd "$conndsrc" && CGO_ENABLED=0 go build -o "$dest" ./cmd/connd )
  chmod 0755 "$dest"
  ok "connd 本地编译完成"
}

# ---- frpc 就位:官方 release --------------------------------------------------
acquire_frpc() { # acquire_frpc <dest_path>
  local dest="$1" os arch tgt tmp
  os="$(detect_os)"; arch="$(detect_arch)"
  # frp release 命名:frp_<ver>_<os>_<arch>.tar.gz(os=linux/darwin)。
  tgt="frp_${FRP_VERSION}_${os}_${arch}"
  tmp="$(mktemp -d)"
  log "frpc:下载 ${tgt}.tar.gz"
  fetch "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${tgt}.tar.gz" "$tmp/frp.tgz" \
    || die "frpc 下载失败"
  tar xzf "$tmp/frp.tgz" -C "$tmp"
  install -m 0755 "$tmp/${tgt}/frpc" "$dest"
  rm -rf "$tmp"
  ok "frpc 就位($FRP_VERSION)"
}

# ---- nebula 就位:官方 release ------------------------------------------------
# 注意:nebula 的 macOS 发布是【通用二进制 zip】nebula-darwin.zip(不分 arch);
#       Linux 才是 nebula-linux-<arch>.tar.gz。
acquire_nebula() { # acquire_nebula <dest_path>
  local dest="$1" os arch tmp
  os="$(detect_os)"; arch="$(detect_arch)"
  tmp="$(mktemp -d)"
  if [[ "$os" == darwin ]]; then
    log "nebula:下载 v${NEBULA_VER} darwin(universal zip)"
    fetch "https://github.com/slackhq/nebula/releases/download/v${NEBULA_VER}/nebula-darwin.zip" "$tmp/nebula.zip" \
      || die "nebula 下载失败"
    command -v unzip >/dev/null 2>&1 || die "需要 unzip 解压 nebula-darwin.zip"
    unzip -q -o "$tmp/nebula.zip" -d "$tmp"
  else
    log "nebula:下载 v${NEBULA_VER} ${os}/${arch}"
    fetch "https://github.com/slackhq/nebula/releases/download/v${NEBULA_VER}/nebula-${os}-${arch}.tar.gz" "$tmp/nebula.tgz" \
      || die "nebula 下载失败"
    tar xzf "$tmp/nebula.tgz" -C "$tmp"
  fi
  install -m 0755 "$tmp/nebula" "$dest"
  rm -rf "$tmp"
  ok "nebula 就位($NEBULA_VER)"
}

# =============================================================================
# 服务管理器抽象
#   SVC_KIND = systemd(Linux)| launchd(macOS)
#   单元名约定:shared-sync-<role>(systemd)/ com.shared-sync.<role>(launchd)
# =============================================================================
detect_svc_kind() {
  case "$(detect_os)" in
    linux)
      command -v systemctl >/dev/null 2>&1 || die "Linux 需 systemd(systemctl);非 systemd 系统见 README"
      echo systemd ;;
    darwin) echo launchd ;;
  esac
}

# systemd 单元目录 / launchd plist 目录(系统级)。
SYSTEMD_DIR="/etc/systemd/system"
LAUNCHD_DIR="/Library/LaunchDaemons"

# svc_install <name> <unit_or_plist_src_file>
#   systemd: 安装到 /etc/systemd/system/<name>.service
#   launchd: 安装到 /Library/LaunchDaemons/<name>.plist
svc_install() {
  local name="$1" src="$2" kind; kind="$(detect_svc_kind)"
  if [[ "$kind" == systemd ]]; then
    $SUDO install -m 0644 "$src" "$SYSTEMD_DIR/${name}.service"
    $SUDO systemctl daemon-reload
  else
    $SUDO install -m 0644 "$src" "$LAUNCHD_DIR/${name}.plist"
    $SUDO chown root:wheel "$LAUNCHD_DIR/${name}.plist"
  fi
}

svc_enable() { # 安装并立即启动 + 开机自启
  local name="$1" kind; kind="$(detect_svc_kind)"
  if [[ "$kind" == systemd ]]; then
    $SUDO systemctl enable "$name" >/dev/null 2>&1 || true
    $SUDO systemctl restart "$name"
  else
    # bootstrap(若已加载先 bootout)然后 enable + kickstart。
    $SUDO launchctl bootout system "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
    $SUDO launchctl bootstrap system "$LAUNCHD_DIR/${name}.plist"
    $SUDO launchctl enable "system/${name}" >/dev/null 2>&1 || true
    $SUDO launchctl kickstart -k "system/${name}" >/dev/null 2>&1 || true
  fi
}

svc_disable() { # 停止 + 取消自启(保留单元文件)
  local name="$1" kind; kind="$(detect_svc_kind)"
  if [[ "$kind" == systemd ]]; then
    $SUDO systemctl disable --now "$name" >/dev/null 2>&1 || true
  else
    $SUDO launchctl bootout system "$LAUNCHD_DIR/${name}.plist" >/dev/null 2>&1 || true
    $SUDO launchctl disable "system/${name}" >/dev/null 2>&1 || true
  fi
}

svc_status() { # 打印服务状态(0=active)
  local name="$1" kind; kind="$(detect_svc_kind)"
  if [[ "$kind" == systemd ]]; then
    $SUDO systemctl is-active "$name" 2>/dev/null
  else
    if $SUDO launchctl print "system/${name}" >/dev/null 2>&1; then
      echo "active"; else echo "inactive"; fi
  fi
}

svc_uninstall() { # 停止 + 删单元
  local name="$1" kind; kind="$(detect_svc_kind)"
  svc_disable "$name"
  if [[ "$kind" == systemd ]]; then
    $SUDO rm -f "$SYSTEMD_DIR/${name}.service"
    $SUDO systemctl daemon-reload
  else
    $SUDO rm -f "$LAUNCHD_DIR/${name}.plist"
  fi
}

# render <src_tmpl> <dst> KEY=VAL [KEY=VAL ...]
#   把 __KEY__ 占位符替换为 VAL,写到 dst。
render() {
  local src="$1" dst="$2"; shift 2
  local content; content="$(cat "$src")"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # 用 bash 字符串替换避免 sed 分隔符冲突(路径含 /)。
    content="${content//__${k}__/$v}"
  done
  printf '%s\n' "$content" > "$dst"
}
