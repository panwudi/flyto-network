#!/usr/bin/env bash
# ============================================================
# modules/hk-setup.sh — 中转节点部署模块 v3
#
# 角色：中转节点（HK 或任意中转服务器）
#   - WireGuard 客户端（可选，不配也行）
#   - V2bX（可选）
#   - AI 路由注入（可选）
#   - WARP（可选）
#   - 强制：禁用 IPv6 / 锁定 DNS / 禁用 systemd-resolved
#   - 仅当启用 WG 时强制 IPv4 转发
# ============================================================
set -euo pipefail

_HK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HK_LIB="${_HK_DIR}/../lib"

for _lib in ui.sh validate.sh progress.sh error.sh; do
  # shellcheck disable=SC1090
  [[ -f "${_HK_LIB}/${_lib}" ]] && source "${_HK_LIB}/${_lib}"
done

# ── 兜底 ────────────────────────────────────────────────────
if ! command -v ui_info >/dev/null 2>&1; then
  ui_info()    { echo "[INFO] $*"; }
  ui_ok()      { echo "[ OK ] $*"; }
  ui_warn()    { echo "[WARN] $*" >&2; }
  ui_error()   { echo "[ERR ] $*" >&2; }
  ui_step()    { echo; echo "▶  $*"; echo; }
  ui_pause()   { read -r -p "  按回车继续..." _ </dev/tty || true; echo; }
  ui_confirm() { local a; read -rp "  $1 [y/N]: " a </dev/tty; [[ "${a}" =~ ^[Yy] ]]; }
  UI_USE_DIALOG=0
fi
if ! command -v progress_step >/dev/null 2>&1; then
  _STEP_TOTAL=6
  progress_step() { ui_step "步骤 $1/${_STEP_TOTAL}：$3"; _STEP_NAME="$3"; }
  progress_gate()  { return 0; }
  progress_init()  { _STEP_TOTAL="${1:-6}"; }
