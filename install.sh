#!/usr/bin/env bash
# ============================================================
# install.sh — FLYTOex Network 在线安装引导脚本 v2
#
# 重构改动：
#   - 下载后验证关键文件存在性（原有）
#   - 新增：下载完成后对 flyto.sh 做 bash -n 语法检查
#   - 新增：自动安装 dialog 依赖
#   - 新增：显示下载来源和版本信息
#   - REPO_REF 支持通过环境变量覆盖（便于测试分支）
# ============================================================
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-panwudi}"
REPO_NAME="${REPO_NAME:-flyto-network}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${FLYTO_INSTALL_DIR:-/opt/flyto-network}"
ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_REF}"

G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; N='\033[0m'
info()  { echo -e "${C}[INSTALL]${N} $*"; }
ok()    { echo -e "${G}[INSTALL]${N} $*"; }
warn()  { echo -e "${Y}[INSTALL]${N} $*"; }
error() { echo -e "${R}[INSTALL]${N} $*" >&2; }

TMP_DIR=""
cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

check_root() {
  [[ "${EUID:-0}" -eq 0 ]] || { error "请使用 root 运行，例如：curl ... | sudo bash"; exit 1; }
}

check_deps() {
  local missing=()
  for cmd in curl tar bash; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    error "缺少依赖：${missing[*]}"
    error "请先安装后重试"
    exit 1
  fi
}

install_dialog() {
  command -v dialog >/dev/null 2>&1 && return 0
  info "尝试自动安装 dialog（TUI 交互库）..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y dialog >/dev/null 2>&1 && \
      ok "dialog 安装成功" && return 0
  elif command -v yum >/dev/null 2>&1; then
    yum install -y dialog >/dev/null 2>&1 && ok "dialog 安装成功" && return 0
  fi
  warn "dialog 安装失败，将使用纯文本模式（功能不受影响）"
}

download_repo() {
  TMP_DIR="$(mktemp -d)"
  local archive="${TMP_DIR}/repo.tar.gz"
  local src_dir="${TMP_DIR}/src"

  info "下载仓库：${REPO_OWNER}/${REPO_NAME}@${REPO_REF}"
  info "来源：${ARCHIVE_URL}"
  curl -fL --progress-bar "${ARCHIVE_URL}" -o "${archive}"

  # 基本完整性检查：tar 能正常列出文件
  if ! tar -tzf "${archive}" >/dev/null 2>&1; then
    error "下载文件损坏（tar 无法读取），请重试"
    exit 1
  fi

  mkdir -p "${src_dir}"
  tar -xzf "${archive}" -C "${src_dir}" --strip-components=1

  # 检查关键文件存在
  local required_files=(
    flyto.sh
    modules/hk-setup.sh
    modules/warp.sh
    tools/gen-secrets.sh
    secrets.enc
    lib/ui.sh
    lib/validate.sh
    lib/progress.sh
    lib/error.sh
  )
  local missing_files=()
  for f in "${required_files[@]}"; do
    [[ -e "${src_dir}/${f}" ]] || missing_files+=("${f}")
  done
  if [[ "${#missing_files[@]}" -gt 0 ]]; then
    error "下载的压缩包缺少以下关键文件："
    for f in "${missing_files[@]}"; do error "  - ${f}"; done
    exit 1
  fi

  # 语法检查核心脚本（逐个检查，原 check.sh 的 bug 在这里修复）
  info "检查脚本语法..."
  local syntax_ok=1
  for f in flyto.sh modules/hk-setup.sh modules/warp.sh tools/gen-secrets.sh \
            lib/ui.sh lib/validate.sh lib/progress.sh lib/error.sh; do
    if bash -n "${src_dir}/${f}" 2>/dev/null; then
      : # ok
    else
      error "语法错误：${f}"
      bash -n "${src_dir}/${f}" 2>&1 | head -5 >&2 || true
      syntax_ok=0
    fi
  done
  [[ "${syntax_ok}" -eq 1 ]] || { error "语法检查未通过，请检查仓库代码"; exit 1; }
  ok "语法检查通过"

  # 部署到目标目录
  mkdir -p "${INSTALL_DIR}"
  cp -a "${src_dir}/." "${INSTALL_DIR}/"

  # 设置可执行权限
  local exec_files=(
    flyto.sh install.sh
    modules/hk-setup.sh modules/warp.sh
    tools/gen-secrets.sh
    scripts/check.sh
  )
  for f in "${exec_files[@]}"; do
    [[ -f "${INSTALL_DIR}/${f}" ]] && chmod +x "${INSTALL_DIR}/${f}" || true
  done

  ok "文件已安装至 ${INSTALL_DIR}"
}

main() {
  echo
  echo -e "${C}  FLYTOex Network — 安装程序${N}"
  echo -e "${C}  www.flytoex.com${N}"
  echo

  check_root
  check_deps
  install_dialog
  download_repo

  if [[ "${1:-}" == "--download-only" ]]; then
    ok "仅下载完成，未启动 flyto.sh"
    ok "进入目录后运行：cd ${INSTALL_DIR} && bash flyto.sh"
    exit 0
  fi

  info "安装完成，启动主程序..."
  cd "${INSTALL_DIR}"
  exec bash "./flyto.sh" "$@"
}

main "$@"
