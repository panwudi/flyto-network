#!/usr/bin/env bash
# ============================================================
# flyto.sh — FLYTOex Network 运维工具集
# 香港中转节点部署 · WARP Google 送中
#
# 项目地址: https://github.com/panwudi/flyto-network
# 官网:     www.flytoex.com
# ============================================================
set -euo pipefail

FLYTO_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_FD=0
INPUT_DESC="/dev/stdin"
# Avoid set -e hard-exit when /dev/tty exists but is not attachable.
if exec 9</dev/tty 2>/dev/null; then
  INPUT_FD=9
  INPUT_DESC="/dev/tty"
fi

# ── 颜色 ────────────────────────────────────────────────────
BG_GREEN='\033[48;5;22m'   # 墨绿底色
W='\033[1;37m'              # 白字
O='\033[38;5;208m'          # 橙色
G='\033[1;32m'              # 绿色
R='\033[1;31m'              # 红色
Y='\033[1;33m'              # 黄色
C='\033[1;36m'              # 青色
D='\033[2;37m'              # 暗白
N='\033[0m'                 # 重置

info()    { echo -e "${C}[INFO]${N} $*"; }
success() { echo -e "${G}[OK]${N} $*"; }
warn()    { echo -e "${Y}[WARN]${N} $*"; }
error()   { echo -e "${R}[ERROR]${N} $*" >&2; }

prompt_read() {
  local __var_name="$1"
  local __prompt="$2"
  if ! IFS= read -r -u "${INPUT_FD}" -p "${__prompt}" "${__var_name}"; then
    error "未检测到可交互输入（${INPUT_DESC}）"
    error "请直接在可交互终端运行: bash ${SCRIPT_DIR}/flyto.sh"
    exit 1
  fi
}

prompt_read_secret() {
  local __var_name="$1"
  local __prompt="$2"
  if ! IFS= read -rs -u "${INPUT_FD}" -p "${__prompt}" "${__var_name}"; then
    error "未检测到可交互输入（${INPUT_DESC}）"
    error "请直接在可交互终端运行: bash ${SCRIPT_DIR}/flyto.sh"
    exit 1
  fi
}

# ── Banner ──────────────────────────────────────────────────
show_banner() {
  clear 2>/dev/null || true
  local PAD="${BG_GREEN}  ${N}"
  local BG="${BG_GREEN}"
  echo
  echo -e "${BG}$(printf '%0.s ' {1..64})${N}"
  echo -e "${PAD}${W}███████╗██╗  ██╗   ██╗████████╗  ${O}╔══════════╗${W}  ${BG}   ${N}"
  echo -e "${PAD}${W}██╔════╝██║  ╚██╗ ██╔╝╚══██╔══╝  ${O}╠══════════╬╗${W} ${BG}   ${N}"
  echo -e "${PAD}${W}█████╗  ██║   ╚████╔╝    ██║     ${O}║          ║ ${W} ${BG}   ${N}"
  echo -e "${PAD}${W}██╔══╝  ██║    ╚██╔╝     ██║     ${O}║          ║ ${W} ${BG}   ${N}"
  echo -e "${PAD}${W}██║     ███████╗██║      ██║     ${O}╚══════════╝ ${W} ${BG}   ${N}"
  echo -e "${PAD}${W}╚═╝     ╚══════╝╚═╝      ╚═╝                     ${W} ${BG}   ${N}"
  echo -e "${BG}$(printf '%0.s ' {1..64})${N}"
  echo
  echo -e "  ${O}▌${N} ${W}FLYTOex Network${N}  ${D}·${N}  v${FLYTO_VERSION}  ${D}·${N}  ${C}www.flytoex.com${N}"
  echo
}

# ── Root 检查 ────────────────────────────────────────────────
check_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    error "请使用 root 运行"
    exit 1
  fi
  return 0
}

# ============================================================
# 敏感配置管理
# 加密存储在 secrets.enc，首次运行时提示解密口令
# 解密结果缓存至 /etc/flyto/.secrets (600)
# ============================================================
SECRETS_CACHE="/etc/flyto/.secrets"
SECRETS_ENC="${SCRIPT_DIR}/secrets.enc"

load_secrets() {
  # 已有缓存直接读
  if [[ -f "${SECRETS_CACHE}" ]]; then
    # shellcheck disable=SC1090
    source "${SECRETS_CACHE}"
    return 0
  fi

  # 检查加密文件是否存在
  if [[ ! -f "${SECRETS_ENC}" ]]; then
    error "未找到 ${SECRETS_ENC}"
    error "请先运行 tools/gen-secrets.sh 生成加密配置"
    exit 1
  fi

  echo
  echo -e "  ${Y}首次运行需要解密配置文件${N}"
  local pass
  prompt_read_secret pass "  请输入解密口令: "
  echo

  mkdir -p /etc/flyto
  local tmp; tmp="$(mktemp)"
  if openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass "pass:${pass}" \
      -d -base64 \
      -in "${SECRETS_ENC}" \
      -out "${tmp}" 2>/dev/null; then
    mv "${tmp}" "${SECRETS_CACHE}"
    chmod 600 "${SECRETS_CACHE}"
    # shellcheck disable=SC1090
    source "${SECRETS_CACHE}"
    success "配置解密成功，已缓存至 ${SECRETS_CACHE}"
  else
    rm -f "${tmp}"
    error "口令错误或配置文件损坏"
    error "如需重置口令，请重新运行 tools/gen-secrets.sh"
    exit 1
  fi
}