fi
if ! command -v validate_ipv4_cidr >/dev/null 2>&1; then
  validate_ipv4_cidr()        { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
  validate_wg_key()           { [[ "${#1}" -ge 40 ]]; }
  validate_wg_endpoint()      { [[ "$1" =~ ^.+:[0-9]+$ ]]; }
  validate_positive_integer() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )); }
  validate_iface()            { ip link show "$1" >/dev/null 2>&1; }
  validate_ipv4()             { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
  validate_input_loop_strict() {
    local __v="$1" l="$2" d="$3" fn="$4" hint="${5:-}"
    local val=""
    [[ -n "${hint}" ]] && echo -e "  \033[2;37m${hint}\033[0m" >/dev/tty
    while true; do
      printf "  %s [%s]: " "${l}" "${d}" >/dev/tty
      IFS= read -r val </dev/tty || return 1
      [[ -z "${val}" ]] && val="${d}"
      "${fn}" "${val}" 2>/dev/null && break
      ui_warn "输入无效，请重新输入"
    done
    printf -v "${__v}" '%s' "${val}"
  }
  validate_input_loop() { validate_input_loop_strict "$@"; }
fi
if ! command -v error_trap_install >/dev/null 2>&1; then
  error_trap_install() { trap 'echo "[ERR] ${BASH_COMMAND} exit $? @ ${BASH_SOURCE[0]}:${LINENO}" >&2' ERR; }
  error_trap_remove()  { trap - ERR; }
fi

HK_STATE_DIR="/etc/hk-setup"

# ── 工具 ─────────────────────────────────────────────────────
_hk_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

_hk_strip_ansi() {
  printf '%s' "$1" | sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g'
}

_hk_is_placeholder() {
  local v="$(_hk_trim "${1:-}")" u
  u="${v^^}"
  [[ -z "${v}" ]] && return 0
  [[ "${u}" =~ ^REPLACE(_WITH_.*)?$ ]] && return 0
  [[ "${u}" == "DEFAULT" || "${u}" == "ENDPOINT" ]] && return 0
  [[ "${u}" == "<EMPTY>" || "${u}" == "NULL" ]] && return 0
  return 1
}

_hk_guess_peer_tun_ip() {
  local local_cidr="${1:-}"
  validate_ipv4_cidr "${local_cidr}" 2>/dev/null || return 1
  python3 - "${local_cidr}" <<'PY' 2>/dev/null
import ipaddress, sys
iface = ipaddress.ip_interface(sys.argv[1].strip())
net, local = iface.network, iface.ip
if net.prefixlen >= 31: sys.exit(1)
first = net.network_address + 1
second = net.network_address + 2
peer = first if first != local else second
if peer == local: sys.exit(1)
print(f"{peer}/32")
PY
}

# ── 前置检查 ─────────────────────────────────────────────────
_check_root() {
  [[ "${EUID:-0}" -eq 0 ]] || { ui_error "请以 root 运行"; exit 1; }
}

_check_secrets() {
  if [[ -z "${PANEL_API_HOST:-}" || -z "${PANEL_API_KEY:-}" ]]; then
    ui_error "PANEL_API_HOST / PANEL_API_KEY 未设置"
    ui_error "请通过 flyto.sh 运行（自动解密），或手动 export 这两个变量"
    exit 1
  fi
}

# ============================================================
# 步骤 1：基础系统（强制项 + 按需项）
# ============================================================
# 参数：enable_ipv4_forward (0|1)
_step_base_system() {
  local enable_fwd="${1:-0}"
  _STEP_NAME="基础系统配置"
  progress_step 1 "${_STEP_TOTAL}" "${_STEP_NAME}"
  error_trap_install

  export DEBIAN_FRONTEND=noninteractive

  error_trap_remove
  ui_spin "更新软件源" apt-get update -y \
    || ui_warn "软件源更新失败，继续使用现有索引"
  error_trap_install

  # 基础包（WG 相关仅在启用时安装）
  local pkgs=(curl ca-certificates dnsutils net-tools iproute2 cron unzip openssl python3 nftables)
  if [[ "${enable_fwd}" == "1" ]]; then
    pkgs+=(wireguard-tools iptables ipset)
  fi

  local total="${#pkgs[@]}" idx=0
  ui_progress_start "安装依赖"
  for p in "${pkgs[@]}"; do
    idx=$((idx+1))
    ui_progress_update $(( idx*100/total )) "安装 ${p}"
    error_trap_remove
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${p}" >/dev/null 2>&1 \
      || ui_warn "可选包 ${p} 失败，已跳过"
    error_trap_install
  done
  ui_progress_done

  # ── 强制：lo 修复 ────────────────────────────────────────
  if ! ip addr show lo 2>/dev/null | grep -q '127.0.0.1'; then
    ui_warn "lo 接口无 127.0.0.1，立即修复..."
    ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true
    ip link set lo up 2>/dev/null || true
    cat > /etc/systemd/system/lo-127-fix.service <<'SVC'
[Unit]
Description=Fix lo 127.0.0.1
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
  fi

  # ── 强制：禁用 IPv6 ─────────────────────────────────────
  cat > /etc/sysctl.d/99-no-ipv6.conf <<'CONF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
CONF

  # ── 按需：IPv4 转发（仅 WG 客户端启用时才需要）─────────
  if [[ "${enable_fwd}" == "1" ]]; then
    cat > /etc/sysctl.d/99-forward.conf <<'CONF'
net.ipv4.ip_forward = 1
CONF
    ui_info "IPv4 转发已启用（WireGuard 客户端模式需要）"
  fi

  sysctl --system >/dev/null 2>&1 || true

  # ── 强制：IPv4 优先 ─────────────────────────────────────
  grep -q 'precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null \
    || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

  # ── 强制：禁用 systemd-resolved，锁定 DNS ──────────────
  systemctl stop    systemd-resolved 2>/dev/null || true
  systemctl disable systemd-resolved 2>/dev/null || true
  systemctl mask    systemd-resolved 2>/dev/null || true
  command -v chattr >/dev/null 2>&1 && chattr -i /etc/resolv.conf 2>/dev/null || true
  [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
  command -v chattr >/dev/null 2>&1 && chattr +i /etc/resolv.conf 2>/dev/null || true

  systemctl enable --now nftables >/dev/null 2>&1 || true

  ui_ok "基础系统配置完成"
  error_trap_remove
}

# ============================================================
# 步骤 2：网络信息采集
# ============================================================
HK_WAN_IF="" HK_GW="" HK_PUB_IP=""

_step_collect_network() {
  _STEP_NAME="采集本机网络信息"
  progress_step 2 "${_STEP_TOTAL}" "${_STEP_NAME}"

  # 若 wg0 在运行则暂停
  if ip link show wg0 >/dev/null 2>&1 && ip link show wg0 | grep -q 'UP'; then
    ui_warn "检测到 wg0 运行中，暂停以探测真实网络信息..."
    systemctl stop wg-quick@wg0 2>/dev/null || true
    sleep 1
  fi

  HK_WAN_IF="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  HK_GW="$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -1 || true)"

  HK_PUB_IP=""
  for probe in https://ifconfig.io https://ip.sb https://api4.my-ip.io/ip; do
    HK_PUB_IP="$(curl -4 -s --max-time 8 "${probe}" 2>/dev/null | tr -d '[:space:]' || true)"
    validate_ipv4 "${HK_PUB_IP}" 2>/dev/null && break || HK_PUB_IP=""
  done
  [[ -z "${HK_PUB_IP}" ]] && ui_warn "公网 IP 自动探测失败，需手动输入"

  ui_info "自动探测结果："
  echo "    WAN 接口 : ${HK_WAN_IF:-<未检测到>}"
  echo "    默认网关 : ${HK_GW:-<未检测到>}"
  echo "    公网 IP  : ${HK_PUB_IP:-<未检测到>}"
  echo

  validate_input_loop_strict HK_WAN_IF \
    "WAN 接口（如 eth0）" "${HK_WAN_IF}" validate_iface \
    "提示：ip -o -4 route show to default"

  validate_input_loop_strict HK_GW \
    "默认网关" "${HK_GW}" validate_ipv4 \
    "提示：ip route show default"

  validate_input_loop_strict HK_PUB_IP \
    "公网 IP（本机对外 IP）" "${HK_PUB_IP}" validate_ipv4 \
    "提示：curl -4 -s https://ifconfig.io"

  mkdir -p "${HK_STATE_DIR}"
  printf '%s\n' "${HK_WAN_IF}" > "${HK_STATE_DIR}/wan_if"
  printf '%s\n' "${HK_GW}"     > "${HK_STATE_DIR}/gateway"
  printf '%s\n' "${HK_PUB_IP}" > "${HK_STATE_DIR}/pub_ip"

  ui_ok "网络信息：WAN=${HK_WAN_IF}  GW=${HK_GW}  PubIP=${HK_PUB_IP}"
}

# ============================================================
# WireGuard 客户端配置（可选步骤）
# ============================================================
HK_PRIV_KEY="" HK_PUB_KEY="" HK_WG_ADDR=""
US_PUB_KEY="" US_WG_ENDPOINT="" US_WG_TUN_IP=""
HK_WG_KEEPALIVE=25 ENABLE_WG=0

_step_wg_client_ask() {
  echo
  if ui_confirm "是否配置 WireGuard 客户端（连接到出口节点）？" "Y"; then
    ENABLE_WG=1
  else
    ENABLE_WG=0
    ui_info "已跳过 WireGuard 配置，本机将直接出站"
  fi
}

_input_wg_fresh() {
  _STEP_NAME="输入 WireGuard 客户端配置"
  progress_step 3 "${_STEP_TOTAL}" "${_STEP_NAME}"

  while true; do
    echo
    ui_info "请在出口节点执行 wg show 或查看其 server_info 获取公钥和 Endpoint"
    ui_info "出口节点还会输出 [Peer] 段，其中 PublicKey 即为下方需要的 US 公钥"
    echo

    validate_input_loop_strict HK_PRIV_KEY \
      "本机（中转节点）WG 私钥" "${HK_PRIV_KEY:-}" validate_wg_key \
      "44 位 base64，以 = 结尾。没有可先运行: wg genkey"

    validate_input_loop_strict HK_WG_ADDR \
      "本机 WG 隧道地址（如 10.0.0.2/32）" "${HK_WG_ADDR:-}" validate_ipv4_cidr \
      "需与出口节点 AllowedIPs 中分配给本机的地址一致"

    validate_input_loop_strict US_PUB_KEY \
      "出口节点 WG 公钥（[Peer] PublicKey）" "${US_PUB_KEY:-}" validate_wg_key \
      "来自出口节点 [Peer] 块中的 PublicKey"

    validate_input_loop_strict US_WG_ENDPOINT \
      "出口节点 Endpoint（IP:端口）" "${US_WG_ENDPOINT:-}" validate_wg_endpoint \
      "来自出口节点 [Peer] 块中的 Endpoint，如 1.2.3.4:51820"

    validate_input_loop_strict US_WG_TUN_IP \
      "出口节点隧道 IP（如 10.0.0.1/32）" "${US_WG_TUN_IP:-10.0.0.1/32}" validate_ipv4_cidr \
      "出口节点 wg0 的 Address 字段，去掉网段前缀改为 /32"

    local ka_val="${HK_WG_KEEPALIVE:-25}"
    validate_input_loop HK_WG_KEEPALIVE \
      "PersistentKeepalive（秒）" "${ka_val}" validate_positive_integer \
      "建议 25，防止 NAT 超时" 2>/dev/null || HK_WG_KEEPALIVE=25

    HK_PUB_KEY="$(printf '%s' "${HK_PRIV_KEY}" | wg pubkey 2>/dev/null || true)"

    echo
    echo -e "  ┌──────────────────────────────────────────────────┐"
    echo -e "  │  \033[1;37mWireGuard 客户端参数确认\033[0m"
    echo -e "  ├──────────────────────────────────────────────────┤"
    printf  "  │  %-22s : %s\n" "本机私钥" "${HK_PRIV_KEY:0:4}...(已隐藏)"
    printf  "  │  %-22s : %s\n" "本机隧道地址" "${HK_WG_ADDR}"
    printf  "  │  %-22s : %s\n" "出口节点公钥" "${US_PUB_KEY:0:12}..."
    printf  "  │  %-22s : %s\n" "出口节点 Endpoint" "${US_WG_ENDPOINT}"
    printf  "  │  %-22s : %s\n" "出口节点隧道 IP" "${US_WG_TUN_IP}"
    printf  "  │  %-22s : %s\n" "Keepalive" "${HK_WG_KEEPALIVE}s"
    echo -e "  └──────────────────────────────────────────────────┘"
    echo

    local gate_rc=0
    progress_gate "确认无误，继续？" || gate_rc=$?
    case "${gate_rc}" in
      0) return 0 ;;
      2) ui_info "重新录入 WireGuard 参数" ;;
      3) exit 0 ;;
    esac
  done
}

