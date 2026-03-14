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

HK_STATE_DIR="/etc/hk-setup"

# ============================================================
# Banner（独立运行时显示）
# ============================================================
_hk_banner() {
  clear 2>/dev/null || true
  local BG="${BG_GREEN}"
  local PAD="${BG}  ${N}"
  echo
  echo -e "${BG}$(printf '%0.s ' {1..64})${N}"
  echo -e "${PAD}${W}███████╗██╗  ██╗   ██╗████████╗  ${O}╔══════════╗${W}  ${BG}   ${N}"
  echo -e "${PAD}${W}██╔════╝██║  ╚██╗ ██╔╝╚══██╔══╝  ${O}╠══════════╬╗${W} ${BG}   ${N}"
  echo -e "${PAD}${W}█████╗  ██║   ╚████╔╝    ██║     ${O}║          ║ ${W} ${BG}   ${N}"
  echo -e "${PAD}${W}██╔══╝  ██║    ╚██╔╝     ██║     ${O}║          ║ ${W} ${BG}   ${N}"
  echo -e "${PAD}${W}██║     ███████╗██║      ██║     ${O}╚══════════╝ ${W} ${BG}   ${N}"
  echo -e "${PAD}${W}╚═╝     ╚══════╝╚═╝      ╚═╝                      ${BG}   ${N}"
  echo -e "${BG}$(printf '%0.s ' {1..64})${N}"
  echo
  echo -e "  ${O}▌${N} ${W}香港节点部署${N}  ${D}·${N}  ${C}www.flytoex.com${N}"
  echo
}

# ============================================================
# 前置检查
# ============================================================
_check_root() {
  [[ ${EUID:-0} -ne 0 ]] && { _hk_err "请以 root 运行"; exit 1; }
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
  apt-get update -y >/dev/null 2>&1 || true

  local pkgs="wireguard-tools nftables ipset curl ca-certificates dnsutils \
              net-tools iptables iproute2 cron unzip openssl"
  for p in ${pkgs}; do
    apt-get install -y "${p}" >/dev/null 2>&1 || _hk_warn "跳过可选包: ${p}"
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
  local wg0_was_up=0
  if ip link show wg0 >/dev/null 2>&1 && [[ "$(ip link show wg0 | grep -c 'UP')" -gt 0 ]]; then
    _hk_warn "检测到 wg0 运行中，暂停以获取本机网络信息..."
    systemctl stop wg-quick@wg0 2>/dev/null || true
    wg0_was_up=1
  fi

  # 探测
  HK_WAN_IF="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  HK_GW="$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -1 || true)"
  HK_PUB_IP="$(curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null \
    || curl -4 -s --max-time 8 https://ip.sb 2>/dev/null || echo '')"

  echo
  echo -e "  探测结果（可直接回车确认，或输入新值覆盖）:"
  echo
  read -r -p "  WAN 接口  [${HK_WAN_IF}]: " inp </dev/tty
  [[ -n "${inp}" ]] && HK_WAN_IF="${inp}"
  read -r -p "  默认网关  [${HK_GW}]: "   inp </dev/tty
  [[ -n "${inp}" ]] && HK_GW="${inp}"
  read -r -p "  公网 IP   [${HK_PUB_IP}]: " inp </dev/tty
  [[ -n "${inp}" ]] && HK_PUB_IP="${inp}"

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
HK_PUB_KEY="" HK_WG_KEEPALIVE=25

