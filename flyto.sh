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
BG_GREEN='\033[48;5;22m'
W='\033[1;37m'
O='\033[38;5;208m'
G='\033[1;32m'
R='\033[1;31m'
Y='\033[1;33m'
C='\033[1;36m'
D='\033[2;37m'
N='\033[0m'

info()    { echo -e "${C}[INFO]${N} $*"; }
success() { echo -e "${G}[OK]${N} $*"; }
warn()    { echo -e "${Y}[WARN]${N} $*"; }
error()   { echo -e "${R}[ERROR]${N} $*" >&2; }

FLYTO_INTERACTIVE=0

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

trim_text() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

drain_input_buffer() {
  local __junk=""
  while IFS= read -r -t 0 -u "${INPUT_FD}" __junk; do :; done
}

prompt_menu_choice() {
  local __var_name="$1"
  local __prompt="$2"
  local __value=""
  drain_input_buffer
  prompt_read __value "${__prompt}"
  __value="$(trim_text "${__value}")"
  printf -v "${__var_name}" '%s' "${__value}"
}

pause_screen() {
  local __prompt="${1:-  按回车继续...}"
  local __dummy=""
  [[ "${FLYTO_INTERACTIVE}" == "1" ]] || return 0
  echo
  if ! IFS= read -r -u "${INPUT_FD}" -p "${__prompt}" __dummy; then
    echo
    warn "未检测到交互输入，跳过暂停"
  fi
  echo
}

run_action() {
  local __rc=0
  set +e
  "$@"
  __rc=$?
  set -e
  return "${__rc}"
}

run_and_warn() {
  local __desc="$1"
  shift
  local __rc=0
  run_action "$@" || __rc=$?
  if [[ ${__rc} -ne 0 ]]; then
    warn "${__desc}返回异常（退出码 ${__rc}）"
  fi
  return 0
}

# ── Banner ──────────────────────────────────────────────────
show_banner() {
  clear 2>/dev/null || true
  echo
  echo -e "${W}  ███████╗██╗  ██╗   ██╗████████╗ ██████╗ ${N}"
  echo -e "${W}  ██╔════╝██║  ╚██╗ ██╔╝╚══██╔══╝██╔═══██╗${N}"
  echo -e "${W}  █████╗  ██║   ╚████╔╝    ██║   ██║   ██║${N}"
  echo -e "${W}  ██╔══╝  ██║    ╚██╔╝     ██║   ██║   ██║${N}"
  echo -e "${W}  ██║     ███████╗██║      ██║   ╚██████${O}╔╝█╗${N}"
  echo -e "${W}  ╚═╝     ╚══════╝╚═╝      ╚═╝    ╚════${O}═╝ ╚╝${N}"
  echo
  echo -e "  ${O}▌${N} ${W}FLYTOex Network${N}  ${C}·${N}  运维控制台"
  echo -e "  ${O}▌${N} ${C}v${FLYTO_VERSION}${N}  ${C}·${N}  github.com/panwudi/flyto-network"
  echo -e "  ${O}▌${N} ${C}www.flytoex.com${N}"
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
  echo -e "  ${C}╔════════════════════════════════════════════════════╗${N}"
  echo -e "  ${C}║${N} ${W}解密密钥输入${N}"
  echo -e "  ${C}║${N} ${D}请输入密钥后回车（输入内容不会回显）${N}"
  echo -e "  ${C}║${N}"
  echo -e "  ${C}║${N} ${G}输入位:${N} ${D}[ 在下方光标处输入 ]${N}"
  echo -e "  ${C}╚════════════════════════════════════════════════════╝${N}"
  local pass=""
  while true; do
    prompt_read_secret pass "  密钥输入 > "
    echo
    if [[ -z "${pass}" ]]; then
      warn "密钥不能为空，请重新输入"
      continue
    fi
    break
  done
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
    info "请确认上方提示后继续"
    pause_screen "  解密成功，按回车继续..."
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
  FLYTO_INTERACTIVE=1
  while true; do
    local choice=""
    echo
    echo -e "  ${W}WARP 管理（Google / Gemini / OpenAI / Claude 相关流量）${N}"
    echo -e "  ${D}────────────────────────────────────────────────────${N}"
    echo
    echo -e "  ${G}1.${N} 安装 / 升级 WARP"
    echo -e "  ${G}2.${N} 查看 WARP 状态"
    echo -e "  ${G}3.${N} 8 层逐层诊断 (warp test)"
    echo -e "  ${G}4.${N} 重启 WARP"
    echo -e "  ${G}5.${N} 卸载 WARP"
    echo -e "  ${G}0/q.${N} 返回主菜单 / 退出脚本"
    echo
    prompt_menu_choice choice "  请输入选项 [0-5/q]: "
    case "${choice}" in
      1)
        load_module warp.sh
        run_and_warn "WARP 安装/升级" warp_do_install
        pause_screen "  按回车返回 WARP 菜单..."
        ;;
      2)
        if command -v warp >/dev/null 2>&1; then
          if ! run_action warp status; then
            warn "WARP 状态查询失败，自动输出调试信息"
            run_action warp debug || true
          fi
        else
          warn "WARP 尚未安装"
        fi
        pause_screen "  按回车返回 WARP 菜单..."
        ;;
      3)
        if command -v warp >/dev/null 2>&1; then
          if ! run_action warp test; then
            warn "WARP 诊断失败，自动输出调试信息"
            run_action warp debug || true
          fi
        else
          warn "WARP 尚未安装"
        fi
        pause_screen "  按回车返回 WARP 菜单..."
        ;;
      4)
        if command -v warp >/dev/null 2>&1; then
          run_and_warn "WARP 重启" warp restart
        else
          warn "WARP 尚未安装"
        fi
        pause_screen "  按回车返回 WARP 菜单..."
        ;;
      5)
        if command -v warp >/dev/null 2>&1; then
          run_and_warn "WARP 卸载" warp uninstall
        else
          warn "WARP 尚未安装"
        fi
        pause_screen "  按回车返回 WARP 菜单..."
        ;;
      0) return 0 ;;
      [Qq]|[Qq][Uu][Ii][Tt]|[Ee][Xx][Ii][Tt])
        echo -e "  ${D}www.flytoex.com${N}"
        exit 0
        ;;
      *) error "无效选项"; sleep 1 ;;
    esac
  done
}