_input_wg_restore() {
  _STEP_NAME="导入备份配置（WG 部分）"
  progress_step 3 "${_STEP_TOTAL}" "${_STEP_NAME}"

  while true; do
    echo
    ui_info "请粘贴备份块（END 行或连续两次空行结束）"
    echo -e "  \033[2;37m─── 开始粘贴 ────────────────────────────────────────\033[0m"

    local lines="" line="" read_any=0 blank_count=0
    while IFS= read -r line </dev/tty; do
      line="${line%$'\r'}"
      line="$(_hk_strip_ansi "${line}")"
      if [[ "${line}" =~ END[[:space:]]+FLYTO|^END$ ]]; then break; fi
      if [[ -z "${line//[[:space:]]/}" ]]; then
        blank_count=$((blank_count+1))
        [[ "${read_any}" -eq 1 && "${blank_count}" -ge 2 ]] && break
        lines+=$'\n'; continue
      fi
      blank_count=0; lines+="${line}"$'\n'; read_any=1
    done
    echo -e "  \033[2;37m─── 粘贴结束 ────────────────────────────────────────\033[0m"
    echo

    [[ "${read_any}" -eq 0 ]] && { ui_warn "未读取到内容，请重新粘贴"; continue; }

    # 解析
    HK_PRIV_KEY="" HK_PUB_KEY="" HK_WG_ADDR=""
    US_PUB_KEY="" US_WG_ENDPOINT="" US_WG_TUN_IP=""
    HK_WAN_IF="" HK_GW="" HK_PUB_IP="" V2BX_NODE_ID="" HK_WG_KEEPALIVE="25"
    local parsed=0

    while IFS= read -r line; do
      line="${line%$'\r'}"
      line="$(_hk_strip_ansi "${line}")"
      [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" != *=* ]] && continue
      local k="${line%%=*}" v="${line#*=}"
      k="$(_hk_trim "${k/#export /}")"
      v="$(_hk_trim "${v}")"
      [[ "${v}" =~ ^[\"\'](.*)[\"\']\$ ]] && v="${BASH_REMATCH[1]}"
      case "${k}" in
        HK_PRIV_KEY)                   HK_PRIV_KEY="${v}";    parsed=$((parsed+1)) ;;
        HK_PUB_KEY)                    HK_PUB_KEY="${v}";     parsed=$((parsed+1)) ;;
        HK_WG_ADDR)                    HK_WG_ADDR="${v}";     parsed=$((parsed+1)) ;;
        HK_WG_PEER_PUBKEY|US_PUB_KEY)  US_PUB_KEY="${v}";     parsed=$((parsed+1)) ;;
        HK_WG_ENDPOINT)                US_WG_ENDPOINT="${v}"; parsed=$((parsed+1)) ;;
        HK_WG_KEEPALIVE)               HK_WG_KEEPALIVE="${v}";parsed=$((parsed+1)) ;;
        US_WG_TUN_IP|US_WG_ADDR)       US_WG_TUN_IP="${v}";   parsed=$((parsed+1)) ;;
        HK_WAN_IF)                     HK_WAN_IF="${v}";       parsed=$((parsed+1)) ;;
        HK_GW)                         HK_GW="${v}";           parsed=$((parsed+1)) ;;
        HK_PUB_IP)                     HK_PUB_IP="${v}";       parsed=$((parsed+1)) ;;
        V2BX_NODE_ID|NODE_ID)          V2BX_NODE_ID="${v}";   parsed=$((parsed+1)) ;;
      esac
    done <<< "${lines}"

    ui_info "识别到 ${parsed} 个字段"

    # 清理占位值
    _hk_is_placeholder "${HK_PRIV_KEY}"    && HK_PRIV_KEY=""
    _hk_is_placeholder "${HK_WG_ADDR}"     && HK_WG_ADDR=""
    _hk_is_placeholder "${US_PUB_KEY}"     && US_PUB_KEY=""
    _hk_is_placeholder "${US_WG_ENDPOINT}" && US_WG_ENDPOINT=""
    _hk_is_placeholder "${US_WG_TUN_IP}"   && US_WG_TUN_IP=""
    _hk_is_placeholder "${V2BX_NODE_ID}"   && V2BX_NODE_ID=""
    [[ ! "${HK_WG_KEEPALIVE}" =~ ^[0-9]+$ ]] && HK_WG_KEEPALIVE="25"
    [[ -z "${HK_PUB_KEY}" ]] && HK_PUB_KEY="$(printf '%s' "${HK_PRIV_KEY}" | wg pubkey 2>/dev/null || true)"

    # 补全缺失字段
    if [[ -z "${HK_PRIV_KEY}" ]] || ! validate_wg_key "${HK_PRIV_KEY}" 2>/dev/null; then
      ui_warn "HK_PRIV_KEY 缺失或格式错误，请手动输入"
      validate_input_loop_strict HK_PRIV_KEY "本机 WG 私钥" "" validate_wg_key || return 1
    fi
    if [[ -z "${HK_WG_ADDR}" ]] || ! validate_ipv4_cidr "${HK_WG_ADDR}" 2>/dev/null; then
      ui_warn "HK_WG_ADDR 缺失，请手动输入"
      validate_input_loop_strict HK_WG_ADDR "本机 WG 隧道地址" "" validate_ipv4_cidr || return 1
    fi
    if [[ -z "${US_PUB_KEY}" ]] || ! validate_wg_key "${US_PUB_KEY}" 2>/dev/null; then
      ui_warn "出口节点公钥缺失，请手动输入"
      validate_input_loop_strict US_PUB_KEY "出口节点 WG 公钥" "" validate_wg_key || return 1
    fi
    if [[ -z "${US_WG_ENDPOINT}" ]] || ! validate_wg_endpoint "${US_WG_ENDPOINT}" 2>/dev/null; then
      ui_warn "出口节点 Endpoint 缺失，请手动输入"
      validate_input_loop_strict US_WG_ENDPOINT "出口节点 Endpoint" "" validate_wg_endpoint || return 1
    fi
    if [[ -z "${US_WG_TUN_IP}" ]] || ! validate_ipv4_cidr "${US_WG_TUN_IP}" 2>/dev/null; then
      local guessed
      guessed="$(_hk_guess_peer_tun_ip "${HK_WG_ADDR}" 2>/dev/null || true)"
      [[ -n "${guessed}" ]] && ui_warn "US_WG_TUN_IP 未提供，推测为 ${guessed}" && US_WG_TUN_IP="${guessed}"
      validate_input_loop_strict US_WG_TUN_IP "出口节点隧道 IP" "${US_WG_TUN_IP:-10.0.0.1/32}" validate_ipv4_cidr || return 1
    fi

    local gate_rc=0
    progress_gate "参数确认，继续部署？" || gate_rc=$?
    case "${gate_rc}" in
      0) return 0 ;;
      2) ui_info "重新粘贴备份块" ;;
      3) exit 0 ;;
    esac
  done
}