_input_wg_fresh() {
  _hk_step "步骤 3/6: 输入 WireGuard 配置（全新安装）"
  echo -e "  ${D}在美国节点执行 'wg show' 获取以下信息${N}"
  echo
  read -r -p "  香港节点 WG 私钥 (PrivateKey): " HK_PRIV_KEY </dev/tty
  read -r -p "  香港节点 WG 隧道地址 (如 10.0.0.3/32): " HK_WG_ADDR </dev/tty
  read -r -p "  美国节点 WG 公钥: " US_PUB_KEY </dev/tty
  read -r -p "  美国节点 WG Endpoint (IP:端口): " US_WG_ENDPOINT </dev/tty
  read -r -p "  美国节点 WG 隧道 IP (如 10.0.0.1/32): " US_WG_TUN_IP </dev/tty
  read -r -p "  V2bX 节点 ID (纯数字): " V2BX_NODE_ID </dev/tty
  read -r -p "  WG PersistentKeepalive [${HK_WG_KEEPALIVE}]: " inp </dev/tty
  [[ -n "${inp}" ]] && HK_WG_KEEPALIVE="${inp}"
  # 派生公钥
  HK_PUB_KEY="$(echo "${HK_PRIV_KEY}" | wg pubkey 2>/dev/null || true)"
}

_input_wg_restore() {
  _hk_step "步骤 3/6: 粘贴备份配置（恢复模式）"
  echo -e "  ${D}将备份输出整块粘贴，空白行结束：${N}"
  echo
  local lines=""
  while IFS= read -r line </dev/tty; do
    [[ -z "${line}" ]] && break
    lines+="${line}"$'\n'
  done
  # 解析 KEY=VALUE 格式
  while IFS='=' read -r k v; do
    [[ "${k}" =~ ^#.*$ || -z "${k}" ]] && continue
    k="${k//[[:space:]]/}"
    v="${v//[[:space:]]/}"
    case "${k}" in
      HK_PRIV_KEY)    HK_PRIV_KEY="${v}"    ;;
      HK_PUB_KEY)     HK_PUB_KEY="${v}"     ;;
      HK_WG_ADDR)     HK_WG_ADDR="${v}"     ;;
      HK_WG_PEER_PUBKEY|US_PUB_KEY) US_PUB_KEY="${v}"   ;;
      HK_WG_ENDPOINT) US_WG_ENDPOINT="${v}" ;;
      HK_WAN_IF)      HK_WAN_IF="${v}"      ;;
      HK_GW)          HK_GW="${v}"          ;;
      HK_PUB_IP)      HK_PUB_IP="${v}"      ;;
    esac
  done <<< "${lines}"
  read -r -p "  V2bX 节点 ID (纯数字): " V2BX_NODE_ID </dev/tty
  [[ -z "${HK_PUB_KEY}" ]] && \
    HK_PUB_KEY="$(echo "${HK_PRIV_KEY}" | wg pubkey 2>/dev/null || true)"
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

  mkdir -p /etc/wireguard

  # 生成 wg0.conf
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ${HK_PRIV_KEY}
Address = ${HK_WG_ADDR}
DNS = 8.8.8.8
Table = off