# ============================================================
# 主菜单
# ============================================================
show_main_menu() {
  FLYTO_INTERACTIVE=1
  while true; do
    local choice=""
    show_banner
    echo -e "${C}  ╔══════════════════════════════════════════════════════╗${N}"
    echo -e "${C}  ║                    主菜单 Main Menu                 ║${N}"
    echo -e "${C}  ╚══════════════════════════════════════════════════════╝${N}"
    echo
    echo -e "  ${G}1.${N} 备份当前配置      ${D}(重装前导出 WireGuard / V2bX 关键参数)${N}"
    echo -e "  ${G}2.${N} 恢复当前配置      ${D}(从备份块恢复 WireGuard + V2bX)${N}"
    echo -e "  ${G}3.${N} WARP 管理         ${D}(安装/状态/诊断/重启/卸载)${N}"
    echo -e "  ${G}4.${N} 完整全新部署      ${D}(WireGuard + V2bX + 可选 WARP)${N}"
    echo -e "  ${G}5.${N} 清除解密信息      ${D}(下次重新输入解密密钥)${N}"
    echo -e "  ${G}0/q.${N} 退出"
    echo
    prompt_menu_choice choice "  请输入选项 [0-5/q]: "
    echo
    case "${choice}" in
      1)
        load_secrets
        load_module hk-setup.sh
        run_and_warn "配置备份" hk_run_backup
        pause_screen "  按回车返回主菜单..."
        ;;
      2)
        load_secrets
        load_module hk-setup.sh
        run_and_warn "配置恢复" hk_run_restore
        pause_screen "  按回车返回主菜单..."
        ;;
      3)
        load_module warp.sh
        run_and_warn "WARP 菜单" menu_warp
        ;;
      4)
        load_secrets
        load_module hk-setup.sh
        run_and_warn "完整全新部署" hk_run_fresh
        pause_screen "  按回车返回主菜单..."
        ;;
      5)
        run_and_warn "清除解密信息" clear_secrets_cache
        pause_screen "  按回车返回主菜单..."
        ;;
      0)
        echo -e "  ${D}www.flytoex.com${N}"
        exit 0
        ;;
      [Qq]|[Qq][Uu][Ii][Tt]|[Ee][Xx][Ii][Tt])
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
        status)
          if command -v warp >/dev/null 2>&1; then
            if ! warp status; then
              warn "WARP 状态查询失败，自动输出调试信息"
              warp debug || true
            fi
          else
            warn "WARP 未安装"
          fi
          ;;
        test)
          if command -v warp >/dev/null 2>&1; then
            if ! warp test; then
              warn "WARP 诊断失败，自动输出调试信息"
              warp debug || true
            fi
          else
            warn "WARP 未安装"
          fi
          ;;
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
