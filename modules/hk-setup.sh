#!/usr/bin/env bash
# ============================================================
# modules/hk-setup.sh — 香港中转节点部署模块
# 可由 flyto.sh 加载，也可独立运行（需先设置 PANEL_API_HOST / PANEL_API_KEY）
#
# 功能: 在香港节点配置 WireGuard + V2bX，通过美国出口节点转发流量
#       支持全新安装 / 备份 / 恢复三种模式
#       可选在完成后安装 WARP（Google Gemini 送中）
#
# 项目地址: https://github.com/panwudi/flyto-network
# 官网:     www.flytoex.com
# ============================================================

# ── 颜色（兼容未由 flyto.sh 设置的场景）────────────────────
W="${W:-\033[1;37m}"
O="${O:-\033[38;5;208m}"
G="${G:-\033[1;32m}"
R="${R:-\033[1;31m}"
Y="${Y:-\033[1;33m}"
C="${C:-\033[1;36m}"
D="${D:-\033[2;37m}"
N="${N:-\033[0m}"
BG_GREEN="${BG_GREEN:-\033[48;5;22m}"

_hk_info()  { echo -e "${C}[HK]${N} $*"; }
_hk_ok()    { echo -e "${G}[HK]${N} $*"; }
_hk_warn()  { echo -e "${Y}[HK]${N} $*" >&2; }
_hk_err()   { echo -e "${R}[HK]${N} $*" >&2; }
_hk_step()  { echo; echo -e "  ${O}▶ $*${N}"; echo; }

_hk_card() {
  local title="$1"
  local subtitle="${2:-}"
  echo
  echo -e "  ${C}╔════════════════════════════════════════════════════════════╗${N}"
  echo -e "  ${C}║${N} ${W}${title}${N}"
  [[ -n "${subtitle}" ]] && echo -e "  ${C}║${N} ${D}${subtitle}${N}"
  echo -e "  ${C}╚════════════════════════════════════════════════════════════╝${N}"
}

_hk_pause() {
  local dummy=""
  if ! read -r -p "  按回车继续..." dummy </dev/tty; then
    echo
    _hk_warn "未检测到交互输入，跳过暂停"
  fi
  echo
}

_hk_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

_hk_strip_ansi() {
  printf '%s' "$1" | sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g'
}

_hk_is_placeholder() {
  local v="$(_hk_trim "${1:-}")"
  local u="${v^^}"
  [[ -z "${v}" ]] && return 0
  [[ "${u}" =~ ^REPLACE(_WITH_.*)?$ ]] && return 0
  [[ "${u}" == "DEFAULT" ]] && return 0
  [[ "${u}" == "ENDPOINT" ]] && return 0
  [[ "${u}" == "<EMPTY>" ]] && return 0
  [[ "${u}" == "NULL" ]] && return 0
  return 1
}

_hk_is_ipv4_cidr() {
  local v="$(_hk_trim "${1:-}")"
  [[ "${v}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
}

_hk_guess_peer_tun_ip_from_local() {
  local local_cidr="$(_hk_trim "${1:-}")"
  _hk_is_ipv4_cidr "${local_cidr}" || return 1
  python3 - "${local_cidr}" <<'PY' 2>/dev/null
import ipaddress, sys

cidr = sys.argv[1].strip()
iface = ipaddress.ip_interface(cidr)
net = iface.network
local = iface.ip

# /31,/32 无法可靠推断对端
if net.prefixlen >= 31:
    sys.exit(1)

first = net.network_address + 1
second = net.network_address + 2
candidate = first if first != local else second
if candidate == local:
    sys.exit(1)
print(f"{candidate}/32")
PY
}

_hk_read_raw() {
  local __var_name="$1"
  local __label="$2"
  local __default="${3-__HK_NO_DEFAULT__}"
  local __value=""
  if [[ "${__default}" == "__HK_NO_DEFAULT__" ]]; then
    printf "  %s: " "${__label}" >/dev/tty
    if ! read -r __value </dev/tty; then
      _hk_err "未检测到交互输入，请在终端直接运行脚本"
      return 1
    fi
  else
    printf "  %s [%s]: " "${__label}" "${__default}" >/dev/tty
    if ! read -r __value </dev/tty; then
      _hk_err "未检测到交互输入，请在终端直接运行脚本"
      return 1
    fi
    [[ -z "${__value}" ]] && __value="${__default}"
  fi
  printf -v "${__var_name}" '%s' "${__value}"
  return 0
}

_hk_read_required() {
  local __var_name="$1"
  local __label="$2"
  local __default="${3-__HK_NO_DEFAULT__}"
  local __value=""
  while true; do
    _hk_read_raw __value "${__label}" "${__default}" || return 1
    __value="$(_hk_trim "${__value}")"
    if [[ -n "${__value}" ]]; then
      printf -v "${__var_name}" '%s' "${__value}"
      return 0
    fi
    _hk_warn "该项不能为空，请重新输入"
  done
}

_hk_read_node_id() {
  local __default="${1-}"
  while true; do
    if [[ -n "${__default}" ]]; then
      _hk_read_required V2BX_NODE_ID "V2bX 节点 ID（纯数字）" "${__default}" || return 1
    else
      _hk_read_required V2BX_NODE_ID "V2bX 节点 ID（纯数字）" || return 1
    fi
    if [[ "${V2BX_NODE_ID}" =~ ^[0-9]+$ ]]; then
      return 0
    fi
    _hk_warn "节点 ID 只能是数字，请重新输入"
    __default=""
  done
}

_hk_confirm() {
  local prompt="$1"
  local default="${2:-N}"
  local ans=""
  while true; do
    if [[ "${default}" == "Y" ]]; then
      printf "  %s [Y/n]: " "${prompt}" >/dev/tty
      if ! read -r ans </dev/tty; then
        _hk_err "未检测到交互输入，请在终端直接运行脚本"
        return 1
      fi
      [[ -z "${ans}" ]] && ans="Y"
    else
      printf "  %s [y/N]: " "${prompt}" >/dev/tty
      if ! read -r ans </dev/tty; then
        _hk_err "未检测到交互输入，请在终端直接运行脚本"
        return 1
      fi
      [[ -z "${ans}" ]] && ans="N"
    fi
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) _hk_warn "请输入 y 或 n" ;;
    esac
  done
}

_hk_step_nav() {
  local prompt="${1:-继续下一步？}"
  local ans=""
  while true; do
    echo "  选项: Enter/y=继续, r=返回, q=退出" >/dev/tty
    printf "  %s: " "${prompt}" >/dev/tty
    if ! read -r ans </dev/tty; then
      echo
      _hk_warn "未检测到交互输入，默认继续"
      return 0
    fi
    ans="$(_hk_trim "${ans}")"
    case "${ans}" in
      ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Rr]|[Bb][Aa][Cc][Kk]|[Rr][Ee][Tt][Uu][Rr][Nn]) return 2 ;;
      [Qq]|[Qq][Uu][Ii][Tt]|[Ee][Xx][Ii][Tt]) return 3 ;;
      *) _hk_warn "请输入 Enter/y/r/q" ;;
    esac
  done
}

_hk_gate_after_step() {
  local prompt="$1"
  local rc=0
  _hk_step_nav "${prompt}" || rc=$?
  case "${rc}" in
    0) return 0 ;;
    2)
      _hk_info "按你的选择返回上级菜单"
      return 2
      ;;
    3)
      _hk_warn "按你的选择退出脚本"
      exit 0
      ;;
    *)
      return 1
      ;;
  esac
}

_hk_progress_bar() {
  local current="$1"
  local total="$2"
  local label="${3:-}"
  local width=28
  local percent=0
  local filled=0
  local bar=""
  if [[ "${total}" -gt 0 ]]; then
    percent=$(( current * 100 / total ))
  fi
  filled=$(( percent * width / 100 ))
  bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')"
  bar="${bar}$(printf '%*s' "$((width - filled))" '' | tr ' ' '-')"
  printf "\r  [%s] %3d%%  %s" "${bar}" "${percent}" "${label}"
  if [[ "${current}" -ge "${total}" ]]; then
    echo
  fi
}

_hk_run_with_spinner() {
  local desc="$1"
  shift
  local rc=0
  local tmp_log=""
  tmp_log="$(mktemp)"

  if [[ -t 1 ]]; then
    "$@" >"${tmp_log}" 2>&1 &
    local pid=$!
    local spin='|/-\'
    local i=0
    while kill -0 "${pid}" 2>/dev/null; do
      i=$(( (i + 1) % 4 ))
      printf "\r  %s %c" "${desc}" "${spin:${i}:1}"
      sleep 0.15
    done
    wait "${pid}" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
      printf "\r  %s ✓\n" "${desc}"
    else
      printf "\r  %s ✗\n" "${desc}"
    fi
  else
    _hk_info "${desc}"
    "$@" >"${tmp_log}" 2>&1 || rc=$?
  fi

  if [[ ${rc} -ne 0 ]]; then
    _hk_warn "${desc}失败（exit=${rc}），最近日志如下："
    sed -n '1,40p' "${tmp_log}" >&2
  fi
  rm -f "${tmp_log}"
  return "${rc}"
}