# ============================================================
# WireGuard 客户端配置生成 + 验证
# ============================================================
_step_setup_wg_client() {
  _STEP_NAME="配置 WireGuard 客户端"
  progress_step 4 "${_STEP_TOTAL}" "${_STEP_NAME}"
  error_trap_install

  local US_PUB_IP="${US_WG_ENDPOINT%%:*}"

  # 面板 IP（仅当安装 V2bX 时才需要）
  local PANEL_IP=""
  if [[ -n "${PANEL_API_HOST:-}" ]]; then
    local panel_host="${PANEL_API_HOST#https://}"
    panel_host="${panel_host#http://}"
    panel_host="${panel_host%%/*}"
    PANEL_IP="$(dig +short "${panel_host}" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | tail -1 || true)"
    [[ -z "${PANEL_IP}" ]] && \
      PANEL_IP="$(getent hosts "${panel_host}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    if [[ -n "${PANEL_IP}" ]]; then
      validate_ipv4 "${PANEL_IP}" 2>/dev/null || { ui_warn "面板 IP 格式异常，已忽略"; PANEL_IP=""; }
    fi
    [[ -z "${PANEL_IP}" ]] && ui_warn "无法解析面板 IP，面板路由将跳过"
  fi

  mkdir -p /etc/wireguard

  {
    echo "[Interface]"
    echo "PrivateKey = ${HK_PRIV_KEY}"
    echo "Address = ${HK_WG_ADDR}"
    echo "Table = off"
    echo ""
    echo "PostUp = grep -q '^100 eth0rt\$' /etc/iproute2/rt_tables || echo '100 eth0rt' >> /etc/iproute2/rt_tables"
    echo "PostUp = ip route replace default via ${HK_GW} dev ${HK_WAN_IF} table eth0rt"
    echo "PostUp = ip rule del pref 100 from ${HK_PUB_IP}/32 lookup eth0rt 2>/dev/null || true"
    echo "PostUp = ip rule add pref 100 from ${HK_PUB_IP}/32 lookup eth0rt"
    echo "PostUp = ip route replace ${US_PUB_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}"
    [[ -n "${PANEL_IP}" ]] && \
      echo "PostUp = ip route replace ${PANEL_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}"
    echo "PostUp = ip route replace ${US_WG_TUN_IP%%/*}/32 dev wg0"
    echo "PostUp = ip route replace default dev wg0"
    echo ""
    echo "PostDown = ip route replace default via ${HK_GW} dev ${HK_WAN_IF} onlink"
    echo "PostDown = ip route del ${US_WG_TUN_IP%%/*}/32 dev wg0 2>/dev/null || true"
    [[ -n "${PANEL_IP}" ]] && \
      echo "PostDown = ip route del ${PANEL_IP}/32 via ${HK_GW} dev ${HK_WAN_IF} 2>/dev/null || true"
    echo "PostDown = ip route del ${US_PUB_IP}/32 via ${HK_GW} dev ${HK_WAN_IF} 2>/dev/null || true"
    echo "PostDown = ip rule del pref 100 from ${HK_PUB_IP}/32 lookup eth0rt 2>/dev/null || true"
    echo "PostDown = ip route flush table eth0rt 2>/dev/null || true"
    echo ""
    echo "[Peer]"
    echo "PublicKey = ${US_PUB_KEY}"
    echo "Endpoint = ${US_WG_ENDPOINT}"
    echo "AllowedIPs = 0.0.0.0/0"
    echo "PersistentKeepalive = ${HK_WG_KEEPALIVE}"
  } > /etc/wireguard/wg0.conf
  chmod 600 /etc/wireguard/wg0.conf

  mkdir -p "${HK_STATE_DIR}"
  printf '%s\n' "${US_WG_TUN_IP}" > "${HK_STATE_DIR}/us_wg_tun_ip"
  if [[ -n "${PANEL_IP}" ]]; then
    printf '%s\n' "${PANEL_IP}" > "${HK_STATE_DIR}/panel_ip"
    local panel_host="${PANEL_API_HOST#https://}"
    grep -v "${panel_host}" /etc/hosts > /tmp/_hk_hosts.tmp \
      && mv /tmp/_hk_hosts.tmp /etc/hosts || true
    printf '%s  %s\n' "${PANEL_IP}" "${panel_host}" >> /etc/hosts
  fi

  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl stop   wg-quick@wg0 2>/dev/null || true
  wg-quick down wg0 2>/dev/null || true
  sleep 1

  ui_spin "启动 wg-quick@wg0" systemctl start wg-quick@wg0 || {
    ui_error "wg-quick@wg0 启动失败"
    journalctl -u wg-quick@wg0 -n 40 --no-pager 2>/dev/null || true
    exit 1
  }
  sleep 3

  if ! systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    ui_error "wg-quick@wg0 未处于 active 状态"
    systemctl status wg-quick@wg0 --no-pager -l 2>/dev/null | head -30 || true
    exit 1
  fi

  # 三项验证
  ui_step "WireGuard 三项验证"
  local ok=1

  echo "─── [1] 握手时间 ───"
  local hs now
  hs="$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || echo 0)"
  now="$(date +%s)"
  if [[ -n "${hs}" && "${hs}" -gt 0 && $(( now - hs )) -lt 300 ]]; then
    ui_ok "握手 $(( now - hs ))s 前"
  else
    ui_error "无握手或握手超时"; ok=0
  fi

  echo "─── [2] 出口 IP ───"
  local exit_ip="" exit_country=""
  exit_ip="$(curl -4 -s --max-time 10 --interface wg0 https://ifconfig.io 2>/dev/null || true)"
  [[ -z "${exit_ip}" ]] && exit_ip="$(curl -4 -s --max-time 10 https://ifconfig.io 2>/dev/null || true)"
  exit_country="$(curl -s --max-time 8 "https://ipinfo.io/${exit_ip}/country" 2>/dev/null || echo '')"
  local ddev
  ddev="$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  echo "  出口 IP: ${exit_ip:-?}  地区: ${exit_country:-?}  默认路由: dev=${ddev:-?}"
  if [[ "${exit_country}" == "US" ]]; then
    ui_ok "出口为美国"
  else
    ui_error "出口非美国（${exit_country:-未知}）"; ok=0
    [[ "${exit_ip}" == "${HK_PUB_IP}" ]] && ui_warn "出口 IP 与本机 IP 相同，wg0 未生效"
  fi

  echo "─── [3] 回包路径 ───"
  local rt_dev
  rt_dev="$(ip route get 8.8.8.8 from "${HK_PUB_IP}" 2>/dev/null | grep -oP 'dev \K\S+' || echo '')"
  if [[ "${rt_dev}" == "${HK_WAN_IF}" ]]; then
    ui_ok "回包走 ${HK_WAN_IF}（正确）"
  else
    ui_error "回包走 ${rt_dev:-?}，应为 ${HK_WAN_IF}"; ok=0
  fi

  if [[ "${ok}" -eq 0 ]]; then
    ui_error "WireGuard 验证未通过"
    echo "  排查：journalctl -u wg-quick@wg0 -n 30 | wg show | ip route show"
    exit 1
  fi
  ui_ok "WireGuard 三项验证全部通过"
  error_trap_remove
}