PostUp = \\
  # 注册 eth0rt 路由表 (100) \\
  grep -q '^100 eth0rt' /etc/iproute2/rt_tables || echo '100 eth0rt' >> /etc/iproute2/rt_tables; \\
  # eth0rt 默认路由 \\
  ip route replace default via ${HK_GW} dev ${HK_WAN_IF} table eth0rt; \\
  # 源 IP 策略路由（回包走 eth0）\\
  ip rule del pref 100 from ${HK_PUB_IP}/32 lookup eth0rt 2>/dev/null || true; \\
  ip rule add pref 100 from ${HK_PUB_IP}/32 lookup eth0rt; \\
  # WG Endpoint 走 eth0（不能走 wg0 自环）\\
  ip route replace ${US_PUB_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}; \\
  $([ -n "${PANEL_IP}" ] && echo "ip route replace ${PANEL_IP}/32 via ${HK_GW} dev ${HK_WAN_IF}; \\" || true)
  # wg0 隧道路由 \\
  ip route replace ${US_WG_TUN_IP%%/*}/32 dev wg0; \\
  # 主动出站全走 wg0 \\
  ip route replace default dev wg0

PostDown = \\
  ip rule del pref 100 from ${HK_PUB_IP}/32 lookup eth0rt 2>/dev/null || true; \\
  ip route del ${US_PUB_IP}/32 2>/dev/null || true; \\
  $([ -n "${PANEL_IP}" ] && echo "ip route del ${PANEL_IP}/32 2>/dev/null || true; \\" || true)
  ip route del ${US_WG_TUN_IP%%/*}/32 dev wg0 2>/dev/null || true; \\
  ip route replace default via ${HK_GW} dev ${HK_WAN_IF}

[Peer]
PublicKey = ${US_PUB_KEY}
Endpoint = ${US_WG_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${HK_WG_KEEPALIVE}
EOF

  chmod 600 /etc/wireguard/wg0.conf

  # 保存面板 IP
  if [[ -n "${PANEL_IP}" ]]; then
    echo "${PANEL_IP}" > "${HK_STATE_DIR}/panel_ip"
    # hosts
    local panel_host="${PANEL_API_HOST#https://}"
    grep -v "${panel_host}" /etc/hosts > /tmp/hosts.tmp && mv /tmp/hosts.tmp /etc/hosts || true
    echo "${PANEL_IP}  ${panel_host}" >> /etc/hosts
  fi

  # 启动 WireGuard
  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    systemctl restart wg-quick@wg0
  else
    systemctl start wg-quick@wg0
  fi
  sleep 3

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
  local exit_ip; exit_ip="$(curl -4 -s --max-time 10 https://ifconfig.io 2>/dev/null || echo '')"
  local exit_country; exit_country="$(curl -s --max-time 8 "https://ipinfo.io/${exit_ip}/country" 2>/dev/null || echo '')"
  echo "  出口 IP: ${exit_ip}  地区: ${exit_country}"
  if [[ "${exit_country}" == "US" ]]; then
    echo -e "  ${G}✓ 出口为美国${N}"
  else
    echo -e "  ${R}✗ 出口非美国 (${exit_country})${N}"; ok=0
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
    exit 1
  fi
  _hk_ok "WireGuard 三项验证通过"
}

# ============================================================
# 步骤五：V2bX 安装
# ============================================================
_step_install_v2bx() {
  _hk_step "步骤 5/6: 安装 V2bX"

  _hk_info "下载 V2bX 安装脚本..."
  local install_sh; install_sh="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh \
    -o "${install_sh}" || { _hk_err "V2bX 安装脚本下载失败"; return 1; }
  chmod +x "${install_sh}"

  echo
  echo -e "  ${Y}V2bX 安装器即将启动。请在菜单中选择 [1] 安装，完成后返回。${N}"
  echo
  bash "${install_sh}"
  rm -f "${install_sh}"

  # 覆盖配置文件
  mkdir -p /etc/V2bX

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

  # sing-box 路由配置
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
  echo
  echo -e "  ${O}▶ 可选：安装 WARP（Google Gemini 送中）${N}"
  echo -e "  ${D}安装后服务器可直接访问 Google / Gemini API，无需额外配置${N}"
  echo
  read -r -p "  是否现在安装 WARP？[y/N]: " ans </dev/tty
  if [[ "${ans}" =~ ^[Yy]$ ]]; then
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

  local priv="" pub="" addr="" peer_pub="" endpoint="" wan_if="" gw="" pub_ip=""
  if [[ -f /etc/wireguard/wg0.conf ]]; then
    priv="$(grep 'PrivateKey' /etc/wireguard/wg0.conf | awk '{print $3}')"
    addr="$(grep '^Address' /etc/wireguard/wg0.conf | awk '{print $3}')"
    peer_pub="$(grep 'PublicKey' /etc/wireguard/wg0.conf | tail -1 | awk '{print $3}')"
    endpoint="$(grep 'Endpoint' /etc/wireguard/wg0.conf | awk '{print $3}')"
    [[ -n "${priv}" ]] && pub="$(echo "${priv}" | wg pubkey 2>/dev/null || true)"
  fi
  wan_if="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)"
  gw="$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -1)"
  pub_ip="$(curl -4 -s --max-time 8 https://ifconfig.io 2>/dev/null || true)"

  echo
  echo -e "${Y}# ───────────────── WireGuard 备份信息 ─────────────────${N}"
  echo "HK_PRIV_KEY=${priv}"
  echo "HK_PUB_KEY=${pub}"
  echo "HK_WG_ADDR=${addr}"
  echo "HK_WG_PEER_PUBKEY=${peer_pub}"
  echo "HK_WG_ENDPOINT=${endpoint}"
  echo "HK_WG_ALLOWED_IPS=0.0.0.0/0"
  echo "HK_WG_KEEPALIVE=25"
  echo
  echo -e "${Y}# ───────────────── 网络信息 ────────────────────────────${N}"
  echo "HK_WAN_IF=${wan_if}"
  echo "HK_GW=${gw}"
  echo "HK_PUB_IP=${pub_ip}"
  echo

  _hk_warn "私钥（HK_PRIV_KEY）极度敏感，请保存在本地加密存储中"
  _hk_warn "不要通过聊天/邮件/截图传输"

  # 不恢复 wg0（即将重装系统）
}

# ============================================================
# 安装入口（全新 + 恢复复用同一流程）
# ============================================================
hk_run_install() {
  [[ "${FLYTO_VERSION:-}" == "" ]] && _hk_banner
  _check_root
  _check_secrets

  echo
  echo -e "  ${W}请选择安装模式:${N}"
  echo -e "  ${G}1.${N} 全新安装  ${D}(逐字段输入 WireGuard 配置)${N}"
  echo -e "  ${G}2.${N} 恢复模式  ${D}(粘贴备份内容一键恢复)${N}"
  echo -e "  ${G}0.${N} 返回"
  echo
  read -r -p "  请选择 [0-2]: " mode </dev/tty

  case "${mode}" in
    1)
      _step_base_system
      _step_collect_network
      _input_wg_fresh
      _step_setup_wireguard
      _step_install_v2bx
      _step_panel_ip_monitor
      _step_optional_warp
      _print_deploy_summary
      ;;
    2)
      _step_base_system
      # 恢复模式先粘贴，再采集（采集可能依赖粘贴中的 WAN_IF / GW）
      _input_wg_restore
      # 如果备份中有网络信息则直接用，否则重新采集
      if [[ -z "${HK_WAN_IF}" || -z "${HK_GW}" || -z "${HK_PUB_IP}" ]]; then
        _step_collect_network
      else
        mkdir -p "${HK_STATE_DIR}"
        echo "${HK_WAN_IF}" > "${HK_STATE_DIR}/wan_if"
        echo "${HK_GW}"     > "${HK_STATE_DIR}/gateway"
        echo "${HK_PUB_IP}" > "${HK_STATE_DIR}/pub_ip"
        _hk_ok "使用备份中的网络信息: ${HK_WAN_IF} / ${HK_GW} / ${HK_PUB_IP}"
      fi
      _step_setup_wireguard
      _step_install_v2bx
      _step_panel_ip_monitor
      _step_optional_warp
      _print_deploy_summary
      ;;
    0) return ;;
    *) _hk_err "无效选项"; return 1 ;;
  esac
}

hk_run_restore() {
  # 快捷入口，直接进入恢复模式
  [[ "${FLYTO_VERSION:-}" == "" ]] && _hk_banner
  _check_root
  _check_secrets
  _step_base_system
  _input_wg_restore
  if [[ -z "${HK_WAN_IF}" || -z "${HK_GW}" || -z "${HK_PUB_IP}" ]]; then
    _step_collect_network
  fi
  _step_setup_wireguard
  _step_install_v2bx
  _step_panel_ip_monitor
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
