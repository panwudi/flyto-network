#!/usr/bin/env bash
# ============================================================
# modules/wg-server.sh — 出口节点 WireGuard 服务端配置
#
# 角色：出口节点（US 节点 / 任意出口服务器）
#   - 生成服务端密钥对
#   - 配置 wg0 监听端口
#   - 接受来自中转节点的连接
#   - 输出 [Peer] 段供中转节点使用
#   - 不安装 V2bX
#   - 强制：禁用 IPv6 / 锁定 DNS / 开启 IPv4 转发
#   - 可选：WARP
# ============================================================
set -euo pipefail

_WGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WGS_LIB="${_WGS_DIR}/../lib"

for _lib in ui.sh validate.sh progress.sh error.sh; do
  # shellcheck disable=SC1090
  [[ -f "${_WGS_LIB}/${_lib}" ]] && source "${_WGS_LIB}/${_lib}"
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
  ui_input()   { local __v="$1" l="$2" d="${3:-}"; printf "  %s [%s]: " "${l}" "${d}" >/dev/tty; IFS= read -r "${__v}" </dev/tty || true; }
fi
if ! command -v progress_step >/dev/null 2>&1; then
  progress_step() { ui_step "步骤 $1/$2：$3"; }
  progress_gate() { return 0; }
  progress_init() { :; }
