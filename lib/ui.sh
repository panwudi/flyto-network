#!/usr/bin/env bash
# ============================================================
# lib/ui.sh — FLYTOex Network UI 封装库
# 提供 dialog TUI / 纯文本两种模式，自动检测并切换
# ============================================================

# ── 颜色 ────────────────────────────────────────────────────
W='\033[1;37m'
O='\033[38;5;208m'
G='\033[1;32m'
R='\033[1;31m'
Y='\033[1;33m'
C='\033[1;36m'
D='\033[2;37m'
N='\033[0m'

# ── 模式检测 ─────────────────────────────────────────────────
# FLYTO_NO_DIALOG=1  强制纯文本
# 无 TTY 时自动降级
UI_USE_DIALOG=0
_ui_detect_mode() {
  [[ "${FLYTO_NO_DIALOG:-0}" == "1" ]] && return
  command -v dialog >/dev/null 2>&1 || return
  [[ -t 0 && -t 1 ]] || return
  UI_USE_DIALOG=1
}
_ui_detect_mode

# dialog 尺寸辅助
_ui_size() {
  local rows cols
  rows="$(tput lines 2>/dev/null || echo 24)"
  cols="$(tput cols  2>/dev/null || echo 80)"
  # 限制最大以避免撑满屏幕
  [[ "${rows}" -gt 40 ]] && rows=40
  [[ "${cols}" -gt 100 ]] && cols=100
  echo "${rows} ${cols}"
}

# ── 日志函数 ─────────────────────────────────────────────────
ui_info()    { echo -e "${C}[INFO]${N} $*"; }
ui_ok()      { echo -e "${G}[ OK ]${N} $*"; }
ui_warn()    { echo -e "${Y}[WARN]${N} $*" >&2; }
ui_error()   { echo -e "${R}[ERR ]${N} $*" >&2; }
ui_step()    { echo; echo -e "  ${O}▶  $*${N}"; echo; }

# ── Banner ───────────────────────────────────────────────────
ui_banner() {
  clear 2>/dev/null || true
  echo
  echo -e "${W}  ███████╗██╗  ██╗   ██╗████████╗ ██████╗ ${N}"
  echo -e "${W}  ██╔════╝██║  ╚██╗ ██╔╝╚══██╔══╝██╔═══██╗${N}"
  echo -e "${W}  █████╗  ██║   ╚████╔╝    ██║   ██║   ██║${N}"
  echo -e "${W}  ██╔══╝  ██║    ╚██╔╝     ██║   ██║   ██║${N}"
  echo -e "${W}  ██║     ███████╗██║      ██║   ╚██████${O}╔╝█╗${N}"
  echo -e "${W}  ╚═╝     ╚══════╝╚═╝      ╚═╝    ╚════${O}═╝ ╚╝${N}"
  echo
  echo -e "  ${O}▌${N} ${W}FLYTOex Network${N}  ${C}·${N}  运维控制台  v${FLYTO_VERSION:-?}"
  echo -e "  ${O}▌${N} ${C}www.flytoex.com${N}"
  echo
}

# ── 消息框 ───────────────────────────────────────────────────
# ui_msgbox "标题" "内容"
ui_msgbox() {
  local title="$1" msg="$2"
  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size)"
    dialog --backtitle "FLYTOex Network" \
           --title " ${title} " \
           --msgbox "${msg}" \
           $((rows - 6)) $((cols - 10))
    clear 2>/dev/null || true
  else
    echo
    echo -e "  ${C}╔══ ${title} ══╗${N}"
    echo -e "  ${msg}" | sed 's/^/  /'
    echo -e "  ${C}╚$(printf '═%.0s' $(seq 1 $((${#title} + 6))))╝${N}"
    echo
    _ui_pause "  按回车继续..."
  fi
}

