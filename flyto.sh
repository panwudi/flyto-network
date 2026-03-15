#!/usr/bin/env bash
# ============================================================
# flyto.sh — FLYTOex Network 运维工具集 v2
#
# 重构改动：
#   - 主菜单接入 dialog TUI（lib/ui.sh）
#   - 加载 lib/* 库（ui / validate / progress / error）
#   - secrets 解密接入 ui_password（更好的输入体验）
#   - WARP 子菜单改为 dialog 菜单
#   - 支持 FLYTO_NO_DIALOG=1 强制纯文本
# ============================================================
set -euo pipefail

FLYTO_VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 加载 lib ─────────────────────────────────────────────────
for _lib in ui.sh validate.sh progress.sh error.sh; do
  # shellcheck disable=SC1090
  [[ -f "${SCRIPT_DIR}/lib/${_lib}" ]] && source "${SCRIPT_DIR}/lib/${_lib}"
done

# ── Root 检查 ────────────────────────────────────────────────
check_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    ui_error "请使用 root 运行"
    exit 1
  fi
}

# ============================================================
# 敏感配置管理
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

  if [[ ! -f "${SECRETS_ENC}" ]]; then
    ui_error "未找到 ${SECRETS_ENC}"
    ui_error "请先运行：bash tools/gen-secrets.sh"
    exit 1
  fi

  local pass=""
  local attempts=0
  while true; do
    ui_password pass "请输入配置解密口令（输入内容不会回显）" || exit 1
    if [[ -z "${pass}" ]]; then
      ui_warn "口令不能为空，请重新输入"
      continue
    fi

    mkdir -p /etc/flyto
    local tmp
    tmp="$(mktemp)"
    if openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass "pass:${pass}" -d -base64 \
        -in "${SECRETS_ENC}" -out "${tmp}" 2>/dev/null; then
      mv "${tmp}" "${SECRETS_CACHE}"
      chmod 600 "${SECRETS_CACHE}"
      # shellcheck disable=SC1090
      source "${SECRETS_CACHE}"
      ui_ok "配置解密成功，已缓存至 ${SECRETS_CACHE}"
      return 0
    else
      rm -f "${tmp}"
      attempts=$((attempts + 1))
      ui_warn "口令错误（第 ${attempts} 次）"
      if [[ "${attempts}" -ge 3 ]]; then
        ui_error "口令错误次数过多，请重新运行或执行：bash tools/gen-secrets.sh"
        exit 1
      fi
    fi
  done
}

clear_secrets_cache() {
  if [[ -f "${SECRETS_CACHE}" ]]; then
    rm -f "${SECRETS_CACHE}"
    ui_ok "已清除配置缓存，下次运行将重新提示口令"
  else
    ui_info "无缓存需要清除"
  fi
}

# ============================================================
# 模块加载
# ============================================================
load_module() {
  local mod="${SCRIPT_DIR}/modules/$1"
  if [[ ! -f "${mod}" ]]; then
    ui_error "模块 $1 未找到：${mod}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${mod}"
}

# ============================================================
# WARP 子菜单
# ============================================================
menu_warp() {
  load_module warp.sh

  while true; do
    local choice=""
    ui_menu choice \
      "WARP 管理" \
      "Google / Gemini / OpenAI / Claude 流量分流" \
      "1" "安装 / 升级 WARP" \
      "2" "查看 WARP 状态" \
      "3" "8 层逐层诊断 (warp test)" \
      "4" "重启 WARP" \
      "5" "卸载 WARP" \
      "0" "返回主菜单" || return 0

    case "${choice}" in
      1)
        warp_do_install
        ui_pause "  按回车返回 WARP 菜单..."
        ;;
      2)
        if command -v warp >/dev/null 2>&1; then
          warp status || { ui_warn "WARP 状态查询失败"; warp debug 2>/dev/null || true; }
        else
          ui_warn "WARP 尚未安装"
        fi
        ui_pause "  按回车返回 WARP 菜单..."
        ;;
      3)
        if command -v warp >/dev/null 2>&1; then
          warp test || { ui_warn "WARP 诊断失败"; warp debug 2>/dev/null || true; }
        else
          ui_warn "WARP 尚未安装"
        fi
        ui_pause "  按回车返回 WARP 菜单..."
        ;;
      4)
        if command -v warp >/dev/null 2>&1; then
          warp restart && ui_ok "WARP 已重启" || ui_warn "WARP 重启失败"
        else
          ui_warn "WARP 尚未安装"
        fi
        ui_pause "  按回车返回 WARP 菜单..."
        ;;
      5)
        if command -v warp >/dev/null 2>&1; then
          if ui_confirm "确认卸载 WARP？" "N"; then
            warp uninstall && ui_ok "WARP 已卸载" || ui_warn "卸载失败"
          fi
        else
          ui_warn "WARP 尚未安装"
        fi
        ui_pause "  按回车返回 WARP 菜单..."
        ;;
      0|"") return 0 ;;
    esac
  done
}

# ============================================================
# 主菜单
# ============================================================
show_main_menu() {
  # 尝试安装 dialog（非强制，失败则降级为纯文本）
  ui_ensure_dialog 2>/dev/null || true

  while true; do
    ui_banner

    local choice=""
    ui_menu choice \
      "主菜单  FLYTOex Network v${FLYTO_VERSION}" \
      "请选择操作" \
      "1" "完整全新部署      (WireGuard + V2bX + 可选 WARP)" \
      "2" "从备份恢复部署    (粘贴备份块一键恢复)" \
      "3" "备份当前配置      (重装前导出关键参数)" \
      "4" "WARP 管理         (安装/状态/诊断/重启/卸载)" \
      "5" "清除解密缓存      (下次重新输入口令)" \
      "0" "退出" || { echo; exit 0; }

    case "${choice}" in
      1)
        load_secrets
        load_module hk-setup.sh
        hk_run_fresh
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
        echo -e "  ${D}www.flytoex.com${N}"
        exit 0
        ;;
      *)
        ui_warn "无效选项，请重新选择"
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
    install)
      load_secrets; load_module hk-setup.sh; hk_run_install
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
      export FLYTO_NO_DIALOG=1
      show_main_menu
      ;;
    --help|-h)
      ui_banner
      cat <<'HELP'
用法: flyto.sh [命令]

  (无参数)          交互菜单（优先使用 dialog TUI）
  install           香港节点安装（全新 / 恢复模式选择）
  backup            备份当前 WireGuard 配置
  restore           从备份块恢复部署
  warp [子命令]     WARP 管理
    install / status / test / uninstall
  --clear-cache     清除解密口令缓存
  --no-dialog       强制纯文本模式（不使用 dialog）
  --help            显示本帮助

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