_hk_mask_secret() {
  local v="${1:-}"
  local n="${#v}"
  if [[ ${n} -eq 0 ]]; then
    printf '%s' "<empty>"
  elif [[ ${n} -le 8 ]]; then
    printf '%s' "已读取 (${n} chars)"
  else
    printf '%s' "${v:0:4}...${v: -4} (${n} chars)"
  fi
}

HK_STATE_DIR="/etc/hk-setup"

# ============================================================
# Banner（独立运行时显示）
# ============================================================
_hk_banner() {
  clear 2>/dev/null || true
  echo
  echo -e "${W}  ███████╗██╗  ██╗   ██╗████████╗ ██████╗ ${N}"
  echo -e "${W}  ██╔════╝██║  ╚██╗ ██╔╝╚══██╔══╝██╔═══██╗${N}"
  echo -e "${W}  █████╗  ██║   ╚████╔╝    ██║   ██║   ██║${N}"
  echo -e "${W}  ██╔══╝  ██║    ╚██╔╝     ██║   ██║   ██║${N}"
  echo -e "${W}  ██║     ███████╗██║      ██║   ╚██████╔╝${O}█╗${N}"
  echo -e "${W}  ╚═╝     ╚══════╝╚═╝      ╚═╝    ╚═════╝ ${O}╚╝${N}"
  echo
  echo -e "  ${O}▌${N} ${W}香港节点部署 HK Transit Setup${N}"
  echo -e "  ${O}▌${N} ${C}www.flytoex.com${N}"
  echo
}

# ============================================================
# 前置检查
# ============================================================
_check_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    _hk_err "请以 root 运行"
    exit 1
  fi
  return 0
}

_check_secrets() {
  if [[ -z "${PANEL_API_HOST:-}" || -z "${PANEL_API_KEY:-}" ]]; then
    _hk_err "PANEL_API_HOST / PANEL_API_KEY 未设置"
    _hk_err "请通过 flyto.sh 运行（自动解密），或手动 export 这两个变量"
    exit 1
  fi
}

# ============================================================
# 步骤一：基础系统配置
# ============================================================
_step_base_system() {
  _hk_step "步骤 1/6: 基础系统配置"

  export DEBIAN_FRONTEND=noninteractive
  _hk_info "正在更新软件源（可能需要 1-3 分钟，请耐心等待）..."
  _hk_info "进度提示：正在刷新软件源索引，请稍候..."
  _hk_run_with_spinner "软件源更新中" apt-get update -y || true

  _hk_info "正在安装依赖包（已启用进度条）..."
  local pkgs=(
    wireguard-tools nftables ipset curl ca-certificates dnsutils
    net-tools iptables iproute2 cron unzip openssl python3
  )
  local total="${#pkgs[@]}"
  local idx=0
  _hk_progress_bar 0 "${total}" "依赖安装准备中"
  for p in "${pkgs[@]}"; do
    idx=$((idx + 1))
    _hk_info "安装依赖 (${idx}/${total}): ${p}"
    _hk_run_with_spinner "安装 ${p}" apt-get install -y "${p}" || _hk_warn "跳过可选包: ${p}"
    _hk_progress_bar "${idx}" "${total}" "依赖安装进度"
  done
  _hk_ok "依赖安装完成"

  # 修复 lo 接口 127.0.0.1（部分云厂商镜像缺失）
  if ! ip addr show lo 2>/dev/null | grep -q '127.0.0.1'; then
    _hk_warn "lo 接口无 127.0.0.1，立即修复..."
    ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true
    ip link set lo up 2>/dev/null || true
    # 持久化
    cat > /etc/systemd/system/lo-127-fix.service <<'SVC'
[Unit]
Description=Fix lo 127.0.0.1 (cloud image quirk)
Before=network-pre.target
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/bin/sh -c "ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true; ip link set lo up"
[Install]
WantedBy=sysinit.target
SVC
    systemctl daemon-reload
    systemctl enable lo-127-fix.service >/dev/null 2>&1 || true
    _hk_ok "lo 修复服务已部署"
  fi

  # 禁用 IPv6
  cat > /etc/sysctl.d/99-no-ipv6.conf <<'CONF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
CONF

  # 开启 IPv4 转发
  cat > /etc/sysctl.d/99-forward.conf <<'CONF'
net.ipv4.ip_forward = 1
CONF

  sysctl --system >/dev/null 2>&1 || true

  # IPv4 优先（防止 DNS 返回 IPv6 导致泄露）
  grep -q 'precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null \
    || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

  # 禁用 systemd-resolved，锁定 resolv.conf
  systemctl stop systemd-resolved 2>/dev/null || true
  systemctl disable systemd-resolved 2>/dev/null || true
  systemctl mask systemd-resolved 2>/dev/null || true
  # 解锁后写入，再重新锁定
  if command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
  [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
  command -v chattr >/dev/null 2>&1 && chattr +i /etc/resolv.conf 2>/dev/null || true

  # 启用 nftables
  systemctl enable --now nftables >/dev/null 2>&1 || true

  _hk_ok "基础配置完成"
}

# ============================================================
# 步骤二：网络信息采集
# ============================================================
HK_WAN_IF="" HK_GW="" HK_PUB_IP=""

_step_collect_network() {
  _hk_step "步骤 2/6: 采集本机网络信息"

  # 若 wg0 在运行则暂停（避免探测到美国 IP）
  if ip link show wg0 >/dev/null 2>&1 && [[ "$(ip link show wg0 | grep -c 'UP')" -gt 0 ]]; then
    _hk_warn "检测到 wg0 运行中，暂停以获取本机网络信息..."
    systemctl stop wg-quick@wg0 2>/dev/null || true
  fi

  # 探测
  HK_WAN_IF="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  HK_GW="$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -1 || true)"
  HK_PUB_IP="$(curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null \
    || curl -4 -s --max-time 8 https://ip.sb 2>/dev/null || echo '')"

  _hk_card "网络信息确认" "可直接回车接受自动探测值，也可以手动覆盖"
  echo -e "  ${W}自动探测结果${N}"
  echo "    WAN 接口: ${HK_WAN_IF:-<未检测到>}"
  echo "    默认网关: ${HK_GW:-<未检测到>}"
  echo "    公网 IP : ${HK_PUB_IP:-<未检测到>}"
  echo

  if [[ -n "${HK_WAN_IF}" ]]; then
    _hk_read_required HK_WAN_IF "WAN 接口（如 eth0 / ens3）" "${HK_WAN_IF}" || return 1
  else
    _hk_read_required HK_WAN_IF "WAN 接口（如 eth0 / ens3）" || return 1
  fi
  if [[ -n "${HK_GW}" ]]; then
    _hk_read_required HK_GW "默认网关" "${HK_GW}" || return 1
  else
    _hk_read_required HK_GW "默认网关" || return 1
  fi
  if [[ -n "${HK_PUB_IP}" ]]; then
    _hk_read_required HK_PUB_IP "公网 IP（香港节点）" "${HK_PUB_IP}" || return 1
  else
    _hk_read_required HK_PUB_IP "公网 IP（香港节点）" || return 1
  fi

  # 保存
  mkdir -p "${HK_STATE_DIR}"
  echo "${HK_WAN_IF}" > "${HK_STATE_DIR}/wan_if"
  echo "${HK_GW}"     > "${HK_STATE_DIR}/gateway"
  echo "${HK_PUB_IP}" > "${HK_STATE_DIR}/pub_ip"

  echo
  _hk_ok "WAN: ${HK_WAN_IF}  GW: ${HK_GW}  PubIP: ${HK_PUB_IP}"
}

# ============================================================
# 步骤三：WireGuard 配置输入
# ============================================================
HK_PRIV_KEY="" HK_WG_ADDR="" US_PUB_KEY="" US_WG_ENDPOINT="" US_WG_TUN_IP=""
HK_PUB_KEY="" HK_WG_KEEPALIVE=25 V2BX_NODE_ID=""