# ── 确认框 ───────────────────────────────────────────────────
# ui_confirm "问题" [默认Y/N] → 返回 0=是 1=否
ui_confirm() {
  local prompt="$1"
  local default="${2:-N}"
  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size)"
    local default_flag=""
    [[ "${default}" == "Y" ]] && default_flag="--defaultno" || default_flag=""
    # dialog --yesno 默认 yes 在左，用 --defaultno 翻转
    if [[ "${default}" == "N" ]]; then
      dialog --backtitle "FLYTOex Network" \
             --title " 确认 " \
             --defaultno \
             --yesno "${prompt}" \
             8 $((cols - 20))
    else
      dialog --backtitle "FLYTOex Network" \
             --title " 确认 " \
             --yesno "${prompt}" \
             8 $((cols - 20))
    fi
    local rc=$?
    clear 2>/dev/null || true
    return "${rc}"
  else
    local ans=""
    while true; do
      if [[ "${default}" == "Y" ]]; then
        printf "  %s [Y/n]: " "${prompt}" >/dev/tty
      else
        printf "  %s [y/N]: " "${prompt}" >/dev/tty
      fi
      if ! IFS= read -r ans </dev/tty; then
        ui_warn "未检测到交互输入，使用默认值 ${default}"
        ans="${default}"
      fi
      [[ -z "${ans}" ]] && ans="${default}"
      case "${ans}" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        [Nn]|[Nn][Oo])     return 1 ;;
        *) ui_warn "请输入 y 或 n" ;;
      esac
    done
  fi
}

# ── 单行输入框 ───────────────────────────────────────────────
# ui_input 变量名 "标签" "默认值（可空）" "提示文字（可空）"
ui_input() {
  local __var="$1"
  local label="$2"
  local default="${3:-}"
  local hint="${4:-}"
  local __val=""

  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size)"
    local extra_msg=""
    [[ -n "${hint}" ]] && extra_msg="\n${hint}"
    local tmp
    tmp="$(mktemp)"
    dialog --backtitle "FLYTOex Network" \
           --title " 输入 " \
           --inputbox "${label}${extra_msg}" \
           10 $((cols - 10)) \
           "${default}" \
           2>"${tmp}"
    local rc=$?
    __val="$(cat "${tmp}")"
    rm -f "${tmp}"
    clear 2>/dev/null || true
    [[ "${rc}" -ne 0 ]] && return 1
  else
    [[ -n "${hint}" ]] && echo -e "  ${D}${hint}${N}" >/dev/tty
    if [[ -n "${default}" ]]; then
      printf "  %s [%s]: " "${label}" "${default}" >/dev/tty
    else
      printf "  %s: " "${label}" >/dev/tty
    fi
    if ! IFS= read -r __val </dev/tty; then
      ui_error "未检测到交互输入"
      return 1
    fi
    [[ -z "${__val}" ]] && __val="${default}"
  fi

  __val="$(_ui_trim "${__val}")"
  printf -v "${__var}" '%s' "${__val}"
}

# ── 密码输入框 ───────────────────────────────────────────────
# ui_password 变量名 "标签"
ui_password() {
  local __var="$1"
  local label="$2"
  local __val=""

  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size)"
    local tmp
    tmp="$(mktemp)"
    dialog --backtitle "FLYTOex Network" \
           --title " 密码输入 " \
           --insecure \
           --passwordbox "${label}" \
           8 $((cols - 10)) \
           2>"${tmp}"
    local rc=$?
    __val="$(cat "${tmp}")"
    rm -f "${tmp}"
    clear 2>/dev/null || true
    [[ "${rc}" -ne 0 ]] && return 1
  else
    printf "  %s: " "${label}" >/dev/tty
    if ! IFS= read -rs __val </dev/tty; then
      ui_error "未检测到交互输入"
      return 1
    fi
    echo >/dev/tty
  fi

  printf -v "${__var}" '%s' "${__val}"
}