# ============================================================
# V2bX 安装（可选）
# ============================================================
V2BX_NODE_ID="" ENABLE_V2BX=0

_step_v2bx_ask() {
  echo
  if ui_confirm "是否安装 V2bX（代理节点管理）？" "Y"; then
    ENABLE_V2BX=1
  else
    ENABLE_V2BX=0
    ui_info "已跳过 V2bX 安装"
  fi
}

# AI 路由注入（可选）
ENABLE_AI_ROUTE=0

_write_ai_warp_route_sync_script() {
  cat > /usr/local/bin/update-ai-warp-route.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="/etc/warp-google/env"
V2BX_SING_ORIGIN="/etc/V2bX/sing_origin.json"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" || true
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
command -v python3 >/dev/null 2>&1 || { echo "[AI-ROUTE] python3 未安装" >&2; exit 1; }
tmp_rules="$(mktemp)"; tmp_conf="$(mktemp)"
trap 'rm -f "${tmp_rules}" "${tmp_conf}"' EXIT
python3 > "${tmp_rules}" <<'PY'
import json, urllib.request
SOURCES=[
  ("meta","https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/openai.yaml"),
  ("meta","https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/anthropic.yaml"),
  ("v2fly","https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/openai"),
  ("v2fly","https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/anthropic"),
]
FALLBACK=["openai.com","chatgpt.com","anthropic.com","claude.ai","claude.com"]
def parse(style,text):
  out=[]
  for raw in text.splitlines():
    l=raw.strip()
    if not l or l.startswith("#"): continue
    if style=="meta":
      if l=="payload:": continue
      if l.startswith("- "): l=l[2:].strip()
    l=l.split(" @",1)[0].strip()
    if not l: continue
    if l.startswith("full:"): out.append(("full",l[5:]))
    elif l.startswith("regexp:"): out.append(("regex",l[7:]))
    elif l.startswith("+."): out.append(("suffix",l[2:]))
    else: out.append(("suffix",l))
  return out
suffix,full,regex=set(),set(),set()
for style,url in SOURCES:
  try:
    req=urllib.request.Request(url,headers={"User-Agent":"flyto-network/2"})
    with urllib.request.urlopen(req,timeout=20) as r: text=r.read().decode("utf-8","ignore")
    for t,v in parse(style,text):
      if t=="suffix": suffix.add(v.lower())
      elif t=="full": full.add(v.lower())
      elif t=="regex": regex.add(v)
  except: pass
for x in FALLBACK: suffix.add(x)
full={x for x in full if x not in suffix}
print(json.dumps({"domain_suffix":sorted(suffix),"domain":sorted(full),"domain_regex":sorted(regex)}))
PY
WARP_PROXY_PORT="${WARP_PROXY_PORT}" TMP_RULES="${tmp_rules}" python3 > "${tmp_conf}" <<'PY'
import json,os
port=int(os.environ.get("WARP_PROXY_PORT","40000"))
rules=json.load(open(os.environ["TMP_RULES"]))
route_rules=[{"ip_is_private":True,"outbound":"block"}]
if rules.get("domain_suffix"): route_rules.append({"domain_suffix":rules["domain_suffix"],"outbound":"warp-ai"})
if rules.get("domain"):        route_rules.append({"domain":rules["domain"],"outbound":"warp-ai"})
if rules.get("domain_regex"):  route_rules.append({"domain_regex":rules["domain_regex"],"outbound":"warp-ai"})
config={"dns":{"servers":[{"address":"8.8.8.8","strategy":"ipv4_only"},{"address":"1.1.1.1","strategy":"ipv4_only"}]},"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"},{"type":"socks","tag":"warp-ai","server":"127.0.0.1","server_port":port}],"route":{"rules":route_rules,"final":"direct"}}
print(json.dumps(config,indent=2))
PY
install -m 0644 "${tmp_conf}" "${V2BX_SING_ORIGIN}"
systemctl restart V2bX >/dev/null 2>&1 || true
echo "[AI-ROUTE] 已更新 ${V2BX_SING_ORIGIN} (port=${WARP_PROXY_PORT})"
SCRIPT
  chmod +x /usr/local/bin/update-ai-warp-route.sh
}