_input_wg_fresh() {
  _hk_step "步骤 3/6: 输入 WireGuard 配置（全新安装）"
  while true; do
    _hk_card "WireGuard 参数录入（全新安装）" "可在美国节点执行 wg show 获取公钥与 endpoint"
    _hk_read_required HK_PRIV_KEY "香港节点 WG 私钥（PrivateKey）" || return 1
    _hk_read_required HK_WG_ADDR "香港节点 WG 隧道地址（如 10.0.0.3/32）" || return 1
    _hk_read_required US_PUB_KEY "美国节点 WG 公钥（Peer PublicKey）" || return 1
    _hk_read_required US_WG_ENDPOINT "美国节点 WG Endpoint（IP:端口）" || return 1
    _hk_read_required US_WG_TUN_IP "美国节点 WG 隧道 IP（如 10.0.0.1/32）" "10.0.0.1/32" || return 1
    _hk_read_node_id "${V2BX_NODE_ID:-}" || return 1
    _hk_read_required HK_WG_KEEPALIVE "WG PersistentKeepalive（秒）" "${HK_WG_KEEPALIVE:-25}" || return 1

    # 派生公钥
    HK_PUB_KEY="$(echo "${HK_PRIV_KEY}" | wg pubkey 2>/dev/null || true)"

    _hk_card "请确认录入信息"
    echo "    HK_PRIV_KEY    = $(_hk_mask_secret "${HK_PRIV_KEY}")"
    echo "    HK_WG_ADDR     = ${HK_WG_ADDR}"
    echo "    US_WG_PUBKEY   = ${US_PUB_KEY}"
    echo "    US_WG_ENDPOINT = ${US_WG_ENDPOINT}"
    echo "    US_WG_TUN_IP   = ${US_WG_TUN_IP}"
    echo "    KEEPALIVE      = ${HK_WG_KEEPALIVE}"
    echo "    V2BX_NODE_ID   = ${V2BX_NODE_ID}"
    echo
    echo "  你可以选择：继续部署 / 重新录入 / 退出脚本"
    local next_action=0
    _hk_step_nav "确认无误后继续部署？" || next_action=$?
    case "${next_action}" in
      0) return 0 ;;
      2) _hk_info "将重新录入 WireGuard 参数" ;;
      3) _hk_warn "按你的选择退出脚本"; exit 0 ;;
      *) _hk_warn "输入异常，默认返回重新录入" ;;
    esac
  done
}