# ── 菜单选择 ─────────────────────────────────────────────────
# ui_menu 变量名 "标题" "描述" item1_tag item1_label item2_tag item2_label ...
# 返回选中的 tag 写入变量
ui_menu() {
  local __var="$1"; shift
  local title="$1"; shift
  local desc="$1"; shift
  local -a items=("$@")

  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size)"
    local tmp
    tmp="$(mktemp)"
    dialog --backtitle "FLYTOex Network" \
           --title " ${title} " \
           --menu "${desc}" \
           $((rows - 4)) $((cols - 10)) \
           $((rows - 12)) \
           "${items[@]}" \
           2>"${tmp}"
    local rc=$?
    local chosen
    chosen="$(cat "${tmp}")"
    rm -f "${tmp}"
    clear 2>/dev/null || true
    [[ "${rc}" -ne 0 ]] && return 1
    printf -v "${__var}" '%s' "${chosen}"
  else
    echo
    echo -e "  ${W}${title}${N}"
    [[ -n "${desc}" ]] && echo -e "  ${D}${desc}${N}"
    echo -e "  ${D}────────────────────────────────────────${N}"
    local i=0
    local -a tags=()
    while [[ "${i}" -lt "${#items[@]}" ]]; do
      local tag="${items[$i]}"
      local lbl="${items[$((i+1))]}"
      tags+=("${tag}")
      echo -e "  ${G}${tag}.${N} ${lbl}"
      i=$((i + 2))
    done
    echo
    local ans=""
    while true; do
      printf "  请输入选项: " >/dev/tty
      if ! IFS= read -r ans </dev/tty; then
        ui_error "未检测到交互输入"
        return 1
      fi
      ans="$(_ui_trim "${ans}")"
      # 检查是否在合法 tag 列表里
      local valid=0
      for t in "${tags[@]}"; do
        [[ "${ans}" == "${t}" ]] && valid=1 && break
      done
      if [[ "${valid}" == "1" ]]; then
        printf -v "${__var}" '%s' "${ans}"
        return 0
      fi
      ui_warn "无效选项，请重新输入"
    done
  fi
}

# ── 进度条 ───────────────────────────────────────────────────
# ui_progress_start "标题"   — 启动进度条（dialog gauge 或文本）
# ui_progress_update N "消息" — 更新进度（N=0..100）
# ui_progress_done           — 关闭进度条

_UI_GAUGE_PID=""
_UI_GAUGE_FD=""
_UI_GAUGE_FIFO=""

ui_progress_start() {
  local title="${1:-处理中}"
  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size)"
    _UI_GAUGE_FIFO="$(mktemp -u)"
    mkfifo "${_UI_GAUGE_FIFO}"
    dialog --backtitle "FLYTOex Network" \
           --title " ${title} " \
           --gauge "准备中..." \
           8 $((cols - 10)) 0 \
           < "${_UI_GAUGE_FIFO}" &
    _UI_GAUGE_PID=$!
    exec {_UI_GAUGE_FD}>"${_UI_GAUGE_FIFO}"
  else
    echo
    echo -e "  ${O}▶  ${title}${N}"
  fi
}

ui_progress_update() {
  local pct="$1"
  local msg="${2:-}"
  if [[ "${UI_USE_DIALOG}" == "1" && -n "${_UI_GAUGE_FD}" ]]; then
    printf "XXX\n%d\n%s\nXXX\n" "${pct}" "${msg}" >&"${_UI_GAUGE_FD}" 2>/dev/null || true
  else
    local width=30
    local filled=$(( pct * width / 100 ))
    local bar
    bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')"
    bar="${bar}$(printf '%*s' "$((width - filled))" '' | tr ' ' '-')"
    printf "\r  [%s] %3d%%  %s" "${bar}" "${pct}" "${msg}"
    [[ "${pct}" -ge 100 ]] && echo
  fi
}

ui_progress_done() {
  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    if [[ -n "${_UI_GAUGE_FD}" ]]; then
      printf "XXX\n100\n完成\nXXX\n" >&"${_UI_GAUGE_FD}" 2>/dev/null || true
      exec {_UI_GAUGE_FD}>&- 2>/dev/null || true
      _UI_GAUGE_FD=""
    fi
    [[ -n "${_UI_GAUGE_PID}" ]] && wait "${_UI_GAUGE_PID}" 2>/dev/null || true
    _UI_GAUGE_PID=""
    [[ -n "${_UI_GAUGE_FIFO}" ]] && rm -f "${_UI_GAUGE_FIFO}"
    _UI_GAUGE_FIFO=""
    clear 2>/dev/null || true
  else
    echo
  fi
}

# ── Spinner（单条命令执行时显示）────────────────────────────
# ui_spin "描述" cmd args...  → 返回命令退出码
ui_spin() {
  local desc="$1"; shift
  local rc=0
  local tmp_log
  tmp_log="$(mktemp)"

  if [[ -t 1 ]]; then
    "$@" >"${tmp_log}" 2>&1 &
    local pid=$!
    local spin='|/-\'
    local i=0
    while kill -0 "${pid}" 2>/dev/null; do
      i=$(( (i + 1) % 4 ))
      printf "\r  %s %c" "${desc}" "${spin:${i}:1}"
      sleep 0.12
    done
    wait "${pid}" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      printf "\r  %-50s ${G}✓${N}\n" "${desc}"
    else
      printf "\r  %-50s ${R}✗${N}\n" "${desc}"
    fi
  else
    ui_info "${desc}"
    "$@" >"${tmp_log}" 2>&1 || rc=$?
  fi

  if [[ "${rc}" -ne 0 ]]; then
    ui_warn "${desc} 失败 (exit=${rc})，日志："
    sed -n '1,30p' "${tmp_log}" >&2
  fi
  rm -f "${tmp_log}"
  return "${rc}"
}

