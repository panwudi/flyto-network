#!/usr/bin/env bash
# ============================================================
# flyto.sh — FLYTOex Network 运维工具集 v3
#
# 新增：节点角色选择
#   中转节点  — WG 客户端（可选）+ V2bX（可选）+ WARP（可选）
#   出口节点  — WG 服务端 + 纯转发，不装 V2bX
#   全功能节点 — 无 WG + V2bX（可选）+ WARP（可选）
# ============================================================
set -euo pipefail

FLYTO_VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _lib in ui.sh validate.sh progress.sh error.sh; do
  # shellcheck disable=SC1090
  [[ -f "${SCRIPT_DIR}/lib/${_lib}" ]] && source "${SCRIPT_DIR}/lib/${_lib}"
done

# ── Root 检查 ────────────────────────────────────────────────
check_root() {
  [[ "${EUID:-0}" -eq 0 ]] || { ui_error "请使用 root 运行"; exit 1; }
}

# ============================================================
# Secrets 管理
# ============================================================
SECRETS_CACHE="/etc/flyto/.secrets"
SECRETS_ENC="${SCRIPT_DIR}/secrets.enc"

load_secrets() {
  if [[ -f "${SECRETS_CACHE}" ]]; then
    # shellcheck disable=SC1090
    source "${SECRETS_CACHE}"; return 0
  fi
  [[ -f "${SECRETS_ENC}" ]] || {
    ui_error "未找到 ${SECRETS_ENC}，请先运行：bash tools/gen-secrets.sh"
    exit 1
  }

  local pass="" attempts=0
  while true; do
    ui_password pass "请输入配置解密口令" || exit 1
    [[ -z "${pass}" ]] && { ui_warn "口令不能为空"; continue; }
    mkdir -p /etc/flyto
    local tmp; tmp="$(mktemp)"
    if openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass "pass:${pass}" -d -base64 \
        -in "${SECRETS_ENC}" -out "${tmp}" 2>/dev/null; then
      mv "${tmp}" "${SECRETS_CACHE}"; chmod 600 "${SECRETS_CACHE}"
      # shellcheck disable=SC1090
      source "${SECRETS_CACHE}"
      ui_ok "配置解密成功"
      return 0
    fi
    rm -f "${tmp}"; attempts=$((attempts+1))
    ui_warn "口令错误（第 ${attempts} 次）"
    [[ "${attempts}" -ge 3 ]] && { ui_error "口令错误次数过多"; exit 1; }
  done
}

clear_secrets_cache() {
  [[ -f "${SECRETS_CACHE}" ]] && rm -f "${SECRETS_CACHE}" && ui_ok "已清除配置缓存" \
    || ui_info "无缓存需要清除"
}

# ============================================================
# 模块加载
# ============================================================
load_module() {
  local mod="${SCRIPT_DIR}/modules/$1"
  [[ -f "${mod}" ]] || { ui_error "模块 $1 未找到：${mod}"; exit 1; }
  # shellcheck disable=SC1090
  source "${mod}"
}

# ============================================================
# 节点角色说明
# ============================================================
_show_role_desc() {
  echo
  echo -e "  \033[1;37m节点角色说明：\033[0m"
  echo -e "  \033[1;32m1. 中转节点\033[0m  ${D:-}(如香港节点)${N:-}"
  echo    "     • WireGuard 客户端 → 连接到出口节点（可选）"
  echo    "     • V2bX 代理节点管理（可选）"
  echo    "     • WARP 分流（可选）"
  echo    "     • 强制：禁用 IPv6 / 锁定 DNS"
  echo
  echo -e "  \033[1;32m2. 出口节点\033[0m  ${D:-}(如美国节点)${N:-}"
  echo    "     • WireGuard 服务端，接受中转节点连接"
  echo    "     • 不安装 V2bX"
  echo    "     • WARP（可选）"
  echo    "     • 强制：禁用 IPv6 / 锁定 DNS / IPv4 转发"
  echo
  echo -e "  \033[1;32m3. 全功能节点\033[0m  ${D:-}(单机直接提供服务)${N:-}"
  echo    "     • 无 WireGuard（流量在本机终止）"
  echo    "     • V2bX（可选）"
  echo    "     • WARP（可选）"
  echo    "     • 强制：禁用 IPv6 / 锁定 DNS"
  echo
}

# ============================================================
# 全功能节点（无 WG）
# ============================================================
_run_standalone() {
  ui_step "全功能节点部署"

  # 强制基础系统（不开 IPv4 转发）
  load_module hk-setup.sh
  # 强制 ENABLE_WG=0，跳过 WG 询问直接走全功能路径
  ENABLE_WG=0
  hk_run_fresh
}