_input_wg_restore() {
  _hk_step "步骤 3/6: 导入备份配置（恢复模式）"
  while true; do
    _hk_card "恢复向导：粘贴备份块" "支持包含 ## 分隔线。可用 END 行、连续两次空行或 Ctrl+D 结束"
    echo "  示例："
    echo "    HK_PRIV_KEY=xxxxxxxx"
    echo "    HK_WG_ADDR=10.0.0.3/32"
    echo "    HK_WG_PEER_PUBKEY=xxxxxxxx"
    echo "    HK_WG_ENDPOINT=5.6.7.8:51820"
    echo "    V2BX_NODE_ID=123"
    echo
    echo -e "  ${C}----- 开始粘贴（遇到 END FLYTO BACKUP 或 Ctrl+D 结束） -----${N}"

    local lines="" line="" read_any=0 end_seen=0 blank_count=0
    while IFS= read -r line </dev/tty; do
      line="${line%$'\r'}"
      line="$(_hk_strip_ansi "${line}")"
      if [[ "${line}" =~ END[[:space:]]+FLYTO[[:space:]]+BACKUP ]] || [[ "${line}" == "END" ]]; then
        end_seen=1
        break
      fi
      if [[ -z "${line//[[:space:]]/}" ]]; then
        blank_count=$((blank_count + 1))
        if [[ ${read_any} -eq 1 && ${blank_count} -ge 2 ]]; then
          break
        fi
        lines+=$'\n'
        continue
      fi
      blank_count=0
      lines+="${line}"$'\n'
      [[ -n "${line//[[:space:]]/}" ]] && read_any=1
    done
    echo -e "  ${C}----- 粘贴结束 -----${N}"
    echo

    if [[ ${read_any} -eq 0 || -z "${lines//[$' \t\r\n']/}" ]]; then
      _hk_warn "未读取到任何内容，请重新粘贴"
      continue
    fi
    [[ ${end_seen} -eq 0 ]] && _hk_warn "未检测到 END FLYTO BACKUP，已按当前内容尝试解析"

    HK_PRIV_KEY="" HK_PUB_KEY="" HK_WG_ADDR="" US_PUB_KEY="" US_WG_ENDPOINT=""
    HK_WAN_IF="" HK_GW="" HK_PUB_IP=""
    local parsed_keepalive="" parsed_node_id="" parsed_tun_ip=""
    local parsed_wan_if="" parsed_gw="" parsed_pub_ip=""
    local parsed_count=0
    local has_keepalive=0 has_tun_ip=0 has_node_id=0

    while IFS= read -r line; do
      line="${line%$'\r'}"
      line="$(_hk_strip_ansi "${line}")"
      [[ -z "${line}" ]] && continue
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue
      [[ "${line}" != *=* ]] && continue
      local k="${line%%=*}"
      local v="${line#*=}"
      k="$(_hk_trim "${k}")"
      v="$(_hk_trim "${v}")"
      k="${k#export }"
      k="$(_hk_trim "${k}")"
      if [[ "${v}" =~ ^\".*\"$ ]] || [[ "${v}" =~ ^\'.*\'$ ]]; then
        v="${v:1:${#v}-2}"
      fi
      [[ -z "${k}" ]] && continue
      case "${k}" in
        HK_PRIV_KEY)                    HK_PRIV_KEY="${v}"; parsed_count=$((parsed_count + 1)) ;;
        HK_PUB_KEY)                     HK_PUB_KEY="${v}"; parsed_count=$((parsed_count + 1)) ;;
        HK_WG_ADDR)                     HK_WG_ADDR="${v}"; parsed_count=$((parsed_count + 1)) ;;
        HK_WG_PEER_PUBKEY|US_PUB_KEY)   US_PUB_KEY="${v}"; parsed_count=$((parsed_count + 1)) ;;
        HK_WG_ENDPOINT)                 US_WG_ENDPOINT="${v}"; parsed_count=$((parsed_count + 1)) ;;
        HK_WG_KEEPALIVE)                parsed_keepalive="${v}"; has_keepalive=1; parsed_count=$((parsed_count + 1)) ;;
        US_WG_TUN_IP|US_WG_ADDR)        parsed_tun_ip="${v}"; has_tun_ip=1; parsed_count=$((parsed_count + 1)) ;;
        HK_WAN_IF)                      parsed_wan_if="${v}"; parsed_count=$((parsed_count + 1)) ;;
        HK_GW)                          parsed_gw="${v}"; parsed_count=$((parsed_count + 1)) ;;
        HK_PUB_IP)                      parsed_pub_ip="${v}"; parsed_count=$((parsed_count + 1)) ;;
        V2BX_NODE_ID|NODE_ID)           parsed_node_id="${v}"; has_node_id=1; parsed_count=$((parsed_count + 1)) ;;
      esac
    done <<< "${lines}"

    _hk_info "本次共识别到 ${parsed_count} 个字段"
    echo "    HK_PRIV_KEY     : $(_hk_mask_secret "${HK_PRIV_KEY}")"
    echo "    HK_WG_ADDR      : ${HK_WG_ADDR:-<空>}"
    echo "    HK_WG_PEER_PUBKEY: ${US_PUB_KEY:-<空>}"
    echo "    HK_WG_ENDPOINT  : ${US_WG_ENDPOINT:-<空>}"
    echo "    US_WG_TUN_IP    : ${parsed_tun_ip:-<空>}"
    echo "    HK_WG_KEEPALIVE : ${parsed_keepalive:-<空>}"
    echo "    V2BX_NODE_ID    : ${parsed_node_id:-<空>}"
    echo "    HK_WAN_IF       : ${parsed_wan_if:-<空>}"
    echo "    HK_GW           : ${parsed_gw:-<空>}"
    echo "    HK_PUB_IP       : ${parsed_pub_ip:-<空>}"
    echo

    local placeholder_fields=()
    if _hk_is_placeholder "${HK_PRIV_KEY}"; then
      HK_PRIV_KEY=""
      placeholder_fields+=("HK_PRIV_KEY")
    fi
    if _hk_is_placeholder "${HK_WG_ADDR}"; then
      HK_WG_ADDR=""
      placeholder_fields+=("HK_WG_ADDR")
    fi
    if _hk_is_placeholder "${US_PUB_KEY}"; then
      US_PUB_KEY=""
      placeholder_fields+=("HK_WG_PEER_PUBKEY/US_PUB_KEY")
    fi
    if _hk_is_placeholder "${US_WG_ENDPOINT}"; then
      US_WG_ENDPOINT=""
      placeholder_fields+=("HK_WG_ENDPOINT")
    fi

    [[ -n "${parsed_keepalive}" ]] && HK_WG_KEEPALIVE="${parsed_keepalive}"
    [[ -n "${parsed_tun_ip}" ]] && US_WG_TUN_IP="${parsed_tun_ip}"
    [[ -n "${parsed_wan_if}" ]] && HK_WAN_IF="${parsed_wan_if}"
    [[ -n "${parsed_gw}" ]] && HK_GW="${parsed_gw}"
    [[ -n "${parsed_pub_ip}" ]] && HK_PUB_IP="${parsed_pub_ip}"
    [[ -n "${parsed_node_id}" ]] && V2BX_NODE_ID="${parsed_node_id}"

    [[ -z "${HK_PUB_KEY}" ]] && HK_PUB_KEY="$(echo "${HK_PRIV_KEY}" | wg pubkey 2>/dev/null || true)"
    if _hk_is_placeholder "${HK_WG_KEEPALIVE}" || [[ ! "${HK_WG_KEEPALIVE}" =~ ^[0-9]+$ ]]; then
      HK_WG_KEEPALIVE="25"
    fi
    if _hk_is_placeholder "${US_WG_TUN_IP}" || [[ "${US_WG_TUN_IP}" == "/32" ]]; then
      US_WG_TUN_IP=""
    fi
    _hk_is_placeholder "${V2BX_NODE_ID}" && V2BX_NODE_ID=""

    if [[ ${#placeholder_fields[@]} -gt 0 ]]; then
      _hk_warn "检测到占位值字段（不是未识别）:"
      for f in "${placeholder_fields[@]}"; do
        echo "    - ${f}"
      done
      _hk_warn "请手动补全真实值，或返回上一步重新生成完整备份块"
      echo
    fi

    if [[ -z "${HK_PRIV_KEY}" ]]; then
      _hk_warn "HK_PRIV_KEY 为空或为占位值，请手动补全"
      _hk_read_required HK_PRIV_KEY "香港节点 WG 私钥（PrivateKey）" || return 1
    fi
    if [[ -z "${HK_WG_ADDR}" ]]; then
      _hk_warn "HK_WG_ADDR 为空或为占位值，请手动补全"
      _hk_read_required HK_WG_ADDR "香港节点 WG 隧道地址（如 10.0.0.3/32）" || return 1
    fi
    if [[ -z "${US_PUB_KEY}" ]]; then
      _hk_warn "HK_WG_PEER_PUBKEY 为空或为占位值，请手动补全"
      _hk_read_required US_PUB_KEY "美国节点 WG 公钥（Peer PublicKey）" || return 1
    fi
    if [[ -z "${US_WG_ENDPOINT}" ]]; then
      _hk_warn "HK_WG_ENDPOINT 为空或为占位值，请手动补全"
      _hk_read_required US_WG_ENDPOINT "美国节点 WG Endpoint（IP:端口）" || return 1
    fi

    local manual_fields=()
    local need_tun_input=0 need_keepalive_input=0 need_nodeid_input=0
    if [[ ${has_tun_ip} -eq 0 ]]; then
      need_tun_input=1
      manual_fields+=("US_WG_TUN_IP（缺失）")
    elif ! _hk_is_ipv4_cidr "${US_WG_TUN_IP}"; then
      need_tun_input=1
      manual_fields+=("US_WG_TUN_IP（格式非法: ${US_WG_TUN_IP:-<空>}）")
    fi
    if [[ ${has_keepalive} -eq 0 ]]; then
      _hk_warn "未提供 HK_WG_KEEPALIVE，已使用默认值 25"
    elif [[ ! "${HK_WG_KEEPALIVE}" =~ ^[0-9]+$ ]]; then
      need_keepalive_input=1
      manual_fields+=("HK_WG_KEEPALIVE（非数字）")
    fi
    if [[ ${has_node_id} -eq 0 ]] || [[ ! "${V2BX_NODE_ID}" =~ ^[0-9]+$ ]]; then
      need_nodeid_input=1
      manual_fields+=("V2BX_NODE_ID（缺失或非数字）")
    fi

    if [[ ${#manual_fields[@]} -gt 0 ]]; then
      _hk_warn "以下字段缺失或无效，下面将逐项提示输入（不是卡住）:"
      for f in "${manual_fields[@]}"; do
        echo "    - ${f}"
      done
      echo
    fi

    if [[ ${need_tun_input} -eq 1 ]]; then
      _hk_warn "US_WG_TUN_IP 需要手动确认（示例: 10.0.0.1/32）"
      while true; do
        _hk_read_required US_WG_TUN_IP "美国节点 WG 隧道 IP（如 10.0.0.1/32）" "${US_WG_TUN_IP:-10.0.0.1/32}" || return 1
        _hk_is_ipv4_cidr "${US_WG_TUN_IP}" && break
        _hk_warn "格式错误，请输入如 10.0.0.1/32"
      done
    fi

    if [[ ${need_keepalive_input} -eq 1 ]]; then
      _hk_warn "HK_WG_KEEPALIVE 非数字（当前: ${HK_WG_KEEPALIVE:-<空>}），请手动输入"
      _hk_read_required HK_WG_KEEPALIVE "WG PersistentKeepalive（秒）" "25" || return 1
    fi

    if [[ ${need_nodeid_input} -eq 1 ]]; then
      _hk_warn "V2BX_NODE_ID 非数字（当前: ${V2BX_NODE_ID:-<空>}），请手动输入"
      _hk_read_node_id "${V2BX_NODE_ID:-}" || return 1
    fi

    _hk_card "恢复参数确认"
    echo "    HK_PRIV_KEY    = $(_hk_mask_secret "${HK_PRIV_KEY}")"
    echo "    HK_WG_ADDR     = ${HK_WG_ADDR}"
    echo "    US_WG_PUBKEY   = ${US_PUB_KEY}"
    echo "    US_WG_ENDPOINT = ${US_WG_ENDPOINT}"
    echo "    US_WG_TUN_IP   = ${US_WG_TUN_IP}"
    echo "    KEEPALIVE      = ${HK_WG_KEEPALIVE}"
    echo "    V2BX_NODE_ID   = ${V2BX_NODE_ID}"
    if [[ -n "${HK_WAN_IF}" || -n "${HK_GW}" || -n "${HK_PUB_IP}" ]]; then
      echo
      echo "    网络信息（来自备份）"
      echo "    HK_WAN_IF      = ${HK_WAN_IF:-<空>}"
      echo "    HK_GW          = ${HK_GW:-<空>}"
      echo "    HK_PUB_IP      = ${HK_PUB_IP:-<空>}"
    fi
    echo
    echo "  你可以选择：继续恢复 / 重新粘贴备份 / 退出脚本"
    local next_action=0
    _hk_step_nav "确认无误后继续恢复部署？" || next_action=$?
    case "${next_action}" in
      0) return 0 ;;
      2) _hk_info "将重新进入恢复粘贴流程" ;;
      3) _hk_warn "按你的选择退出脚本"; exit 0 ;;
      *) _hk_warn "输入异常，默认返回重新粘贴" ;;
    esac
  done
}

# ============================================================
# 步骤四：生成 wg0.conf + 启动 + 三项验证
# ============================================================
_step_setup_wireguard() {
  _hk_step "步骤 4/6: 配置 WireGuard"

  # 从 endpoint 提取美国公网 IP
  local US_PUB_IP="${US_WG_ENDPOINT%%:*}"
  # 面板 IP
  local PANEL_IP
  PANEL_IP="$(dig +short "${PANEL_API_HOST#https://}" @8.8.8.8 2>/dev/null | tail -1 || true)"
  [[ -z "${PANEL_IP}" ]] && PANEL_IP="$(getent hosts "${PANEL_API_HOST#https://}" | awk '{print $1}' | head -1 || true)"
  [[ -z "${PANEL_IP}" ]] && { _hk_warn "无法解析面板 IP，跳过面板路由"; PANEL_IP=""; }

  local WG_DNS_LINE=""
  if command -v resolvconf >/dev/null 2>&1; then
    WG_DNS_LINE="DNS = 8.8.8.8"
  else
    _hk_warn "未检测到 resolvconf，wg0.conf 将不写 DNS（使用系统 /etc/resolv.conf）"
  fi

  mkdir -p /etc/wireguard

  # 生成 wg0.conf
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ${HK_PRIV_KEY}
Address = ${HK_WG_ADDR}
${WG_DNS_LINE}
Table = off

PostUp = grep -q '^100 eth0rt$' /etc/iproute2/rt_tables || echo '100 eth0rt' >> /etc/iproute2/rt_tables
PostUp = ip route replace default via ${HK_GW} dev ${HK_WAN_IF} table eth0rt
PostUp = ip rule del pref 100 from ${HK_PUB_IP}/32 lookup eth0rt 2>/dev/null || true
PostUp = ip rule add pref 100 from ${HK_PUB_IP}/32 lookup eth0rt
PostUp = ip route replace ${US_PUB_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}
$([ -n "${PANEL_IP}" ] && echo "PostUp = ip route replace ${PANEL_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}" || true)
PostUp = ip route replace ${US_WG_TUN_IP%%/*}/32 dev wg0
PostUp = ip route replace default dev wg0

PostDown = ip route replace default via ${HK_GW} dev ${HK_WAN_IF} onlink
PostDown = ip route del ${US_WG_TUN_IP%%/*}/32 dev wg0 2>/dev/null || true
$([ -n "${PANEL_IP}" ] && echo "PostDown = ip route del ${PANEL_IP}/32 via ${HK_GW} dev ${HK_WAN_IF} 2>/dev/null || true" || true)
PostDown = ip route del ${US_PUB_IP}/32 via ${HK_GW} dev ${HK_WAN_IF} 2>/dev/null || true
PostDown = ip rule del pref 100 from ${HK_PUB_IP}/32 lookup eth0rt 2>/dev/null || true
PostDown = ip route flush table eth0rt 2>/dev/null || true

[Peer]
PublicKey = ${US_PUB_KEY}
Endpoint = ${US_WG_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${HK_WG_KEEPALIVE}
EOF

  chmod 600 /etc/wireguard/wg0.conf

  # 保存面板 IP
  mkdir -p "${HK_STATE_DIR}"
  echo "${US_WG_TUN_IP}" > "${HK_STATE_DIR}/us_wg_tun_ip"
  if [[ -n "${PANEL_IP}" ]]; then
    echo "${PANEL_IP}" > "${HK_STATE_DIR}/panel_ip"
    # hosts
    local panel_host="${PANEL_API_HOST#https://}"
    grep -v "${panel_host}" /etc/hosts > /tmp/hosts.tmp && mv /tmp/hosts.tmp /etc/hosts || true
    echo "${PANEL_IP}  ${panel_host}" >> /etc/hosts
  fi

  # 启动 WireGuard
  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl stop wg-quick@wg0 2>/dev/null || true
  wg-quick down wg0 2>/dev/null || true
  sleep 1
  if ! systemctl start wg-quick@wg0; then
    _hk_err "wg-quick@wg0 启动失败，已中止"
    journalctl -u wg-quick@wg0 -n 30 --no-pager 2>/dev/null || true
    exit 1
  fi
  sleep 3
  if ! systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    _hk_err "wg-quick@wg0 未处于 active 状态，已中止"
    systemctl status wg-quick@wg0 --no-pager -l 2>/dev/null | sed -n '1,40p' || true
    journalctl -u wg-quick@wg0 -n 40 --no-pager 2>/dev/null || true
    exit 1
  fi

  # 三项验证
  _hk_step "步骤 4b: WireGuard 三项验证"
  local ok=1

  echo "--- [1] WG 握手时间 ---"
  local hs; hs="$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || echo 0)"
  local now; now="$(date +%s)"
  if [[ -n "${hs}" && "${hs}" -gt 0 && $(( now - hs )) -lt 300 ]]; then
    echo -e "  ${G}✓ 握手 $(( now - hs ))s 前${N}"
  else
    echo -e "  ${R}✗ 无握手或握手超时${N}"; ok=0
  fi

  echo "--- [2] 出口 IP 地区 ---"
  local exit_ip=""
  local exit_probe_mode="wg0"
  exit_ip="$(curl -4 -s --max-time 10 --interface wg0 https://ifconfig.io 2>/dev/null || true)"
  if [[ -z "${exit_ip}" ]]; then
    exit_probe_mode="default-route"
    exit_ip="$(curl -4 -s --max-time 10 https://ifconfig.io 2>/dev/null || true)"
  fi
  local exit_country; exit_country="$(curl -s --max-time 8 "https://ipinfo.io/${exit_ip}/country" 2>/dev/null || echo '')"
  local default_route; default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
  local default_dev; default_dev="$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i==\"dev\"){print $(i+1); exit}}' || true)"
  echo "  出口 IP: ${exit_ip}  地区: ${exit_country}"
  echo "  探测方式: ${exit_probe_mode}"
  echo "  默认路由: ${default_route:-<空>}"
  if [[ "${default_dev}" != "wg0" ]]; then
    echo -e "  ${Y}! 当前默认路由并非 wg0（dev=${default_dev:-<空>}）${N}"
  fi
  if [[ "${exit_country}" == "US" ]]; then
    echo -e "  ${G}✓ 出口为美国${N}"
  else
    echo -e "  ${R}✗ 出口非美国 (${exit_country})${N}"; ok=0
    if [[ -n "${HK_PUB_IP}" && "${exit_ip}" == "${HK_PUB_IP}" ]]; then
      echo -e "  ${Y}! 当前出口与香港公网 IP 一致，说明 wg0 未生效（仍本地直出）${N}"
    fi
  fi

  echo "--- [3] 回包路径 ---"
  local rt_dev; rt_dev="$(ip route get 8.8.8.8 from "${HK_PUB_IP}" 2>/dev/null | grep -oP 'dev \K\S+' || echo '')"
  if [[ "${rt_dev}" == "${HK_WAN_IF}" ]]; then
    echo -e "  ${G}✓ 回包走 ${HK_WAN_IF}（正确）${N}"
  else
    echo -e "  ${R}✗ 回包走 ${rt_dev:-?}（应为 ${HK_WAN_IF}）${N}"; ok=0
  fi

  if [[ ${ok} -eq 0 ]]; then
    _hk_err "WireGuard 验证未通过，请检查配置后重试"
    echo -e "  ${Y}排查提示:${N}"
    echo "  1. 检查美国节点是否在线: ping ${US_PUB_IP}"
    echo "  2. 检查 WG Endpoint 路由: ip route get ${US_PUB_IP}"
    echo "  3. 查看 WG 日志: journalctl -u wg-quick@wg0 -n 30"
    echo
    echo "--- [附加诊断] wg show (root) ---"
    wg show 2>/dev/null || true
    if command -v ip >/dev/null 2>&1 && ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "sb-ns"; then
      echo "--- [附加诊断] wg show (sb-ns) ---"
      ip netns exec sb-ns wg show 2>/dev/null || true
    fi
    echo "--- [附加诊断] 默认路由 ---"
    ip -4 route show default 2>/dev/null || true
    echo "--- [附加诊断] Endpoint 路由 ---"
    ip -4 route get "${US_PUB_IP}" 2>/dev/null || true
    exit 1
  fi
  _hk_ok "WireGuard 三项验证通过"
}

# ============================================================
# 步骤五：V2bX 安装
# ============================================================
_write_ai_warp_route_sync_script() {
  cat > /usr/local/bin/update-ai-warp-route.sh <<'SCRIPT'
#!/usr/bin/env bash
# update-ai-warp-route.sh — sync OpenAI/Claude routes to WARP for V2bX sing-box
set -euo pipefail

ENV_FILE="/etc/warp-google/env"
V2BX_SING_ORIGIN="/etc/V2bX/sing_origin.json"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}" || true
fi
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[AI-ROUTE] python3 未安装，无法更新 ${V2BX_SING_ORIGIN}" >&2
  exit 1
fi

tmp_rules="$(mktemp)"
tmp_conf="$(mktemp)"
cleanup() { rm -f "${tmp_rules}" "${tmp_conf}"; }
trap cleanup EXIT

python3 > "${tmp_rules}" <<'PYRULE'
import json
import urllib.request

SOURCES = [
    ("meta", "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/openai.yaml"),
    ("meta", "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/anthropic.yaml"),
    ("v2fly", "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/openai"),
    ("v2fly", "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/anthropic"),
]

FALLBACK_SUFFIX = [
    "openaiapi-site.azureedge.net",
    "openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net",
    "openaicom.imgix.net",
    "openaicomproductionae4b.blob.core.windows.net",
    "production-openaicom-storage.azureedge.net",
    "chat.com",
    "chatgpt.com",
    "crixet.com",
    "oaistatic.com",
    "oaiusercontent.com",
    "openai.com",
    "sora.com",
    "chatgpt.livekit.cloud",
    "host.livekit.cloud",
    "turn.livekit.cloud",
    "openai.com.cdn.cloudflare.net",
    "o33249.ingest.sentry.io",
    "browser-intake-datadoghq.com",
    "servd-anthropic-website.b-cdn.net",
    "anthropic.com",
    "clau.de",
    "claude.ai",
    "claude.com",
    "claudemcpclient.com",
    "claudeusercontent.com",
]

FALLBACK_REGEX = [
    r"^chatgpt-async-webps-prod-\S+-\d+\.webpubsub\.azure\.com$",
]


def parse_lines(style: str, text: str):
    parsed = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if style == "meta":
            if line == "payload:":
                continue
            if line.startswith("- "):
                line = line[2:].strip()
        line = line.split(" @", 1)[0].strip()
        if not line:
            continue
        if line.startswith("full:"):
            parsed.append(("full", line[5:].strip()))
        elif line.startswith("regexp:"):
            parsed.append(("regex", line[7:].strip()))
        elif line.startswith("+."):
            parsed.append(("suffix", line[2:].strip()))
        else:
            parsed.append(("suffix", line))
    return parsed


suffix = set()
full = set()
regex = set()

for style, url in SOURCES:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "flyto-network/2.0"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            text = resp.read().decode("utf-8", "ignore")
        for typ, value in parse_lines(style, text):
            if not value:
                continue
            if typ == "suffix":
                suffix.add(value.lower())
            elif typ == "full":
                full.add(value.lower())
            elif typ == "regex":
                regex.add(value)
    except Exception:
        continue

for item in FALLBACK_SUFFIX:
    suffix.add(item.lower())
for item in FALLBACK_REGEX:
    regex.add(item)

# domain_suffix already covers exact match, keep full list minimal.
full = {x for x in full if x not in suffix}

result = {
    "domain_suffix": sorted(suffix),
    "domain": sorted(full),
    "domain_regex": sorted(regex),
}
print(json.dumps(result, ensure_ascii=True))
PYRULE

WARP_PROXY_PORT="${WARP_PROXY_PORT}" TMP_RULES="${tmp_rules}" python3 > "${tmp_conf}" <<'PYCONF'
import json
import os

port = int(os.environ.get("WARP_PROXY_PORT", "40000"))
rules = json.load(open(os.environ["TMP_RULES"], "r", encoding="utf-8"))

route_rules = [
    {"ip_is_private": True, "outbound": "block"},
]

if rules.get("domain_suffix"):
    route_rules.append({"domain_suffix": rules["domain_suffix"], "outbound": "warp-ai"})
if rules.get("domain"):
    route_rules.append({"domain": rules["domain"], "outbound": "warp-ai"})
if rules.get("domain_regex"):
    route_rules.append({"domain_regex": rules["domain_regex"], "outbound": "warp-ai"})

config = {
    "dns": {
        "servers": [
            {"address": "8.8.8.8", "strategy": "ipv4_only"},
            {"address": "1.1.1.1", "strategy": "ipv4_only"},
        ]
    },
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
        {
            "type": "socks",
            "tag": "warp-ai",
            "server": "127.0.0.1",
            "server_port": port,
        },
    ],
    "route": {
        "rules": route_rules,
        "final": "direct",
    },
}

print(json.dumps(config, indent=2, ensure_ascii=True))
PYCONF

install -m 0644 "${tmp_conf}" "${V2BX_SING_ORIGIN}"

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart V2bX >/dev/null 2>&1 || true
fi

echo "[AI-ROUTE] 已更新 ${V2BX_SING_ORIGIN} (WARP_PROXY_PORT=${WARP_PROXY_PORT})"
SCRIPT
  chmod +x /usr/local/bin/update-ai-warp-route.sh
}

_step_install_v2bx() {
  _hk_step "步骤 5/6: 安装 V2bX"

  _hk_info "下载 V2bX 安装脚本..."
  local install_sh; install_sh="$(mktemp)"
  curl -fL --progress-bar https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh \
    -o "${install_sh}" || { _hk_err "V2bX 安装脚本下载失败"; return 1; }
  chmod +x "${install_sh}"

  echo
  echo -e "  ${Y}V2bX 安装器即将启动。请在菜单中选择 [1] 安装，完成后返回。${N}"
  echo
  bash "${install_sh}"
  rm -f "${install_sh}"

  # 覆盖配置文件
  mkdir -p /etc/V2bX

  cat > /etc/V2bX/config.json <<EOF
{
  "Log": {
    "Level": "info",
    "Output": ""
  },
  "Cores": [
    {
      "Type": "sing",
      "Log": {
        "Level": "info",
        "Timestamp": true
      },
      "OriginalPath": "/etc/V2bX/sing_origin.json"
    }
  ],
  "Nodes": [
    {
      "Core": "sing",
      "ApiHost": "${PANEL_API_HOST}",
      "ApiKey": "${PANEL_API_KEY}",
      "NodeID": ${V2BX_NODE_ID},
      "NodeType": "vless",
      "Timeout": 30,
      "ListenIP": "0.0.0.0",
      "SendIP": "0.0.0.0",
      "TCPFastOpen": true,
      "SniffEnabled": true
    }
  ]
}
EOF

  cat > /etc/V2bX/config.yml <<EOF
Log:
  Level: error
  AccessPath: /etc/V2bX/access.log
  ErrorPath: /etc/V2bX/error.log

Nodes:
  - PanelType: V2board
    ApiConfig:
      ApiHost: ${PANEL_API_HOST}
      ApiKey: ${PANEL_API_KEY}
      NodeID: ${V2BX_NODE_ID}
      NodeType: vless
      Timeout: 30
      EnableVless: true
      SpeedLimit: 0
      DeviceLimit: 0
    ControllerConfig:
      ListenIP: 0.0.0.0
      SendIP: 0.0.0.0
      UpdatePeriodic: 60
      EnableDNS: false
      CertConfig:
        CertMode: none
      EnableFallback: false
      SniffEnabled: false
EOF

  # sing-box 路由配置（OpenAI / Claude 域名走 WARP）
  _write_ai_warp_route_sync_script
  if /usr/local/bin/update-ai-warp-route.sh >/dev/null 2>&1; then
    _hk_ok "sing-box 路由已生成（OpenAI / Claude -> WARP）"
  else
    _hk_warn "AI 路由生成失败，回退为基础 direct 配置"
    cat > /etc/V2bX/sing_origin.json <<'EOF'
{
  "dns": {
    "servers": [
      {"address": "8.8.8.8", "strategy": "ipv4_only"},
      {"address": "1.1.1.1", "strategy": "ipv4_only"}
    ]
  },
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ],
  "route": {
    "rules": [
      {"ip_is_private": true, "outbound": "block"}
    ],
    "final": "direct"
  }
}
EOF
  fi

  systemctl restart V2bX >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet V2bX 2>/dev/null; then
    _hk_ok "V2bX 已启动"
  else
    _hk_warn "V2bX 可能启动失败，请检查: journalctl -u V2bX -n 30"
  fi
}

# ============================================================
# 步骤六：面板 IP 监控 cron
# ============================================================
_step_panel_ip_monitor() {
  _hk_step "步骤 6/6: 部署面板 IP 监控"

  local panel_host="${PANEL_API_HOST#https://}"

  cat > /usr/local/bin/update-panel-route.sh <<MONITOR
#!/usr/bin/env bash
# update-panel-route.sh — FLYTOex Network www.flytoex.com
# 监控面板域名 IP 变化，自动更新路由和 /etc/hosts
PANEL_HOST="${panel_host}"
STATE_FILE="${HK_STATE_DIR}/panel_ip"
LOG_FILE="/var/log/update-panel-route.log"
GW="\$(ip route show default dev "\$(ip -o -4 route show to default | awk '{print \$5}' | head -1)" \
    table eth0rt 2>/dev/null | awk '{print \$3}' | head -1 || ip route show default | awk '{print \$3}' | head -1)"
WAN_IF="\$(cat "${HK_STATE_DIR}/wan_if" 2>/dev/null || ip -o -4 route show to default | awk '{print \$5}' | head -1)"

new_ip="\$(dig +short "\${PANEL_HOST}" @8.8.8.8 2>/dev/null | tail -1 || true)"
[[ -z "\${new_ip}" ]] && exit 0

old_ip="\$(cat "\${STATE_FILE}" 2>/dev/null || true)"
[[ "\${new_ip}" == "\${old_ip}" ]] && exit 0

# IP 已变更
echo "\$(date '+%Y-%m-%d %H:%M:%S') IP 变更: \${old_ip} -> \${new_ip}" >> "\${LOG_FILE}"

[[ -n "\${old_ip}" ]] && ip route del "\${old_ip}/32" 2>/dev/null || true
ip route add "\${new_ip}/32" via "\${GW}" dev "\${WAN_IF}" 2>/dev/null || true

# 更新 hosts
sed -i "/\${PANEL_HOST}/d" /etc/hosts
echo "\${new_ip}  \${PANEL_HOST}" >> /etc/hosts

echo "\${new_ip}" > "\${STATE_FILE}"
systemctl restart V2bX >/dev/null 2>&1 || true
echo "\$(date '+%Y-%m-%d %H:%M:%S') 路由已更新" >> "\${LOG_FILE}"
MONITOR
  chmod +x /usr/local/bin/update-panel-route.sh

  # cron — 每小时第 5 分钟执行
  (crontab -l 2>/dev/null | grep -v 'update-panel-route'; \
   echo "5 * * * * /usr/local/bin/update-panel-route.sh") | crontab -

  _hk_ok "面板 IP 监控已配置 (每小时 :05 检测)"
}

# ============================================================
# 可选步骤：WARP 安装
# ============================================================
_step_optional_warp() {
  _hk_card "可选步骤：安装 WARP" "安装后可直接访问 Google / Gemini 与 AI 相关流量（按路由策略）"
  if _hk_confirm "是否现在安装 WARP？" "N"; then
    # 加载 warp 模块（如果未加载）
    if ! command -v warp_do_install >/dev/null 2>&1; then
      local warp_mod
      warp_mod="$(dirname "${BASH_SOURCE[0]}")/warp.sh"
      if [[ -f "${warp_mod}" ]]; then
        # shellcheck disable=SC1090
        source "${warp_mod}"
      else
        _hk_warn "未找到 warp.sh 模块，跳过 WARP 安装"
        _hk_warn "事后可运行: flyto.sh warp install"
        return
      fi
    fi
    warp_do_install
  else
    echo -e "  ${D}已跳过。事后可通过 flyto.sh → WARP 管理 安装${N}"
  fi
}

# ============================================================
# 部署摘要
# ============================================================
_print_deploy_summary() {
  echo
  echo -e "${G}╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "${G}║  ✓  香港节点部署完成 — FLYTOex Network                  ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}"
  echo
  echo -e "  ${W}WireGuard${N}   wg0  →  ${US_WG_ENDPOINT%%:*} (US)"
  echo -e "  ${W}V2bX${N}        节点 ID: ${V2BX_NODE_ID:-?}  |  面板: ${PANEL_API_HOST}"
  echo -e "  ${W}出口 IP${N}     $(curl -4 -s --max-time 6 https://ifconfig.io 2>/dev/null || echo '?')"
  echo
  echo -e "  ${C}常用命令:${N}"
  echo "  wg show                        WireGuard 状态"
  echo "  v2bx status                    V2bX 状态"
  echo "  /usr/local/bin/update-panel-route.sh  手动更新面板路由"
  echo "  tail -20 /var/log/update-panel-route.log  面板 IP 日志"
  command -v warp >/dev/null 2>&1 && echo "  warp status                    WARP 状态"
  echo
  echo -e "  ${D}www.flytoex.com${N}"
  echo
}

# ============================================================
# 备份模式
# ============================================================
hk_run_backup() {
  _hk_step "备份模式 — 保存 WireGuard 配置"

  # 停止 wg0 以获取本机真实 IP
  local wg_was_up=0
  if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    _hk_warn "暂停 wg0 获取本机网络信息..."
    systemctl stop wg-quick@wg0; wg_was_up=1; sleep 1
  fi

  local priv="" pub="" addr="" peer_pub="" endpoint="" us_tun_ip="" keepalive="" node_id=""
  local wan_if="" gw="" pub_ip=""
  local wg_conf="" wg_tmp="" wg_source=""
  local wg_ns="" wg_iface="wg0"

  # 优先探测 netns 场景（例如 V2bX/sing-box 把 wg 放在 sb-ns）
  if command -v ip >/dev/null 2>&1 && command -v wg >/dev/null 2>&1; then
    if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "sb-ns"; then
      local sb_ifaces=""
      sb_ifaces="$(ip netns exec sb-ns wg show interfaces 2>/dev/null || true)"
      if [[ -n "${sb_ifaces//[[:space:]]/}" ]]; then
        wg_ns="sb-ns"
        wg_iface="$(awk '{print $1}' <<< "${sb_ifaces}")"
      fi
    fi

    if [[ -z "${wg_ns}" ]]; then
      local ns="" ns_ifaces=""
      while IFS= read -r ns; do
        [[ -z "${ns}" ]] && continue
        ns_ifaces="$(ip netns exec "${ns}" wg show interfaces 2>/dev/null || true)"
        if [[ -n "${ns_ifaces//[[:space:]]/}" ]]; then
          wg_ns="${ns}"
          wg_iface="$(awk '{print $1}' <<< "${ns_ifaces}")"
          break
        fi
      done < <(ip netns list 2>/dev/null | awk '{print $1}')
    fi
  fi

  if [[ -n "${wg_ns}" ]]; then
    wg_tmp="$(mktemp)"
    if ip netns exec "${wg_ns}" wg showconf "${wg_iface}" > "${wg_tmp}" 2>/dev/null; then
      wg_conf="${wg_tmp}"
      wg_source="netns ${wg_ns}/${wg_iface}"
      _hk_info "检测到 WireGuard 运行在 ${wg_source}，将从该命名空间提取备份"
    else
      rm -f "${wg_tmp}"
      wg_tmp=""
    fi
  fi

  if [[ -z "${wg_conf}" ]]; then
    for p in /etc/wireguard/wg0.conf /usr/local/etc/wireguard/wg0.conf; do
      if [[ -f "${p}" ]]; then
        wg_conf="${p}"
        wg_source="${p}"
        break
      fi
    done
  fi

  if [[ -z "${wg_conf}" ]] && command -v wg >/dev/null 2>&1; then
    wg_tmp="$(mktemp)"
    if wg showconf wg0 > "${wg_tmp}" 2>/dev/null; then
      wg_conf="${wg_tmp}"
      wg_source="root namespace wg0(runtime)"
      _hk_info "未找到本地 wg0.conf，已从运行中的 wg 接口导出配置用于备份"
    else
      rm -f "${wg_tmp}"
      wg_tmp=""
    fi
  fi

  if [[ -n "${wg_conf}" ]]; then
    _hk_info "从 ${wg_source:-${wg_conf}} 提取 WireGuard 参数..."
    priv="$(
      sed -nE 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | head -1
    )"
    addr="$(
      sed -nE 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | head -1
    )"
    peer_pub="$(
      sed -nE 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | tail -1
    )"
    endpoint="$(
      sed -nE 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | head -1
    )"
    keepalive="$(
      sed -nE 's/^[[:space:]]*PersistentKeepalive[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${wg_conf}" | head -1
    )"
    us_tun_ip="$(
      sed -nE 's/.*ip route replace[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+)[[:space:]]+dev[[:space:]]+wg0.*/\1/p' "${wg_conf}" | head -1
    )"
  else
    _hk_warn "未找到 wg0.conf，尝试从运行状态读取可用字段"
  fi

  if [[ -z "${peer_pub}" ]] && command -v wg >/dev/null 2>&1; then
    if [[ -n "${wg_ns}" ]]; then
      peer_pub="$(ip netns exec "${wg_ns}" wg show "${wg_iface}" peers 2>/dev/null | head -1 || true)"
    else
      peer_pub="$(wg show wg0 peers 2>/dev/null | head -1 || true)"
    fi
  fi
  if [[ -z "${endpoint}" ]] && command -v wg >/dev/null 2>&1; then
    if [[ -n "${wg_ns}" ]]; then
      endpoint="$(ip netns exec "${wg_ns}" wg show "${wg_iface}" endpoints 2>/dev/null | awk 'NR==1{print $2}' || true)"
    else
      endpoint="$(wg show wg0 endpoints 2>/dev/null | awk 'NR==1{print $2}' || true)"
    fi
  fi
  if [[ -z "${keepalive}" ]] && command -v wg >/dev/null 2>&1; then
    if [[ -n "${wg_ns}" ]]; then
      keepalive="$(ip netns exec "${wg_ns}" wg show "${wg_iface}" dump 2>/dev/null | awk 'NR==2{print $9}' || true)"
    else
      keepalive="$(wg show wg0 dump 2>/dev/null | awk 'NR==2{print $9}' || true)"
    fi
  fi
  if [[ -z "${addr}" ]]; then
    if [[ -n "${wg_ns}" ]]; then
      addr="$(ip netns exec "${wg_ns}" ip -o -4 addr show dev "${wg_iface}" scope global 2>/dev/null | awk 'NR==1{print $4}' || true)"
    else
      addr="$(ip -o -4 addr show dev wg0 scope global 2>/dev/null | awk 'NR==1{print $4}' || true)"
    fi
  fi
  if [[ -z "${us_tun_ip}" ]]; then
    if [[ -n "${wg_ns}" ]]; then
      us_tun_ip="$(
        ip netns exec "${wg_ns}" ip -4 route show dev "${wg_iface}" 2>/dev/null \
          | awk '$1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}\/32$/ {print $1; exit}' \
          | head -1 || true
      )"
    else
      us_tun_ip="$(
        ip -4 route show dev wg0 2>/dev/null \
          | awk '$1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}\/32$/ {print $1; exit}' \
          | head -1 || true
      )"
    fi
  fi

  # 回退 1：历史状态（之前部署时保存）
  if [[ -z "${us_tun_ip}" && -s "${HK_STATE_DIR}/us_wg_tun_ip" ]]; then
    local saved_tun=""
    saved_tun="$(_hk_trim "$(cat "${HK_STATE_DIR}/us_wg_tun_ip" 2>/dev/null || true)")"
    if _hk_is_ipv4_cidr "${saved_tun}"; then
      us_tun_ip="${saved_tun}"
      _hk_info "US_WG_TUN_IP 来自历史状态: ${us_tun_ip}"
    fi
  fi

  # 回退 2：依据本地隧道地址推断（例如本地 10.0.0.2/24 -> 对端 10.0.0.1/32）
  if [[ -z "${us_tun_ip}" && -n "${addr}" ]]; then
    local guessed_tun=""
    guessed_tun="$(_hk_guess_peer_tun_ip_from_local "${addr}" || true)"
    if _hk_is_ipv4_cidr "${guessed_tun}"; then
      us_tun_ip="${guessed_tun}"
      _hk_warn "未直接识别到 US_WG_TUN_IP，已按 ${addr} 推测为 ${us_tun_ip}（请核对）"
    fi
  fi

  [[ -n "${priv}" ]] && pub="$(echo "${priv}" | wg pubkey 2>/dev/null || true)"
  [[ -n "${wg_tmp}" ]] && rm -f "${wg_tmp}"
  if [[ ! "${keepalive}" =~ ^[0-9]+$ ]]; then
    keepalive="25"
  fi
  [[ -z "${keepalive}" ]] && keepalive="25"
  # 优先读取 config.json（当前主流），再回退 config.yml
  node_id="$(
    sed -nE 's/.*"(NodeID|nodeId|node_id)"[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*/\2/p' /etc/V2bX/config.json 2>/dev/null | head -1
  )"
  if [[ -z "${node_id}" ]]; then
    node_id="$(
      sed -nE 's/.*"(NodeID|nodeId|node_id)"[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*/\2/p' /usr/local/etc/V2bX/config.json 2>/dev/null | head -1
    )"
  fi
  if [[ -z "${node_id}" ]]; then
    node_id="$(
      sed -nE 's/^[[:space:]]*NodeID:[[:space:]]*([0-9]+).*$/\1/p' /etc/V2bX/config.yml 2>/dev/null | head -1
    )"
  fi
  if [[ -z "${node_id}" ]]; then
    node_id="$(
      sed -nE 's/^[[:space:]]*NodeID:[[:space:]]*([0-9]+).*$/\1/p' /usr/local/etc/V2bX/config.yml 2>/dev/null | head -1
    )"
  fi
  if [[ -z "${node_id}" ]]; then
    _hk_warn "未自动识别到 V2bX Node ID，备份中将写入占位值，请手动补全"
    node_id="REPLACE_WITH_NODE_ID"
  fi

  if _hk_is_placeholder "${priv}"; then
    _hk_warn "未读取到 HK_PRIV_KEY，备份中写入占位值"
    priv="REPLACE_WITH_HK_PRIV_KEY"
  fi
  if _hk_is_placeholder "${addr}"; then
    _hk_warn "未读取到 HK_WG_ADDR，备份中写入占位值"
    addr="REPLACE_WITH_HK_WG_ADDR"
  fi
  if _hk_is_placeholder "${peer_pub}"; then
    _hk_warn "未读取到 HK_WG_PEER_PUBKEY，备份中写入占位值"
    peer_pub="REPLACE_WITH_HK_WG_PEER_PUBKEY"
  fi
  if _hk_is_placeholder "${endpoint}"; then
    _hk_warn "未读取到 HK_WG_ENDPOINT，备份中写入占位值"
    endpoint="REPLACE_WITH_HK_WG_ENDPOINT"
  fi
  if _hk_is_placeholder "${us_tun_ip}" || [[ "${us_tun_ip}" == "/32" ]]; then
    _hk_warn "未读取到 US_WG_TUN_IP，备份中写入占位值"
    _hk_warn "已尝试来源：wg0.conf / wg showconf / 路由 / 历史状态缓存"
    _hk_warn "可手动执行以下命令确认后再填入恢复块："
    if [[ -n "${wg_ns}" ]]; then
      echo "    ip netns exec ${wg_ns} ip -4 route show dev ${wg_iface}"
      echo "    ip netns exec ${wg_ns} ip -o -4 addr show dev ${wg_iface}"
    else
      echo "    ip -4 route show dev wg0"
      echo "    ip -o -4 addr show dev wg0"
    fi
    us_tun_ip="REPLACE_WITH_US_WG_TUN_IP"
  fi

  wan_if="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)"
  gw="$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -1)"
  pub_ip="$(curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null || true)"

  echo
  echo -e "  ${Y}╔════════════════════════════════════════════════════════════╗${N}"
  echo -e "  ${Y}║${N} ${W}备份复制区（请从 BEGIN 到 END 整块复制）${N}"
  echo -e "  ${Y}╚════════════════════════════════════════════════════════════╝${N}"
  echo "########## BEGIN FLYTO BACKUP ##########"
  echo "HK_PRIV_KEY=${priv}"
  echo "HK_PUB_KEY=${pub}"
  echo "HK_WG_ADDR=${addr}"
  echo "HK_WG_PEER_PUBKEY=${peer_pub}"
  echo "HK_WG_ENDPOINT=${endpoint}"
  echo "HK_WG_ALLOWED_IPS=0.0.0.0/0"
  echo "HK_WG_KEEPALIVE=${keepalive}"
  echo "US_WG_TUN_IP=${us_tun_ip}"
  echo "HK_WAN_IF=${wan_if}"
  echo "HK_GW=${gw}"
  echo "HK_PUB_IP=${pub_ip}"
  echo "V2BX_NODE_ID=${node_id}"
  echo "########### END FLYTO BACKUP ###########"
  echo

  _hk_warn "私钥（HK_PRIV_KEY）极度敏感，请保存在本地加密存储中"
  _hk_warn "不要通过聊天/邮件/截图传输"
  echo
  echo -e "  ${Y}请完整复制上方备份信息并确认保存后再继续。${N}"
  echo -e "  ${D}输入 y: 已保存并继续  |  n: 继续停留在此页面  |  q: 退出脚本${N}"
  while true; do
    printf "  请选择 [y/n/q]: " >/dev/tty
    read -r ans </dev/tty || {
      _hk_err "未检测到交互输入，已中止备份流程"
      return 1
    }
    case "${ans}" in
      [Yy]|[Yy][Ee][Ss])
        echo
        _hk_ok "备份确认完成，返回上级菜单"
        return 0
        ;;
      [Nn]|[Nn][Oo]|"")
        _hk_info "请继续停留在当前页面复制备份信息，确认后输入 y"
        ;;
      [Qq]|[Qq][Uu][Ii][Tt]|[Ee][Xx][Ii][Tt])
        _hk_warn "按你的选择退出脚本"
        exit 0
        ;;
      *)
        _hk_warn "请输入 y / n / q"
        ;;
    esac
  done

  # 不恢复 wg0（即将重装系统）
}

