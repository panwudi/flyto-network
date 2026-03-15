#!/usr/bin/env bash
# ============================================================
# lib/error.sh — FLYTOex Network 统一错误处理
# - trap ERR：自动捕获并定位失败步骤
# - 每种错误附带恢复建议
# - 区分"可继续警告"与"致命错误"
# ============================================================

# 当前正在执行的步骤（由 progress_step 设置）
_ERR_STEP_NAME="${_STEP_NAME:-未知步骤}"
_ERR_LOG_FILE="${FLYTO_ERROR_LOG:-/var/log/flyto-error.log}"

# ── 安装 ERR trap ────────────────────────────────────────
# 在需要严格错误捕获的代码段调用一次
error_trap_install() {
  trap '_error_handler "${BASH_COMMAND}" "$?" "${LINENO}" "${BASH_SOURCE[0]:-script}"' ERR
}

# ── 卸载 trap（在允许失败的代码段前调用）──────────────
error_trap_remove() {
  trap - ERR
}

# ── 内部：ERR handler ────────────────────────────────────
_error_handler() {
  local cmd="$1"
  local rc="$2"
  local line="$3"
  local file="$4"
  local step="${_STEP_NAME:-未知}"

  # 写入日志
  mkdir -p "$(dirname "${_ERR_LOG_FILE}")" 2>/dev/null || true
  {
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "步骤   : ${step}"
    echo "文件   : ${file}:${line}"
    echo "命令   : ${cmd}"
    echo "退出码 : ${rc}"
    echo
  } >> "${_ERR_LOG_FILE}" 2>/dev/null || true

  # 终端输出
  echo >&2
  echo -e "\033[1;31m╔══════════════════════════════════════════════════╗\033[0m" >&2
  echo -e "\033[1;31m║  ✗  部署失败                                      ║\033[0m" >&2
  echo -e "\033[1;31m╚══════════════════════════════════════════════════╝\033[0m" >&2
  echo >&2
  echo -e "  \033[1;37m失败步骤\033[0m : ${step}" >&2
  echo -e "  \033[1;37m出错位置\033[0m : ${file} 第 ${line} 行" >&2
  echo -e "  \033[1;37m失败命令\033[0m : ${cmd}" >&2
  echo -e "  \033[1;37m退出码  \033[0m : ${rc}" >&2
  echo >&2

  # 针对步骤给出恢复建议
  _error_hint "${step}" "${cmd}"

  echo >&2
  echo -e "  \033[2;37m错误日志：${_ERR_LOG_FILE}\033[0m" >&2
  echo >&2
}

# ── 恢复建议（根据步骤名匹配）──────────────────────────
_error_hint() {
  local step="$1"
  local cmd="$2"

  echo -e "  \033[1;33m排查建议：\033[0m" >&2

  case "${step}" in
    *基础系统*|*系统配置*)
      cat >&2 <<'HINT'
  • 检查网络连通性：ping 8.8.8.8
  • 手动更新软件源：apt-get update
  • 查看 apt 日志：tail -50 /var/log/apt/term.log
HINT
      ;;
    *网络信息*|*采集*)
      cat >&2 <<'HINT'
  • 确认 WAN 接口：ip -o -4 route show to default
  • 确认默认网关：ip route show default
  • 确认公网 IP：curl -4 -s https://ifconfig.io
HINT
      ;;
    *WireGuard*|*wg*)
      cat >&2 <<'HINT'
  • 查看 WG 日志：journalctl -u wg-quick@wg0 -n 50
  • 检查配置文件：cat /etc/wireguard/wg0.conf
  • 检查路由规则：ip rule list && ip route show
  • 手动重启 WG ：systemctl restart wg-quick@wg0
  • 临时恢复路由：ip route replace default via <GW> dev <WAN_IF>
HINT
      ;;
    *V2bX*|*v2bx*)
      cat >&2 <<'HINT'
  • 查看 V2bX 日志：journalctl -u V2bX -n 50
  • 检查配置文件：cat /etc/V2bX/config.json
  • 手动重启：systemctl restart V2bX
  • 检查面板连通性：curl -v "${PANEL_API_HOST}" --max-time 10
HINT
      ;;
    *面板*|*panel*|*监控*)
      cat >&2 <<'HINT'
  • 手动执行监控脚本：/usr/local/bin/update-panel-route.sh
  • 查看监控日志：tail -30 /var/log/update-panel-route.log
  • 检查 cron：crontab -l
HINT
      ;;
    *secrets*|*解密*|*口令*)
      cat >&2 <<'HINT'
  • 清除旧缓存后重试：bash flyto.sh --clear-cache
  • 重新生成 secrets.enc：bash tools/gen-secrets.sh
HINT
      ;;
    *)
      # 通用建议
      cat >&2 <<'HINT'
  • 重新运行脚本，从当前步骤继续
  • 如反复失败，请检查系统网络和权限后重试
HINT
      ;;
  esac

  # 如果是 curl/wget 失败，额外提示网络
  if [[ "${cmd}" =~ ^curl|^wget ]]; then
    echo -e "  • 网络请求失败，请检查出口连通性：curl -v https://ifconfig.io" >&2
  fi
}

# ── 致命错误（退出）────────────────────────────────────
# error_fatal "消息" [退出码]
error_fatal() {
  local msg="$1"
  local rc="${2:-1}"
  ui_error "${msg}"
  _error_hint "${_STEP_NAME:-}" ""
  exit "${rc}"
}

# ── 可恢复错误（仅警告，不退出）────────────────────────
error_warn_continue() {
  local msg="$1"
  ui_warn "${msg}（继续执行，此步骤为非关键步骤）"
}

# ── 显示历史错误日志 ────────────────────────────────────
error_show_log() {
  if [[ -f "${_ERR_LOG_FILE}" ]]; then
    echo -e "  \033[1;33m最近错误日志（${_ERR_LOG_FILE}）：\033[0m"
    tail -60 "${_ERR_LOG_FILE}"
  else
    echo "  暂无错误日志"
  fi
}
