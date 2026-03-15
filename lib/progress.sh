#!/usr/bin/env bash
# ============================================================
# lib/progress.sh — FLYTOex Network 部署进度追踪
# 提供步骤计数、进度百分比、步骤导航（继续/返回/退出）
# ============================================================

# 全局步骤状态
_STEP_TOTAL=6
_STEP_CURRENT=0
_STEP_NAME=""

# ── 初始化步骤计数器 ────────────────────────────────────
progress_init() {
  _STEP_TOTAL="${1:-6}"
  _STEP_CURRENT=0
}

# ── 进入下一步 ──────────────────────────────────────────
# progress_step N "步骤名"
progress_step() {
  _STEP_CURRENT="$1"
  _STEP_NAME="$2"
  local pct=$(( _STEP_CURRENT * 100 / _STEP_TOTAL ))

  if [[ "${UI_USE_DIALOG:-0}" == "1" ]]; then
    # dialog infobox 短暂显示步骤名
    read -r rows cols <<< "$(_ui_size 2>/dev/null || echo '24 80')"
    dialog --backtitle "FLYTOex Network" \
           --title " 部署进度 " \
           --infobox "步骤 ${_STEP_CURRENT}/${_STEP_TOTAL}：${_STEP_NAME}\n\n进度 ${pct}%" \
           6 $((cols - 20)) 2>/dev/null || true
    sleep 0.4
    clear 2>/dev/null || true
  fi

  echo
  echo -e "  ${O}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${O}▶  步骤 ${_STEP_CURRENT}/${_STEP_TOTAL}：${_STEP_NAME}${N}"
  _progress_bar "${_STEP_CURRENT}" "${_STEP_TOTAL}"
  echo -e "  ${O}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo
}

_progress_bar() {
  local cur="$1" tot="$2"
  local width=40 pct=0 filled=0 bar=""
  [[ "${tot}" -gt 0 ]] && pct=$(( cur * 100 / tot ))
  filled=$(( pct * width / 100 ))
  bar="$(printf '%*s' "${filled}" '' | tr ' ' '█')"
  bar="${bar}$(printf '%*s' "$((width - filled))" '' | tr ' ' '░')"
  echo -e "  ${G}[${bar}]${N} ${pct}%"
}

# ── 步骤间导航提示 ──────────────────────────────────────
# progress_gate "步骤描述"
# 返回: 0=继续  2=返回上级  3=退出脚本
progress_gate() {
  local desc="${1:-继续下一步？}"

  if [[ "${UI_USE_DIALOG:-0}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size 2>/dev/null || echo '24 80')"
    local choice
    choice="$(dialog --backtitle "FLYTOex Network" \
                     --title " 步骤完成 " \
                     --menu "${desc}" \
                     12 $((cols - 20)) 3 \
                     "continue" "继续下一步" \
                     "back"     "返回上级菜单" \
                     "quit"     "退出脚本" \
                     2>&1 >/dev/tty)" || true
    clear 2>/dev/null || true
    case "${choice}" in
      continue) return 0 ;;
      back)     return 2 ;;
      quit)     exit 0   ;;
      *)        return 0 ;;   # 按 ESC 等，默认继续
    esac
  else
    echo
    echo -e "  ${D}选项：Enter/y = 继续  |  r = 返回菜单  |  q = 退出${N}"
    printf "  %s [Enter]: " "${desc}" >/dev/tty
    local ans=""
    if ! IFS= read -r ans </dev/tty 2>/dev/null; then
      ui_warn "未检测到交互输入，默认继续"
      return 0
    fi
    ans="$(echo "${ans}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "${ans}" in
      ""|y|yes)      return 0 ;;
      r|back|return) return 2 ;;
      q|quit|exit)   exit 0   ;;
      *)
        ui_warn "未识别的输入，默认继续"
        return 0
        ;;
    esac
  fi
}

# ── 部署完成总结 ────────────────────────────────────────
progress_complete() {
  if [[ "${UI_USE_DIALOG:-0}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size 2>/dev/null || echo '24 80')"
    dialog --backtitle "FLYTOex Network" \
           --title " 部署完成 " \
           --msgbox "香港节点部署成功！\n\n所有步骤均已完成。" \
           8 $((cols - 20)) 2>/dev/null || true
    clear 2>/dev/null || true
  fi
  _progress_bar "${_STEP_TOTAL}" "${_STEP_TOTAL}"
  echo
  ui_ok "全部步骤完成"
  echo
}