# ============================================================
# 安装入口（全新 + 恢复复用同一流程）
# ============================================================
hk_run_fresh() {
  [[ "${FLYTO_VERSION:-}" == "" ]] && _hk_banner
  _check_root
  _check_secrets
  local gate_rc=0

  _step_base_system
  gate_rc=0; _hk_gate_after_step "步骤 1/6 完成，继续步骤 2/6 吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_collect_network
  gate_rc=0; _hk_gate_after_step "步骤 2/6 完成，继续步骤 3/6 吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _input_wg_fresh
  gate_rc=0; _hk_gate_after_step "步骤 3/6 完成，继续步骤 4/6 吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_setup_wireguard
  gate_rc=0; _hk_gate_after_step "步骤 4/6 完成，继续步骤 5/6 吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_install_v2bx
  gate_rc=0; _hk_gate_after_step "步骤 5/6 完成，继续步骤 6/6 吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_panel_ip_monitor
  gate_rc=0; _hk_gate_after_step "步骤 6/6 完成，继续可选 WARP 安装吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_optional_warp
  _print_deploy_summary
}

hk_run_install() {
  [[ "${FLYTO_VERSION:-}" == "" ]] && _hk_banner
  _check_root
  _check_secrets

  while true; do
    _hk_card "安装模式选择"
    echo -e "  ${G}1.${N} 全新安装  ${D}(逐字段输入 WireGuard 配置)${N}"
    echo -e "  ${G}2.${N} 恢复模式  ${D}(粘贴备份内容一键恢复)${N}"
    echo -e "  ${G}0.${N} 返回"
    echo
    local mode=""
    _hk_read_raw mode "请选择 [0-2]" || return 1

    case "${mode}" in
      1)
        hk_run_fresh
        return 0
        ;;
      2)
        hk_run_restore
        return 0
        ;;
      0) return 0 ;;
      *)
        _hk_err "无效选项，请输入 0 / 1 / 2"
        ;;
    esac
  done
}

