#!/usr/bin/env bash
# ============================================================
# install.sh — FLYTOex Network 在线安装引导脚本
# 支持 curl | bash，无需 git
# ============================================================
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-panwudi}"
REPO_NAME="${REPO_NAME:-flyto-network}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${FLYTO_INSTALL_DIR:-/opt/flyto-network}"
ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_REF}"

G='\033[1;32m'
R='\033[1;31m'
Y='\033[1;33m'
C='\033[1;36m'
N='\033[0m'

info()  { echo -e "${C}[INSTALL]${N} $*"; }
ok()    { echo -e "${G}[INSTALL]${N} $*"; }
warn()  { echo -e "${Y}[INSTALL]${N} $*"; }
error() { echo -e "${R}[INSTALL]${N} $*" >&2; }

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

check_root() {
  [[ ${EUID:-0} -eq 0 ]] || { error "请使用 root 运行，例如: curl ... | sudo bash"; exit 1; }
}

check_deps() {
  local missing=()
  for cmd in curl tar; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "缺少依赖: ${missing[*]}"
    error "请先安装后重试"
    exit 1
  fi
}

download_repo() {
  TMP_DIR="$(mktemp -d)"
  local archive="${TMP_DIR}/repo.tar.gz"
  local src_dir="${TMP_DIR}/src"

  info "下载仓库压缩包: ${REPO_OWNER}/${REPO_NAME}@${REPO_REF}"
  curl -fsSL "${ARCHIVE_URL}" -o "${archive}"

  mkdir -p "${src_dir}"
  tar -xzf "${archive}" -C "${src_dir}" --strip-components=1

  for path in flyto.sh modules/hk-setup.sh modules/warp.sh tools/gen-secrets.sh secrets.enc; do
    [[ -e "${src_dir}/${path}" ]] || { error "缺少关键文件: ${path}"; exit 1; }
  done

  mkdir -p "${INSTALL_DIR}"
  cp -a "${src_dir}/." "${INSTALL_DIR}/"

  chmod +x \
    "${INSTALL_DIR}/install.sh" \
    "${INSTALL_DIR}/flyto.sh" \
    "${INSTALL_DIR}/modules/hk-setup.sh" \
    "${INSTALL_DIR}/modules/warp.sh" \
    "${INSTALL_DIR}/tools/gen-secrets.sh" \
    "${INSTALL_DIR}/scripts/check.sh" 2>/dev/null || true

  ok "文件已安装到 ${INSTALL_DIR}"
}

main() {
  check_root
  check_deps
  download_repo

  if [[ "${1:-}" == "--download-only" ]]; then
    ok "仅下载完成，未执行 flyto.sh"
    exit 0
  fi

  info "安装完成。"

  # 只有在真正交互终端中才尝试自动进入菜单，避免 curl | bash 场景下静默退出。
  if [[ -t 0 && -t 1 && -t 2 && -r /dev/tty && -w /dev/tty ]]; then
    info "检测到交互终端，正在启动 FLYTOex Network..."
    if bash "${INSTALL_DIR}/flyto.sh" "$@" </dev/tty >/dev/tty 2>&1; then
      exit 0
    fi
    warn "自动启动未成功，请手动执行: bash ${INSTALL_DIR}/flyto.sh"
    exit 0
  fi

  warn "当前会话不是交互终端，已完成安装但不会自动进入菜单。"
  warn "下一步请执行: bash ${INSTALL_DIR}/flyto.sh"
}

main "$@"