_step_install_v2bx() {
  _STEP_NAME="安装 V2bX"
  progress_step 5 "${_STEP_TOTAL}" "${_STEP_NAME}"

  ui_info "下载 V2bX 安装脚本..."
  local install_sh
  install_sh="$(mktemp)"
  curl -fL --progress-bar https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh \
    -o "${install_sh}" || { ui_error "V2bX 安装脚本下载失败"; return 1; }
  chmod +x "${install_sh}"

  echo
  ui_warn "V2bX 安装器即将启动，请在菜单中选择 [1] 安装，完成后返回。"
  echo
  bash "${install_sh}"
  rm -f "${install_sh}"

  # 提示节点 ID
  while true; do
    validate_input_loop V2BX_NODE_ID \
      "V2bX 节点 ID（从面板获取，纯数字）" "${V2BX_NODE_ID:-}" \
      validate_positive_integer || return 1
    break
  done

  mkdir -p /etc/V2bX

  cat > /etc/V2bX/config.json <<EOF
{
  "Log": { "Level": "info", "Output": "" },
  "Cores": [{
    "Type": "sing",
    "Log": { "Level": "info", "Timestamp": true },
    "OriginalPath": "/etc/V2bX/sing_origin.json"
  }],
  "Nodes": [{
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
  }]
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

  # AI 路由注入（可选）
  _write_ai_warp_route_sync_script

  echo
  if ui_confirm "是否注入 OpenAI/Claude 域名路由到 sing-box（需要 WARP 已安装或将安装）？" "N"; then
    ENABLE_AI_ROUTE=1
    if /usr/local/bin/update-ai-warp-route.sh >/dev/null 2>&1; then
      ui_ok "AI 路由已注入（OpenAI / Claude → WARP SOCKS5）"
    else
      ui_warn "AI 路由注入失败，回退为基础 direct 配置"
      ENABLE_AI_ROUTE=0
    fi
  else
    ui_info "已跳过 AI 路由注入，使用基础 direct 配置"
    ENABLE_AI_ROUTE=0
  fi

  # 写基础 sing_origin.json（如果 AI 路由未注入或注入失败）
  if [[ "${ENABLE_AI_ROUTE}" -eq 0 ]]; then
    cat > /etc/V2bX/sing_origin.json <<'EOF'
{
  "dns": {"servers":[{"address":"8.8.8.8","strategy":"ipv4_only"},{"address":"1.1.1.1","strategy":"ipv4_only"}]},
  "outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],
  "route":{"rules":[{"ip_is_private":true,"outbound":"block"}],"final":"direct"}
}
EOF
  fi

  systemctl restart V2bX >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet V2bX 2>/dev/null; then
    ui_ok "V2bX 已启动"
  else
    ui_warn "V2bX 可能启动失败，请检查：journalctl -u V2bX -n 30"
  fi
}

# ============================================================
# 面板 IP 监控 cron（仅当启用 WG + V2bX 时才有意义）
# ============================================================
_step_panel_ip_monitor() {
  _STEP_NAME="部署面板 IP 监控"
  progress_step 6 "${_STEP_TOTAL}" "${_STEP_NAME}"

  local panel_host="${PANEL_API_HOST#https://}"
  panel_host="${panel_host#http://}"
  panel_host="${panel_host%%/*}"

  cat > /usr/local/bin/update-panel-route.sh <<MONITOR
#!/usr/bin/env bash
set -euo pipefail
PANEL_HOST="${panel_host}"
STATE_DIR="${HK_STATE_DIR}"
STATE_FILE="\${STATE_DIR}/panel_ip"
LOG_FILE="/var/log/update-panel-route.log"
WAN_IF="\$(cat "\${STATE_DIR}/wan_if" 2>/dev/null || ip -o -4 route show to default | awk '{print \$5}' | head -1)"
GW="\$(cat "\${STATE_DIR}/gateway" 2>/dev/null || ip -o -4 route show to default | awk '{print \$3}' | head -1)"
if [[ -z "\${WAN_IF}" || -z "\${GW}" ]]; then
  echo "\$(date '+%Y-%m-%d %H:%M:%S') WAN_IF 或 GW 为空，跳过" >> "\${LOG_FILE}"; exit 0
fi
new_ip="\$(dig +short "\${PANEL_HOST}" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | tail -1 || true)"
[[ -z "\${new_ip}" ]] && exit 0
old_ip="\$(cat "\${STATE_FILE}" 2>/dev/null || true)"
[[ "\${new_ip}" == "\${old_ip}" ]] && exit 0
echo "\$(date '+%Y-%m-%d %H:%M:%S') IP 变更: \${old_ip:-<空>} -> \${new_ip}" >> "\${LOG_FILE}"
[[ -n "\${old_ip}" ]] && ip route del "\${old_ip}/32" 2>/dev/null || true
ip route add "\${new_ip}/32" via "\${GW}" dev "\${WAN_IF}" 2>/dev/null || true
sed -i "/\${PANEL_HOST}/d" /etc/hosts
printf '%s  %s\n' "\${new_ip}" "\${PANEL_HOST}" >> /etc/hosts
printf '%s\n' "\${new_ip}" > "\${STATE_FILE}"
systemctl restart V2bX >/dev/null 2>&1 || true
echo "\$(date '+%Y-%m-%d %H:%M:%S') 路由已更新" >> "\${LOG_FILE}"
MONITOR
  chmod +x /usr/local/bin/update-panel-route.sh

  (crontab -l 2>/dev/null | grep -v 'update-panel-route'; \
   echo "5 * * * * /usr/local/bin/update-panel-route.sh") | crontab -

  ui_ok "面板 IP 监控已配置（每小时 :05 检测）"
}

# ============================================================
# 可选：WARP
# ============================================================
_step_optional_warp() {
  echo
  if ui_confirm "是否安装 WARP（Google/Gemini/AI 流量分流，可选）？" "N"; then
    if ! command -v warp_do_install >/dev/null 2>&1; then
      local warp_mod="${_HK_DIR}/warp.sh"
      # shellcheck disable=SC1090
      [[ -f "${warp_mod}" ]] && source "${warp_mod}" || {
        ui_warn "未找到 warp.sh，跳过 WARP 安装"; return
      }
    fi
    warp_do_install
  else
    ui_info "已跳过 WARP，事后可通过主菜单 → WARP 管理 安装"
  fi
}

# ============================================================
# 部署摘要
# ============================================================
_print_deploy_summary() {
  local exit_ip
  exit_ip="$(curl -4 -s --max-time 6 https://ifconfig.io 2>/dev/null || echo '?')"
  echo
  echo -e "\033[1;32m╔══════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[1;32m║  ✓  中转节点部署完成 — FLYTOex Network                  ║\033[0m"
  echo -e "\033[1;32m╚══════════════════════════════════════════════════════════╝\033[0m"
  echo
  if [[ "${ENABLE_WG}" -eq 1 ]]; then
    echo "  WireGuard   wg0 客户端 → ${US_WG_ENDPOINT%%:*}"
  else
    echo "  WireGuard   未配置（直接出站）"
  fi
  if [[ "${ENABLE_V2BX}" -eq 1 ]]; then
    echo "  V2bX        节点 ID: ${V2BX_NODE_ID:-?}  面板: ${PANEL_API_HOST}"
    echo "  AI 路由     $( [[ "${ENABLE_AI_ROUTE}" -eq 1 ]] && echo "已注入 → WARP" || echo "未启用")"
  else
    echo "  V2bX        未安装"
  fi
  echo "  当前出口    ${exit_ip}"
  echo
  echo "  常用命令："
  [[ "${ENABLE_WG}" -eq 1 ]]   && echo "    wg show                       WireGuard 状态"
  [[ "${ENABLE_V2BX}" -eq 1 ]] && echo "    v2bx status                   V2bX 状态"
  command -v warp >/dev/null 2>&1 && echo "    warp status                   WARP 状态"
  echo
}

# ============================================================
# 备份（保持与 v2 兼容）
# ============================================================
hk_run_backup() {
  ui_step "备份模式 — 保存 WireGuard 配置"

  local wg_was_up=0
  if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    ui_warn "暂停 wg0 以获取真实网络信息..."
    systemctl stop wg-quick@wg0; wg_was_up=1; sleep 1
  fi

  local priv="" pub="" addr="" peer_pub="" endpoint="" us_tun_ip=""
  local keepalive="25" node_id="" wan_if="" gw="" pub_ip=""
  local wg_conf="" wg_tmp=""

  for p in /etc/wireguard/wg0.conf /usr/local/etc/wireguard/wg0.conf; do
    [[ -f "${p}" ]] && { wg_conf="${p}"; break; }
  done

  if [[ -z "${wg_conf}" ]] && command -v wg >/dev/null 2>&1; then
    wg_tmp="$(mktemp)"
    wg showconf wg0 > "${wg_tmp}" 2>/dev/null && wg_conf="${wg_tmp}" || { rm -f "${wg_tmp}"; wg_tmp=""; }
  fi

  if [[ -n "${wg_conf}" ]]; then
    priv="$(sed -nE 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | head -1)"
    addr="$(sed -nE 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | head -1)"
    peer_pub="$(sed -nE 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | tail -1)"
    endpoint="$(sed -nE 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "${wg_conf}" | head -1)"
    keepalive="$(sed -nE 's/^[[:space:]]*PersistentKeepalive[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${wg_conf}" | head -1)"
    us_tun_ip="$(sed -nE 's/.*ip route replace[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+)[[:space:]]+dev[[:space:]]+wg0.*/\1/p' "${wg_conf}" | head -1)"
  fi
  [[ -n "${wg_tmp}" ]] && rm -f "${wg_tmp}"
  [[ -n "${priv}" ]] && pub="$(printf '%s' "${priv}" | wg pubkey 2>/dev/null || true)"
  [[ ! "${keepalive}" =~ ^[0-9]+$ ]] && keepalive="25"

  # 尝试从历史状态或推断 US_WG_TUN_IP
  if [[ -z "${us_tun_ip}" ]] || ! validate_ipv4_cidr "${us_tun_ip}" 2>/dev/null; then
    local saved_tun
    saved_tun="$(cat "${HK_STATE_DIR}/us_wg_tun_ip" 2>/dev/null | tr -d '[:space:]' || true)"
    validate_ipv4_cidr "${saved_tun}" 2>/dev/null && us_tun_ip="${saved_tun}"
  fi
  if [[ -z "${us_tun_ip}" ]] && [[ -n "${addr}" ]]; then
    local guessed
    guessed="$(_hk_guess_peer_tun_ip "${addr}" 2>/dev/null || true)"
    validate_ipv4_cidr "${guessed}" 2>/dev/null && us_tun_ip="${guessed}" && \
      ui_warn "US_WG_TUN_IP 已推断为 ${us_tun_ip}，请核对"
  fi

  # V2bX 节点 ID
  for cfg in /etc/V2bX/config.json /usr/local/etc/V2bX/config.json; do
    [[ -f "${cfg}" ]] && node_id="$(sed -nE 's/.*"(NodeID|nodeId|node_id)"[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*/\2/p' "${cfg}" 2>/dev/null | head -1)" && [[ -n "${node_id}" ]] && break
  done

  wan_if="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  gw="$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -1 || true)"
  pub_ip="$(curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null || true)"

  _hk_is_placeholder "${priv}"      && priv="REPLACE_WITH_HK_PRIV_KEY"
  _hk_is_placeholder "${addr}"      && addr="REPLACE_WITH_HK_WG_ADDR"
  _hk_is_placeholder "${peer_pub}"  && peer_pub="REPLACE_WITH_HK_WG_PEER_PUBKEY"
  _hk_is_placeholder "${endpoint}"  && endpoint="REPLACE_WITH_HK_WG_ENDPOINT"
  { _hk_is_placeholder "${us_tun_ip}" || [[ "${us_tun_ip}" == "/32" || -z "${us_tun_ip}" ]]; } \
    && us_tun_ip="REPLACE_WITH_US_WG_TUN_IP"
  [[ -z "${node_id}" ]] && node_id="REPLACE_WITH_NODE_ID"

  echo
  echo -e "\033[1;33m╔════════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[1;33m║  ⚠  请完整复制 BEGIN 到 END 之间内容并妥善保存            ║\033[0m"
  echo -e "\033[1;33m╚════════════════════════════════════════════════════════════╝\033[0m"
  echo
  cat <<BACKUP