fi
if ! command -v validate_ipv4_cidr >/dev/null 2>&1; then
  validate_ipv4_cidr()    { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
  validate_positive_integer() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )); }
  validate_ipv4()         { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
  validate_iface()        { ip link show "$1" >/dev/null 2>&1; }
  validate_input_loop_strict() {
    local __v="$1" l="$2" d="$3" fn="$4"
    local val=""
    while true; do
      printf "  %s [%s]: " "${l}" "${d}" >/dev/tty
      IFS= read -r val </dev/tty || return 1
      [[ -z "${val}" ]] && val="${d}"
      "${fn}" "${val}" 2>/dev/null && break || ui_warn "输入无效，请重新输入"
    done
    printf -v "${__v}" '%s' "${val}"
  }
fi
if ! command -v error_trap_install >/dev/null 2>&1; then
  error_trap_install() { trap 'echo "[ERR] ${BASH_COMMAND} exit $? @ ${BASH_SOURCE[0]}:${LINENO}" >&2' ERR; }
  error_trap_remove()  { trap - ERR; }
fi

WGS_STATE_DIR="/etc/wg-server"

# ============================================================
# 工具
# ============================================================
_wgs_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# ============================================================
# 步骤 1：基础系统（出口节点专用，强制项）
# ============================================================
_wgs_step_base() {
  _STEP_NAME="基础系统配置（出口节点）"
  progress_step 1 5 "${_STEP_NAME}"
  error_trap_install

  export DEBIAN_FRONTEND=noninteractive

  error_trap_remove
  ui_spin "更新软件源" apt-get update -y \
    || ui_warn "软件源更新失败，继续使用现有索引"
  error_trap_install

  local pkgs=(wireguard-tools curl ca-certificates iproute2 iptables nftables openssl)
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

  # ── 强制：禁用 IPv6 ─────────────────────────────────────
  cat > /etc/sysctl.d/99-no-ipv6.conf <<'CONF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
CONF

  # ── 强制：IPv4 转发（出口节点必须）─────────────────────
  cat > /etc/sysctl.d/99-forward.conf <<'CONF'
net.ipv4.ip_forward = 1
CONF
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
# 步骤 2：生成密钥对 + 采集网络信息
# ============================================================
WGS_PRIV_KEY="" WGS_PUB_KEY=""
WGS_LISTEN_PORT=51820
WGS_TUN_ADDR=""   # 服务端隧道地址，如 10.0.0.1/24
WGS_WAN_IF="" WGS_PUB_IP=""

_wgs_step_keygen() {
  _STEP_NAME="生成密钥 & 采集网络信息"
  progress_step 2 5 "${_STEP_NAME}"

  # 生成密钥对
  WGS_PRIV_KEY="$(wg genkey)"
  WGS_PUB_KEY="$(printf '%s' "${WGS_PRIV_KEY}" | wg pubkey)"
  ui_ok "密钥对已生成"
  echo "  公钥（后续中转节点需要）：${WGS_PUB_KEY}"
  echo

  # 监听端口
  local port_val=""
  validate_input_loop port_val \
    "WireGuard 监听端口" \
    "${WGS_LISTEN_PORT}" \
    validate_positive_integer \
    "建议 51820，确保防火墙/安全组已开放该 UDP 端口" \
    2>/dev/null || port_val="${WGS_LISTEN_PORT}"
  WGS_LISTEN_PORT="${port_val}"

  # 服务端隧道地址
  local addr_val=""
  validate_input_loop_strict addr_val \
    "服务端 WG 隧道地址（如 10.0.0.1/24）" \
    "10.0.0.1/24" \
    validate_ipv4_cidr \
    "此地址用于 WireGuard 虚拟网络，与中转节点约定即可"
  WGS_TUN_ADDR="${addr_val}"

  # 探测公网 IP
  WGS_PUB_IP=""
  for probe in https://ifconfig.io https://ip.sb https://api4.my-ip.io/ip; do
    WGS_PUB_IP="$(curl -4 -s --max-time 8 "${probe}" 2>/dev/null | tr -d '[:space:]' || true)"
    validate_ipv4 "${WGS_PUB_IP}" 2>/dev/null && break || WGS_PUB_IP=""
  done
  [[ -z "${WGS_PUB_IP}" ]] && ui_warn "公网 IP 自动探测失败，需手动输入"

  validate_input_loop_strict WGS_PUB_IP \
    "本机公网 IP（Endpoint 用）" \
    "${WGS_PUB_IP}" \
    validate_ipv4 \
    "中转节点将使用此 IP 连接本机"

  # WAN 接口
  WGS_WAN_IF="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  validate_input_loop_strict WGS_WAN_IF \
    "WAN 接口（如 eth0）" \
    "${WGS_WAN_IF:-eth0}" \
    validate_iface \
    "用于配置 NAT 规则"

  mkdir -p "${WGS_STATE_DIR}"
  printf '%s\n' "${WGS_WAN_IF}"    > "${WGS_STATE_DIR}/wan_if"
  printf '%s\n' "${WGS_PUB_IP}"    > "${WGS_STATE_DIR}/pub_ip"
  printf '%s\n' "${WGS_LISTEN_PORT}" > "${WGS_STATE_DIR}/listen_port"

  ui_ok "密钥和网络信息就绪"
}

# ============================================================
# 步骤 3：收集中转节点（Peer）信息
# ============================================================
# 支持多个 Peer，每个 Peer 一个隧道 IP
declare -a WGS_PEERS_PUBKEY=()
declare -a WGS_PEERS_TUN_IP=()

_wgs_step_collect_peers() {
  _STEP_NAME="录入中转节点 Peer 信息"
  progress_step 3 5 "${_STEP_NAME}"

  ui_info "请输入中转节点的 WireGuard 公钥和隧道 IP"
  ui_info "（可添加多个中转节点，输入完成后留空回车结束）"
  echo

  WGS_PEERS_PUBKEY=()
  WGS_PEERS_TUN_IP=()
  local idx=1

  while true; do
    echo "  ── Peer ${idx} ──────────────────────────────────────"
    local peer_pub="" peer_ip=""

    printf "  中转节点 %d 公钥（留空结束）: " "${idx}" >/dev/tty
    IFS= read -r peer_pub </dev/tty || break
    peer_pub="$(_wgs_trim "${peer_pub}")"
    [[ -z "${peer_pub}" ]] && break

    if ! validate_wg_key "${peer_pub}" 2>/dev/null; then
      ui_warn "公钥格式错误（需 44 位 base64），请重新输入"
      continue
    fi

    validate_input_loop_strict peer_ip \
      "该中转节点的隧道 IP（如 10.0.0.2/32）" \
      "10.0.0.${idx+1}/32" \
      validate_ipv4_cidr \
      "每个 Peer 分配不同的隧道 IP"

    WGS_PEERS_PUBKEY+=("${peer_pub}")
    WGS_PEERS_TUN_IP+=("${peer_ip}")
    ui_ok "Peer ${idx} 已添加：${peer_ip}"
    idx=$((idx+1))
  done

  if [[ "${#WGS_PEERS_PUBKEY[@]}" -eq 0 ]]; then
    ui_warn "未添加任何 Peer，将生成不含 Peer 的配置（后续可手动编辑 /etc/wireguard/wg0.conf）"
  else
    ui_ok "共添加 ${#WGS_PEERS_PUBKEY[@]} 个 Peer"
  fi
}

# ============================================================
# 步骤 4：生成 wg0.conf + NAT 规则 + 启动
# ============================================================
_wgs_step_setup() {
  _STEP_NAME="生成配置并启动 WireGuard"
  progress_step 4 5 "${_STEP_NAME}"
  error_trap_install

  mkdir -p /etc/wireguard

  # 生成 wg0.conf
  {
    echo "[Interface]"
    echo "PrivateKey = ${WGS_PRIV_KEY}"
    echo "Address = ${WGS_TUN_ADDR}"
    echo "ListenPort = ${WGS_LISTEN_PORT}"
    echo "Table = off"
    echo ""
    # PostUp：NAT 规则 + 路由
    echo "PostUp = iptables -t nat -A POSTROUTING -o ${WGS_WAN_IF} -j MASQUERADE"
    echo "PostUp = iptables -A FORWARD -i wg0 -j ACCEPT"
    echo "PostUp = iptables -A FORWARD -o wg0 -j ACCEPT"
    echo ""
    echo "PostDown = iptables -t nat -D POSTROUTING -o ${WGS_WAN_IF} -j MASQUERADE"
    echo "PostDown = iptables -D FORWARD -i wg0 -j ACCEPT"
    echo "PostDown = iptables -D FORWARD -o wg0 -j ACCEPT"

    # Peer 段
    for (( i=0; i<${#WGS_PEERS_PUBKEY[@]}; i++ )); do
      echo ""
      echo "[Peer]"
      echo "PublicKey = ${WGS_PEERS_PUBKEY[$i]}"
      echo "AllowedIPs = ${WGS_PEERS_TUN_IP[$i]}"
    done
  } > /etc/wireguard/wg0.conf
  chmod 600 /etc/wireguard/wg0.conf

  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl stop   wg-quick@wg0 2>/dev/null || true
  sleep 1

  ui_spin "启动 wg-quick@wg0" systemctl start wg-quick@wg0 || {
    ui_error "wg-quick@wg0 启动失败"
    journalctl -u wg-quick@wg0 -n 30 --no-pager 2>/dev/null || true
    exit 1
  }
  sleep 2

  if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    ui_ok "WireGuard 服务端已启动，监听 UDP:${WGS_LISTEN_PORT}"
  else
    ui_error "wg-quick@wg0 未处于 active 状态"
    systemctl status wg-quick@wg0 --no-pager -l 2>/dev/null | head -30 || true
    exit 1
  fi

  error_trap_remove
}

# ============================================================
# 步骤 5：输出供中转节点使用的 [Peer] 段
# ============================================================
_wgs_step_print_peer_block() {
  _STEP_NAME="输出中转节点 Peer 配置"
  progress_step 5 5 "${_STEP_NAME}"

  # 计算服务端在隧道网络中的 IP（去掉前缀，加 /32 供对端路由）
  local tun_ip="${WGS_TUN_ADDR%%/*}"

  echo
  echo -e "\033[1;33m╔═══════════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[1;33m║  ⚠  请将以下 [Peer] 段复制到中转节点的 wg0.conf 中          ║\033[0m"
  echo -e "\033[1;33m╚═══════════════════════════════════════════════════════════════╝\033[0m"
  echo
  echo "########## BEGIN WG SERVER PEER BLOCK ##########"
  echo "[Peer]"
  echo "PublicKey = ${WGS_PUB_KEY}"
  echo "Endpoint = ${WGS_PUB_IP}:${WGS_LISTEN_PORT}"
  echo "AllowedIPs = 0.0.0.0/0"
  echo "PersistentKeepalive = 25"
  echo "########### END WG SERVER PEER BLOCK ###########"
  echo
  echo "  说明："
  echo "  • PublicKey  = 本机（出口节点）WireGuard 公钥"
  echo "  • Endpoint   = 本机公网 IP:监听端口"
  echo "  • AllowedIPs = 0.0.0.0/0 表示所有流量经此出口"
  echo "  • 中转节点还需在 [Interface] 中加入 Table=off 及对应 PostUp 路由"
  echo
  echo "  本机（出口节点）WireGuard 信息（备用）："
  echo "    公钥       : ${WGS_PUB_KEY}"
  echo "    监听端口   : ${WGS_LISTEN_PORT}"
  echo "    隧道地址   : ${WGS_TUN_ADDR}"
  echo "    公网 IP    : ${WGS_PUB_IP}"
  echo

  # 同时保存到文件方便日后查看
  mkdir -p "${WGS_STATE_DIR}"
  {
    echo "# 出口节点 WG 信息 — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "WGS_PUB_KEY=${WGS_PUB_KEY}"
    echo "WGS_PRIV_KEY=${WGS_PRIV_KEY}"
    echo "WGS_LISTEN_PORT=${WGS_LISTEN_PORT}"
    echo "WGS_TUN_ADDR=${WGS_TUN_ADDR}"
    echo "WGS_PUB_IP=${WGS_PUB_IP}"
  } > "${WGS_STATE_DIR}/server_info"
  chmod 600 "${WGS_STATE_DIR}/server_info"
  ui_info "以上信息已保存至 ${WGS_STATE_DIR}/server_info（chmod 600）"

  # 确认用户已复制
  while true; do
    if ui_confirm "已将 [Peer] 段复制保存到中转节点？" "N"; then
      ui_ok "确认完成，返回主菜单"
      break
    fi
    ui_info "请先复制上方 [Peer] 段，确认后输入 y"
  done
}

# ============================================================
# 部署摘要
# ============================================================
_wgs_print_summary() {
  echo
  echo -e "\033[1;32m╔══════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[1;32m║  ✓  出口节点（WG 服务端）部署完成                        ║\033[0m"
  echo -e "\033[1;32m╚══════════════════════════════════════════════════════════╝\033[0m"
  echo
  echo "  WireGuard  监听 UDP:${WGS_LISTEN_PORT}，已配置 NAT 转发"
  echo "  Peer 数量  ${#WGS_PEERS_PUBKEY[@]} 个中转节点"
  echo
  echo "  常用命令："
  echo "    wg show                        WireGuard 状态"
  echo "    systemctl restart wg-quick@wg0 重启 WireGuard"
  echo "    cat ${WGS_STATE_DIR}/server_info  查看本机 WG 信息"
  echo
}

# ============================================================
# 主入口
# ============================================================
wgs_run_deploy() {
  local gate_rc=0
  progress_init 5

  _wgs_step_base
  progress_gate "步骤 1 完成，继续步骤 2？" || gate_rc=$?
  [[ "${gate_rc}" -eq 2 ]] && return 0

  _wgs_step_keygen
  progress_gate "步骤 2 完成，继续录入 Peer 信息？" || gate_rc=$?
  [[ "${gate_rc}" -eq 2 ]] && return 0

  _wgs_step_collect_peers
  progress_gate "Peer 信息就绪，继续生成配置？" || gate_rc=$?
  [[ "${gate_rc}" -eq 2 ]] && return 0

  _wgs_step_setup
  progress_gate "WireGuard 已启动，继续输出 Peer 块？" || gate_rc=$?
  [[ "${gate_rc}" -eq 2 ]] && return 0

  _wgs_step_print_peer_block

  # 可选：WARP
  echo
  if ui_confirm "是否安装 WARP（可选，出口节点一般不需要）？" "N"; then
    if ! command -v warp_do_install >/dev/null 2>&1; then
      local warp_mod="${_WGS_DIR}/warp.sh"
      # shellcheck disable=SC1090
      [[ -f "${warp_mod}" ]] && source "${warp_mod}" || {
        ui_warn "未找到 warp.sh，跳过"; return
      }
    fi
    warp_do_install
  fi

  progress_complete 2>/dev/null || true
  _wgs_print_summary
}

# 独立运行支持
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ "${EUID:-0}" -eq 0 ]] || { echo "请以 root 运行"; exit 1; }
  wgs_run_deploy
fi