hk_run_restore() {
  # 快捷入口，直接进入恢复模式
  [[ "${FLYTO_VERSION:-}" == "" ]] && _hk_banner
  _check_root
  _check_secrets
  _hk_card "恢复模式" "将使用备份块恢复 WireGuard 与 V2bX 配置"
  local gate_rc=0

  _step_base_system
  gate_rc=0; _hk_gate_after_step "步骤 1/6 完成，继续步骤 3/6（粘贴恢复块）吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _input_wg_restore
  gate_rc=0; _hk_gate_after_step "恢复块解析完成，继续网络与 WireGuard 部署吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  if [[ -z "${HK_WAN_IF}" || -z "${HK_GW}" || -z "${HK_PUB_IP}" ]]; then
    _step_collect_network
  else
    mkdir -p "${HK_STATE_DIR}"
    echo "${HK_WAN_IF}" > "${HK_STATE_DIR}/wan_if"
    echo "${HK_GW}"     > "${HK_STATE_DIR}/gateway"
    echo "${HK_PUB_IP}" > "${HK_STATE_DIR}/pub_ip"
    _hk_ok "使用备份中的网络信息: ${HK_WAN_IF} / ${HK_GW} / ${HK_PUB_IP}"
  fi

  gate_rc=0; _hk_gate_after_step "网络信息就绪，继续配置 WireGuard 吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_setup_wireguard
  gate_rc=0; _hk_gate_after_step "WireGuard 完成，继续安装 V2bX 吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_install_v2bx
  gate_rc=0; _hk_gate_after_step "V2bX 配置完成，继续部署面板 IP 监控吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_panel_ip_monitor
  gate_rc=0; _hk_gate_after_step "面板监控完成，继续可选 WARP 安装吗？" || gate_rc=$?
  [[ ${gate_rc} -eq 2 ]] && return 0
  [[ ${gate_rc} -ne 0 ]] && return 1

  _step_optional_warp
  _print_deploy_summary
}

# ── 独立运行支持 ─────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -z "${PANEL_API_HOST:-}" || -z "${PANEL_API_KEY:-}" ]]; then
    _hk_err "独立运行需要设置环境变量:"
    _hk_err "  export PANEL_API_HOST=https://your-panel.example.com"
    _hk_err "  export PANEL_API_KEY=your-api-key"
    _hk_err "或通过 flyto.sh 运行（自动解密 secrets.enc）"
    exit 1
  fi
  case "${1:-menu}" in
    install) hk_run_install ;;
    backup)  hk_run_backup  ;;
    restore) hk_run_restore ;;
    menu|*)  hk_run_install ;;
  esac
fi