########## BEGIN FLYTO BACKUP ##########
HK_PRIV_KEY=${priv}
HK_PUB_KEY=${pub}
HK_WG_ADDR=${addr}
HK_WG_PEER_PUBKEY=${peer_pub}
HK_WG_ENDPOINT=${endpoint}
HK_WG_ALLOWED_IPS=0.0.0.0/0
HK_WG_KEEPALIVE=${keepalive}
US_WG_TUN_IP=${us_tun_ip}
HK_WAN_IF=${wan_if}
HK_GW=${gw}
HK_PUB_IP=${pub_ip}
V2BX_NODE_ID=${node_id}
########### END FLYTO BACKUP ###########
BACKUP
  echo
  ui_warn "私钥（HK_PRIV_KEY）极度敏感，请保存在本地加密存储中，不要通过聊天/邮件传输"
  echo

  while true; do
    if ui_confirm "已将备份内容复制保存？（确认后返回菜单）" "N"; then
      ui_ok "备份确认完成"; break
    fi
    ui_info "请先复制上方内容，完成后选 y"
  done

  if [[ "${wg_was_up}" -eq 1 ]]; then
    systemctl start wg-quick@wg0 2>/dev/null \
      || ui_warn "wg0 恢复启动失败，请手动运行：systemctl start wg-quick@wg0"
  fi
}