# ============================================================
# WARP 子菜单
# ============================================================
menu_warp() {
  load_module warp.sh
  while true; do
    local choice=""
    ui_menu choice "WARP 管理" "Google / Gemini / OpenAI / Claude 流量分流" \
      "1" "安装 / 升级 WARP" \
      "2" "查看状态" \
      "3" "8 层逐层诊断" \
      "4" "重启 WARP" \
      "5" "卸载 WARP" \
      "0" "返回" || return 0

    case "${choice}" in
      1) warp_do_install; ui_pause ;;
      2) command -v warp >/dev/null 2>&1 && { warp status || warp debug 2>/dev/null || true; } \
           || ui_warn "WARP 尚未安装"; ui_pause ;;
      3) command -v warp >/dev/null 2>&1 && { warp test || warp debug 2>/dev/null || true; } \
           || ui_warn "WARP 尚未安装"; ui_pause ;;
      4) command -v warp >/dev/null 2>&1 && warp restart && ui_ok "已重启" \
           || ui_warn "WARP 未安装"; ui_pause ;;
      5) command -v warp >/dev/null 2>&1 && ui_confirm "确认卸载？" "N" && warp uninstall \
           || true; ui_pause ;;
      0|"") return 0 ;;
    esac
  done
}

# ============================================================
# 主菜单
# ============================================================
show_main_menu() {
  ui_ensure_dialog 2>/dev/null || true

  while true; do
    ui_banner

    local choice=""
    ui_menu choice \
      "主菜单  FLYTOex Network v${FLYTO_VERSION}" \
      "请选择操作" \
      "1" "部署新节点        (选择角色：中转 / 出口 / 全功能)" \
      "2" "从备份恢复        (中转节点 — 粘贴备份块)" \
      "3" "备份当前配置      (中转节点 — 导出关键参数)" \
      "4" "WARP 管理         (安装/状态/诊断/重启/卸载)" \
      "5" "清除解密缓存      (下次重新输入口令)" \
      "0" "退出" || { echo; exit 0; }

    case "${choice}" in
      1)
        _show_role_desc
        local role=""
        ui_menu role "选择节点角色" "本台服务器将扮演哪种角色？" \
          "1" "中转节点  (WG客户端可选 + V2bX可选 + WARP可选)" \
          "2" "出口节点  (WG服务端 + 纯转发，不装V2bX)" \
          "3" "全功能节点(无WG + V2bX可选 + WARP可选)" \
          "0" "返回" || continue

        case "${role}" in
          1)
            load_secrets
            load_module hk-setup.sh
            hk_run_fresh
            ;;
          2)
            load_module wg-server.sh
            wgs_run_deploy
            ;;
          3)
            load_secrets
            _run_standalone
            ;;
          0|"") continue ;;
        esac
        ui_pause "  按回车返回主菜单..."
        ;;
      2)
        load_secrets
        load_module hk-setup.sh
        hk_run_restore
        ui_pause "  按回车返回主菜单..."
        ;;
      3)
        load_secrets
        load_module hk-setup.sh
        hk_run_backup
        ui_pause "  按回车返回主菜单..."
        ;;
      4)
        menu_warp
        ;;
      5)
        clear_secrets_cache
        ui_pause "  按回车返回主菜单..."
        ;;
      0|"")
        echo -e "  \033[2;37mwww.flytoex.com\033[0m"
        exit 0
        ;;
    esac
  done
}

# ============================================================
# 命令行参数
# ============================================================
main() {
  check_root

  case "${1:-}" in
    transit|hk)
      load_secrets; load_module hk-setup.sh
      hk_run_install
      ;;
    exit-node|us)
      load_module wg-server.sh
      wgs_run_deploy
      ;;
    standalone)
      load_secrets; _run_standalone
      ;;
    backup)
      load_secrets; load_module hk-setup.sh; hk_run_backup
      ;;
    restore)
      load_secrets; load_module hk-setup.sh; hk_run_restore
      ;;
    warp)
      shift || true
      load_module warp.sh
      case "${1:-menu}" in
        install)   warp_do_install ;;
        status)    command -v warp >/dev/null 2>&1 && warp status  || ui_warn "WARP 未安装" ;;
        test)      command -v warp >/dev/null 2>&1 && warp test    || ui_warn "WARP 未安装" ;;
        uninstall) command -v warp >/dev/null 2>&1 && warp uninstall || ui_warn "WARP 未安装" ;;
        *)         load_secrets; menu_warp ;;
      esac
      ;;
    --clear-cache)
      clear_secrets_cache
      ;;
    --no-dialog)
      export FLYTO_NO_DIALOG=1; show_main_menu
      ;;
    --help|-h)
      ui_banner
      cat <<'HELP'
用法: flyto.sh [命令]

节点角色部署：
  transit / hk      中转节点（WG客户端可选 + V2bX可选 + WARP可选）
  exit-node / us    出口节点（WG服务端 + 纯转发）
  standalone        全功能节点（无WG + V2bX可选 + WARP可选）

维护命令：
  backup            备份中转节点 WireGuard 配置
  restore           从备份块恢复中转节点
  warp [子命令]     WARP 管理 (install/status/test/uninstall)
  --clear-cache     清除解密口令缓存
  --no-dialog       强制纯文本模式
  --help            显示帮助

环境变量：
  FLYTO_NO_DIALOG=1   强制纯文本模式
  FLYTO_ERROR_LOG     错误日志路径（默认 /var/log/flyto-error.log）

HELP
      ;;
    *)
      show_main_menu
      ;;
  esac
}

main "$@"