# ── 多字段表单 ───────────────────────────────────────────────
# ui_form 变量名数组 标签数组 默认值数组 "标题" "描述"
# 纯文本模式下逐字段输入，dialog 模式下显示表单
# 用法:
#   declare -a _vars=("VAR1" "VAR2")
#   declare -a _labels=("字段1" "字段2")
#   declare -a _defaults=("默认1" "默认2")
#   ui_form _vars _labels _defaults "表单标题" "说明"
ui_form() {
  local -n __fvars="$1"
  local -n __flabels="$2"
  local -n __fdefaults="$3"
  local ftitle="$4"
  local fdesc="${5:-}"

  local count="${#__fvars[@]}"

  if [[ "${UI_USE_DIALOG}" == "1" ]]; then
    read -r rows cols <<< "$(_ui_size)"
    local form_args=()
    local row=1
    for (( i=0; i<count; i++ )); do
      local lbl="${__flabels[$i]}"
      local def="${__fdefaults[$i]:-}"
      form_args+=("${lbl}" "${row}" 1 "${def}" "${row}" 22 $((cols - 35)) 0)
      row=$((row + 2))
    done

    local tmp
    tmp="$(mktemp)"
    dialog --backtitle "FLYTOex Network" \
           --title " ${ftitle} " \
           --form "${fdesc}" \
           $((rows - 4)) $((cols - 10)) \
           $((count * 2 + 2)) \
           "${form_args[@]}" \
           2>"${tmp}"
    local rc=$?
    clear 2>/dev/null || true
    [[ "${rc}" -ne 0 ]] && { rm -f "${tmp}"; return 1; }

    local -a results
    mapfile -t results < "${tmp}"
    rm -f "${tmp}"

    for (( i=0; i<count; i++ )); do
      local val="${results[$i]:-}"
      [[ -z "${val}" ]] && val="${__fdefaults[$i]:-}"
      printf -v "${__fvars[$i]}" '%s' "$(_ui_trim "${val}")"
    done
  else
    echo
    echo -e "  ${W}${ftitle}${N}"
    [[ -n "${fdesc}" ]] && echo -e "  ${D}${fdesc}${N}"
    echo -e "  ${D}────────────────────────────────────────${N}"
    for (( i=0; i<count; i++ )); do
      local val=""
      ui_input val "${__flabels[$i]}" "${__fdefaults[$i]:-}" || return 1
      printf -v "${__fvars[$i]}" '%s' "${val}"
    done
  fi
}

# ── 暂停 ─────────────────────────────────────────────────────
_ui_pause() {
  local prompt="${1:-  按回车继续...}"
  local dummy=""
  if ! IFS= read -r dummy </dev/tty 2>/dev/null; then
    echo
  fi
}

ui_pause() {
  _ui_pause "${1:-  按回车继续...}"
}

# ── 文本工具 ─────────────────────────────────────────────────
_ui_trim() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

_ui_strip_ansi() {
  printf '%s' "$1" | sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g'
}

_ui_mask_secret() {
  local v="${1:-}"
  local n="${#v}"
  if   [[ "${n}" -eq 0 ]];   then printf '%s' "<empty>"
  elif [[ "${n}" -le 8 ]];   then printf '%s' "已读取 (${n} chars)"
  else                             printf '%s' "${v:0:4}...${v: -4} (${n} chars)"
  fi
}

# ── 安装 dialog（如果缺失）──────────────────────────────────
ui_ensure_dialog() {
  command -v dialog >/dev/null 2>&1 && return 0
  ui_info "dialog 未安装，尝试自动安装..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y dialog >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y dialog >/dev/null 2>&1 || true
  fi
  if command -v dialog >/dev/null 2>&1; then
    ui_ok "dialog 安装成功"
    _ui_detect_mode
    return 0
  fi
  ui_warn "dialog 安装失败，将使用纯文本模式"
  return 1
}