# 清除缓存（重新输入口令）
clear_secrets_cache() {
  if [[ -f "${SECRETS_CACHE}" ]]; then
    rm -f "${SECRETS_CACHE}"
    success "已清除配置缓存，下次运行将重新提示口令"
  else
    info "无缓存需要清除"
  fi
}

# ============================================================
# 模块加载
# ============================================================
load_module() {
  local mod="${SCRIPT_DIR}/modules/$1"
  if [[ ! -f "${mod}" ]]; then
    error "模块 $1 未找到: ${mod}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${mod}"
}

# ============================================================
# WARP 子菜单
# ============================================================
menu_warp() {
  while true; do
    echo
    echo -e "  ${O}── WARP 管理 (Google Gemini 送中) ──${N}"
    echo
    echo -e "  ${G}1.${N} 安装 / 升级 WARP"
    echo -e "  ${G}2.${N} 查看 WARP 状态"
    echo -e "  ${G}3.${N} 8 层逐层诊断 (warp test)"
    echo -e "  ${G}4.${N} 重启 WARP"
    echo -e "  ${G}5.${N} 卸载 WARP"
    echo -e "  ${G}0.${N} 返回主菜单"
    echo
    prompt_read choice "  请输入选项 [0-5]: "
    case "${choice}" in
      1)
        load_module warp.sh
        warp_do_install
        ;;
      2)
        if command -v warp >/dev/null 2>&1; then
          warp status
        else
          warn "WARP 尚未安装"
        fi
        ;;
      3)
        if command -v warp >/dev/null 2>&1; then
          warp test
        else
          warn "WARP 尚未安装"
        fi
        ;;
      4)
        if command -v warp >/dev/null 2>&1; then
          warp restart
        else
          warn "WARP 尚未安装"
        fi
        ;;
      5)
        if command -v warp >/dev/null 2>&1; then
          warp uninstall
        else
          warn "WARP 尚未安装"
        fi
        ;;
      0) return ;;
      *) error "无效选项" ;;
    esac
  done
}

# ============================================================
# 主菜单
# ============================================================
show_main_menu() {
  while true; do
    show_banner
    echo -e "  ${W}请选择操作:${N}"
    echo
    echo -e "  ${G}1.${N} 香港节点完整部署  ${D}(全新安装 WireGuard + V2bX，可选 WARP)${N}"
    echo -e "  ${G}2.${N} WARP 管理         ${D}(Google Gemini 送中 — 安装/状态/诊断/卸载)${N}"
    echo -e "  ${G}3.${N} 备份当前配置      ${D}(保存 WireGuard 密钥供重装系统使用)${N}"
    echo -e "  ${G}4.${N} 恢复配置          ${D}(重装后从备份恢复)${N}"
    echo -e "  ${G}5.${N} 清除解密缓存      ${D}(下次运行重新输入口令)${N}"
    echo -e "  ${G}0.${N} 退出"
    echo
    prompt_read choice "  请输入选项 [0-5]: "
    echo
    case "${choice}" in
      1)
        load_secrets
        load_module hk-setup.sh
        hk_run_install
        ;;
      2)
        load_module warp.sh
        menu_warp
        ;;
      3)
        load_secrets
        load_module hk-setup.sh
        hk_run_backup
        ;;
      4)
        load_secrets
        load_module hk-setup.sh
        hk_run_restore
        ;;
      5)
        clear_secrets_cache
        ;;
      0)
        echo -e "  ${D}www.flytoex.com${N}"
        exit 0
        ;;
      *)
        error "无效选项，请重新输入"
        sleep 1
        ;;
    esac
  done
}

# ============================================================
# 命令行参数支持
# ============================================================
main() {
  check_root

  case "${1:-}" in
    --install|install)
      load_secrets
      load_module hk-setup.sh
      hk_run_install
      ;;
    --backup|backup)
      load_secrets
      load_module hk-setup.sh
      hk_run_backup
      ;;
    --restore|restore)
      load_secrets
      load_module hk-setup.sh
      hk_run_restore
      ;;
    --warp|warp)
      shift || true
      load_module warp.sh
      case "${1:-}" in
        install)   warp_do_install ;;
        status)    command -v warp >/dev/null 2>&1 && warp status || warn "WARP 未安装" ;;
        test)      command -v warp >/dev/null 2>&1 && warp test  || warn "WARP 未安装" ;;
        uninstall) command -v warp >/dev/null 2>&1 && warp uninstall || warn "WARP 未安装" ;;
        *)         load_secrets; menu_warp ;;
      esac
      ;;
    --clear-cache)
      check_root
      clear_secrets_cache
      ;;
    --help|-h)
      show_banner
      echo "用法: flyto.sh [选项]"
      echo
      echo "  (无参数)          交互菜单"
      echo "  install           香港节点安装"
      echo "  backup            备份配置"
      echo "  restore           恢复配置"
      echo "  warp [install|status|test|uninstall]"
      echo "  --clear-cache     清除解密缓存"
      echo
      echo "  官网: www.flytoex.com"
      ;;
    *)
      show_main_menu
      ;;
  esac
}

main "$@"