# ============================================================
# 主部署流程（全新 / 恢复）
# ============================================================
hk_run_fresh() {
  [[ "${FLYTO_VERSION:-}" == "" ]] && ui_banner 2>/dev/null || true
  _check_root
  # secrets 仅当安装 V2bX 时才必须
  local gate_rc=0

  # 先问 WG 是否启用（决定是否开启 IPv4 转发）
  _step_wg_client_ask

  progress_init 6
  _step_base_system "${ENABLE_WG}"
  progress_gate "步骤 1 完成，继续？" || gate_rc=$?
  [[ "${gate_rc}" -eq 2 ]] && return 0

  _step_collect_network
  progress_gate "步骤 2 完成，继续？" || gate_rc=$?
  [[ "${gate_rc}" -eq 2 ]] && return 0

  if [[ "${ENABLE_WG}" -eq 1 ]]; then
    _input_wg_fresh
    progress_gate "WG 参数就绪，继续配置？" || gate_rc=$?
    [[ "${gate_rc}" -eq 2 ]] && return 0

    _step_setup_wg_client
    progress_gate "WG 配置完成，继续？" || gate_rc=$?
    [[ "${gate_rc}" -eq 2 ]] && return 0
  fi

  # V2bX 可选
  _step_v2bx_ask
  if [[ "${ENABLE_V2BX}" -eq 1 ]]; then
    _check_secrets
    _step_install_v2bx
    progress_gate "V2bX 完成，继续面板监控？" || gate_rc=$?
    [[ "${gate_rc}" -eq 2 ]] && return 0

    if [[ "${ENABLE_WG}" -eq 1 ]]; then
      _step_panel_ip_monitor
    else
      ui_info "未配置 WireGuard，跳过面板 IP 监控（不需要路由切换）"
    fi
  fi

  _step_optional_warp
  progress_complete 2>/dev/null || true
  _print_deploy_summary
}

hk_run_restore() {
  [[ "${FLYTO_VERSION:-}" == "" ]] && ui_banner 2>/dev/null || true
  _check_root
  local gate_rc=0

  _step_wg_client_ask
  progress_init 6
  _step_base_system "${ENABLE_WG}"
  progress_gate "步骤 1 完成，继续粘贴恢复块？" || gate_rc=$?
  [[ "${gate_rc}" -eq 2 ]] && return 0

  if [[ "${ENABLE_WG}" -eq 1 ]]; then
    _input_wg_restore
    progress_gate "恢复块解析完成，继续网络采集？" || gate_rc=$?
    [[ "${gate_rc}" -eq 2 ]] && return 0

    # 验证备份 IP 与当前机器是否一致
    local current_pub
    current_pub="$(curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "${HK_WAN_IF}" && -n "${HK_GW}" && -n "${HK_PUB_IP}" \
          && "${current_pub}" == "${HK_PUB_IP}" ]]; then
      mkdir -p "${HK_STATE_DIR}"
      printf '%s\n' "${HK_WAN_IF}" > "${HK_STATE_DIR}/wan_if"
      printf '%s\n' "${HK_GW}"     > "${HK_STATE_DIR}/gateway"
      printf '%s\n' "${HK_PUB_IP}" > "${HK_STATE_DIR}/pub_ip"
      ui_ok "使用备份网络信息（当前 IP 一致）：${HK_WAN_IF} / ${HK_GW} / ${HK_PUB_IP}"
    else
      [[ -n "${current_pub}" && "${current_pub}" != "${HK_PUB_IP:-}" ]] && \
        ui_warn "当前 IP（${current_pub}）与备份 IP（${HK_PUB_IP:-?}）不一致，重新采集网络信息"
      _step_collect_network
    fi

    progress_gate "网络信息就绪，继续配置 WG？" || gate_rc=$?
    [[ "${gate_rc}" -eq 2 ]] && return 0
    _step_setup_wg_client
    progress_gate "WG 完成，继续？" || gate_rc=$?
    [[ "${gate_rc}" -eq 2 ]] && return 0
  fi

  _step_v2bx_ask
  if [[ "${ENABLE_V2BX}" -eq 1 ]]; then
    _check_secrets
    _step_install_v2bx
    progress_gate "V2bX 完成，继续面板监控？" || gate_rc=$?
    [[ "${gate_rc}" -eq 2 ]] && return 0
    [[ "${ENABLE_WG}" -eq 1 ]] && _step_panel_ip_monitor
  fi

  _step_optional_warp
  progress_complete 2>/dev/null || true
  _print_deploy_summary
}

hk_run_install() {
  [[ "${FLYTO_VERSION:-}" == "" ]] && ui_banner 2>/dev/null || true
  _check_root

  local mode=""
  ui_menu mode "中转节点安装模式" "请选择部署方式" \
    "1" "全新安装" \
    "2" "从备份恢复" \
    "0" "返回" || return 0

  case "${mode}" in
    1) hk_run_fresh   ;;
    2) hk_run_restore ;;
    0) return 0       ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ -z "${PANEL_API_HOST:-}" ]] && {
    echo "独立运行需设置 PANEL_API_HOST / PANEL_API_KEY"
    echo "或通过 flyto.sh 运行"
    exit 1
  }
  case "${1:-menu}" in
    install) hk_run_install ;;
    backup)  hk_run_backup  ;;
    restore) hk_run_restore ;;
    *)       hk_run_install ;;
  esac
fi
