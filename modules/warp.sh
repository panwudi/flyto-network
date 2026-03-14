#!/usr/bin/env bash
# ============================================================
# modules/warp.sh — WARP Google 送中模块
# 可由 flyto.sh 加载，也可独立运行
#
# 功能: 在服务器上安装 Cloudflare WARP，通过 iptables + ipset
#       透明代理将 Google/Gemini IP 段的 TCP 流量经 WARP 转发
#
# 项目地址: https://github.com/panwudi/flyto-network
# 官网:     www.flytoex.com
# ============================================================

WARP_VERSION="2.0.0"
WARP_REPO_RAW="https://raw.githubusercontent.com/panwudi/flyto-network/main/modules/warp.sh"

# ── 颜色（兼容独立运行时未定义的场景）──────────────────────
W="${W:-\033[1;37m}"
O="${O:-\033[38;5;208m}"
G="${G:-\033[1;32m}"
R="${R:-\033[1;31m}"
Y="${Y:-\033[1;33m}"
C="${C:-\033[1;36m}"
D="${D:-\033[2;37m}"
N="${N:-\033[0m}"
BG_GREEN="${BG_GREEN:-\033[48;5;22m}"

_info()    { echo -e "${C}[WARP]${N} $*"; }
_ok()      { echo -e "${G}[WARP]${N} $*"; }
_warn()    { echo -e "${Y}[WARP]${N} $*" >&2; }
_err()     { echo -e "${R}[WARP]${N} $*" >&2; }

# ── 运行时配置文件（端口唯一来源）──────────────────────────
WARP_ENV_FILE="/etc/warp-google/env"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="${TPROXY_PORT:-12345}"
[[ -f "${WARP_ENV_FILE}" ]] && source "${WARP_ENV_FILE}" 2>/dev/null || true

WARP_CACHE_DIR="/etc/warp-google"
IPSET_NAME="warp_google4"
NAT_CHAIN="WARP_GOOGLE"
QUIC_CHAIN="WARP_GOOGLE_QUIC"
IPV4_CACHE_FILE="${WARP_CACHE_DIR}/google_ipv4.txt"
TPROXY_BACKEND_FILE="${WARP_CACHE_DIR}/tproxy_backend"
GAI_MARK="# flyto-network: prefer ipv4"

STATIC_GOOGLE_IPV4="
8.8.4.0/24 8.8.8.0/24 8.34.208.0/20 8.35.192.0/20 23.236.48.0/20
23.251.128.0/19 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12 35.224.0.0/12
35.240.0.0/13 64.18.0.0/20 64.233.160.0/19 66.102.0.0/20 66.249.64.0/19
70.32.128.0/19 72.14.192.0/18 74.114.24.0/21 74.125.0.0/16 104.132.0.0/14
104.154.0.0/15 104.196.0.0/14 107.167.160.0/19 107.178.192.0/18
108.59.80.0/20 108.170.192.0/18 108.177.0.0/17 130.211.0.0/16
136.112.0.0/12 142.250.0.0/15 146.148.0.0/17 162.216.148.0/22
162.222.176.0/21 172.110.32.0/21 172.217.0.0/16 172.253.0.0/16
173.194.0.0/16 173.255.112.0/20 192.158.28.0/22 192.178.0.0/15
193.186.4.0/24 199.36.154.0/23 199.36.156.0/24 199.192.112.0/22
199.223.232.0/21 203.208.0.0/14 207.223.160.0/20 208.65.152.0/22
208.68.108.0/22 208.81.188.0/22 208.117.224.0/19 209.85.128.0/17
216.58.192.0/19 216.73.80.0/20 216.239.32.0/19
"

# ── Banner（独立运行时显示）─────────────────────────────────
_warp_banner() {
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
  echo -e "  ${O}▌${N} ${W}WARP — Google Gemini 送中${N}  ${D}·${N}  v${WARP_VERSION}  ${D}·${N}  ${C}www.flytoex.com${N}"
  echo
}

# ============================================================
# 系统检测
# ============================================================
WARP_OS="" WARP_OS_VER="" WARP_CODENAME=""

_detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    WARP_OS="${ID:-}" WARP_OS_VER="${VERSION_ID:-}" WARP_CODENAME="${VERSION_CODENAME:-}"
  else
    _err "无法检测系统"; return 1
  fi
  [[ -z "${WARP_CODENAME}" ]] && WARP_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  if [[ -z "${WARP_CODENAME}" ]]; then
    case "${WARP_OS}" in
      ubuntu) case "${WARP_OS_VER}" in
        20.04*) WARP_CODENAME="focal" ;; 22.04*) WARP_CODENAME="jammy" ;;
        24.04*) WARP_CODENAME="noble" ;; esac ;;
      debian) case "${WARP_OS_VER}" in
        11*) WARP_CODENAME="bullseye" ;; 12*) WARP_CODENAME="bookworm" ;; esac ;;
    esac
  fi
}

_in_container() {
  [[ -f /.dockerenv ]] && return 0
  grep -qE 'lxc|docker|container' /proc/1/cgroup 2>/dev/null && return 0
  local v; v="$(systemd-detect-virt --container 2>/dev/null || true)"
  [[ "${v}" != "none" && -n "${v}" ]] && return 0
  return 1
}

# ============================================================
# 内核模块 & iptables
# ============================================================
_ensure_modules() {
  for m in ip_set ip_set_hash_net xt_set nf_nat; do
    modprobe "${m}" 2>/dev/null || true
  done
}

# ============================================================
# DNS
# ============================================================
_setup_dns() {
  _info "配置 Cloudflare DNS..."
  if ! _in_container && command -v systemctl >/dev/null 2>&1 \
      && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-flyto-warp.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=1.1.1.1 1.0.0.1
DNSStubListener=yes
EOF
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    _ok "DNS 已配置 (systemd-resolved)"
    return
  fi
  if [[ -L /etc/resolv.conf ]]; then
    _warn "resolv.conf 是符号链接，跳过直写"; return
  fi
  local test_f="/etc/.flyto-dns-test.$$"
  if ! touch "${test_f}" 2>/dev/null; then
    _warn "resolv.conf 目录不可写，跳过"; return
  fi
  rm -f "${test_f}"
  # chattr +i 检测
  if command -v lsattr >/dev/null 2>&1 \
      && lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
    _info "resolv.conf 有 chattr +i（V2bX 等设置），临时解除..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cp /etc/resolv.conf /etc/resolv.conf.flyto-bak
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
  else
    cp /etc/resolv.conf /etc/resolv.conf.flyto-bak 2>/dev/null || true
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
  fi
  _ok "DNS 已配置 (1.1.1.1)"
}

# ============================================================
# 依赖安装
# ============================================================
_install_deps() {
  _info "安装依赖..."
  case "${WARP_OS}" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      for p in curl ca-certificates gnupg lsb-release iptables ipset python3 dnsutils; do
        apt-get install -y "${p}" >/dev/null 2>&1 || _warn "跳过: ${p}"
      done ;;
    centos|rhel|rocky|almalinux|fedora)
      local pm="yum"; command -v dnf >/dev/null 2>&1 && pm="dnf"
      "${pm}" install -y epel-release >/dev/null 2>&1 || true
      for p in curl ca-certificates iptables ipset python3 bind-utils; do
        "${pm}" install -y "${p}" >/dev/null 2>&1 || _warn "跳过: ${p}"
      done ;;
    *) _err "不支持的系统: ${WARP_OS}"; return 1 ;;
  esac
  _ok "依赖就绪"
}

# ============================================================
# WARP 客户端安装
# ============================================================
_install_warp_client() {
  if command -v warp-cli >/dev/null 2>&1; then
    _ok "warp-cli 已存在，跳过安装"; return 0
  fi
  _info "安装 Cloudflare WARP..."
  case "${WARP_OS}" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      local arch; arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
      install -m 0755 -d /usr/share/keyrings
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
      echo "deb [arch=${arch} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${WARP_CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
      apt-get update -y >/dev/null 2>&1
      apt-get install -y cloudflare-warp >/dev/null 2>&1 || { _err "WARP 安装失败"; return 1; } ;;
    centos|rhel|rocky|almalinux|fedora)
      rpm --import https://pkg.cloudflareclient.com/pubkey.gpg 2>/dev/null || true
      cat > /etc/yum.repos.d/cloudflare-warp.repo <<'REPO'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
REPO
      local pm="yum"; command -v dnf >/dev/null 2>&1 && pm="dnf"
      "${pm}" install -y cloudflare-warp || { _err "WARP 安装失败"; return 1; } ;;
    *) _err "不支持的系统: ${WARP_OS}"; return 1 ;;
  esac
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  _ok "WARP 客户端已安装"
}

# ============================================================
# 端口冲突检测
# ============================================================
_port_held_externally() {
  ss -tlnp 2>/dev/null | grep -q ":${1}[[:space:]]"
}

_find_free_proxy_port() {
  local port="${WARP_PROXY_PORT}" limit=$((WARP_PROXY_PORT + 20))
  while [[ ${port} -lt ${limit} ]]; do
    if ! _port_held_externally "${port}"; then
      WARP_PROXY_PORT="${port}"; return 0
    fi
    _warn "端口 ${port} 被占用，尝试 $((port+1))..."
    port=$((port + 1))
  done
  WARP_PROXY_PORT="${port}"
}

# ============================================================
# WARP 配置
# ============================================================
_configure_warp() {
  _info "配置 WARP proxy 模式 (端口 ${WARP_PROXY_PORT})..."

  # 注册复用
  local reg_ok=0
  warp-cli --accept-tos registration show >/dev/null 2>&1 && reg_ok=1 || true
  if [[ ${reg_ok} -eq 0 ]]; then
    _info "创建新 WARP 注册..."
    warp-cli --accept-tos registration new >/dev/null 2>&1 \
      || warp-cli --accept-tos register >/dev/null 2>&1 || true
  else
    _info "复用现有 WARP 注册"
  fi

  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  _find_free_proxy_port

  # 连接 + 端口冲突三段重试
  local attempt=0 connected=0 status=""
  while [[ ${attempt} -lt 3 && ${connected} -eq 0 ]]; do
    warp-cli --accept-tos proxy port "${WARP_PROXY_PORT}" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      status="$(warp-cli --accept-tos status 2>/dev/null || echo '')"
      echo "${status}" | grep -qi 'Connected' && { connected=1; break; }
      sleep 1; printf "."
    done
    echo
    [[ ${connected} -eq 1 ]] && break
    if [[ ${attempt} -eq 0 ]]; then
      _info "重启 warp-svc 以释放端口..."
      systemctl restart warp-svc >/dev/null 2>&1 || true; sleep 3
    else
      WARP_PROXY_PORT=$((WARP_PROXY_PORT + 1))
      _warn "切换至端口 ${WARP_PROXY_PORT}..."
    fi
    attempt=$((attempt + 1))
  done

  [[ ${connected} -eq 1 ]] && _ok "WARP 已连接，端口 ${WARP_PROXY_PORT}" \
    || _warn "WARP 连接失败，运行 'warp test' 诊断"

  # 写入 ENV_FILE
  mkdir -p "${WARP_CACHE_DIR}"
  cat > "${WARP_ENV_FILE}" <<EOF
# flyto-network warp runtime config — auto-generated
WARP_PROXY_PORT=${WARP_PROXY_PORT}
TPROXY_PORT=${TPROXY_PORT}
EOF
  _ok "端口配置已写入 ${WARP_ENV_FILE}"
  _sync_v2bx_ai_route
}

_sync_v2bx_ai_route() {
  local updater="/usr/local/bin/update-ai-warp-route.sh"
  if [[ ! -x "${updater}" ]]; then
    _info "未检测到 V2bX AI 路由同步脚本，跳过"
    return 0
  fi
  if "${updater}" >/dev/null 2>&1; then
    _ok "V2bX AI 路由已同步"
  else
    _warn "V2bX AI 路由同步失败，请手动执行: ${updater}"
  fi
}

# ============================================================
# ipt2socks / Python fallback
# ============================================================
_is_elf() {
  local f="$1"; [[ -f "${f}" ]] || return 1
  local m; m="$(od -An -N4 -tx1 "${f}" 2>/dev/null | tr -d ' \n' | head -c8)"
  [[ "${m}" == "7f454c46" ]]
}

_install_ipt2socks() {
  [[ -x /usr/local/bin/ipt2socks ]] && { _ok "ipt2socks 已存在"; return 0; }
  local arch; arch="$(uname -m)"
  local akey
  case "${arch}" in x86_64) akey="x86_64" ;; aarch64|arm64) akey="aarch64" ;;
    *) _info "无 ipt2socks 预编译包 (${arch})"; return 1 ;; esac
  _info "下载 ipt2socks (${akey})..."
  local tmp; tmp="$(mktemp)"
  local url
  url="$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/zfl9/ipt2socks/releases/latest" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d.get('assets',[]):
  n=a.get('name','')
  if '${akey}' in n and not n.endswith(('.sha256','.md5')):
    print(a['browser_download_url']);break
" 2>/dev/null || true)"
  [[ -z "${url}" ]] && url="https://github.com/zfl9/ipt2socks/releases/download/v1.1.3/ipt2socks_v1.1.3_linux_${akey}"
  if ! curl -fsSL --max-time 60 "${url}" -o "${tmp}" 2>/dev/null || ! _is_elf "${tmp}"; then
    rm -f "${tmp}"; _warn "ipt2socks 下载失败"; return 1
  fi
  install -m 755 "${tmp}" /usr/local/bin/ipt2socks
  rm -f "${tmp}"
  _ok "ipt2socks 安装完成"
}

_write_python_tproxy() {
  cat > /usr/local/bin/flyto-tproxy-py <<'PYEOF'
#!/usr/bin/env python3
"""flyto-tproxy-py — asyncio transparent SOCKS5 redirector (fallback)
www.flytoex.com
"""
import asyncio, os, socket, struct, signal

def _load_env():
    cfg = {}
    try:
        with open('/etc/warp-google/env') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    cfg[k.strip()] = v.strip()
    except FileNotFoundError: pass
    return cfg

_cfg = _load_env()
_LISTEN = ('127.0.0.1', int(_cfg.get('TPROXY_PORT', os.environ.get('TPROXY_PORT', 12345))))
_SOCKS5 = ('127.0.0.1', int(_cfg.get('WARP_PROXY_PORT', os.environ.get('WARP_PROXY_PORT', 40000))))
_SO_ORIG_DST = 80

def _get_orig_dst(sock):
    raw = sock.getsockopt(socket.IPPROTO_IP, _SO_ORIG_DST, 16)
    return socket.inet_ntoa(raw[4:8]), struct.unpack_from('!H', raw, 2)[0]

async def _pipe(r, w):
    try:
        while chunk := await r.read(65536):
            w.write(chunk); await w.drain()
    except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError, OSError): pass
    finally:
        try: w.close(); await w.wait_closed()
        except Exception: pass

async def _handshake(r, w, ip, port):
    w.write(b'\x05\x01\x00'); await w.drain()
    resp = await asyncio.wait_for(r.readexactly(2), 10)
    if resp != b'\x05\x00': raise ConnectionError(f'socks5 auth: {resp!r}')
    w.write(b'\x05\x01\x00\x01' + socket.inet_aton(ip) + struct.pack('!H', port))
    await w.drain()
    resp = await asyncio.wait_for(r.readexactly(10), 10)
    if resp[1] != 0: raise ConnectionError(f'socks5 connect: {resp[1]}')

async def _handle(cr, cw):
    sr = sw = None
    try:
        dst_ip, dst_port = _get_orig_dst(cw.get_extra_info('socket'))
        sr, sw = await asyncio.wait_for(asyncio.open_connection(*_SOCKS5), 10)
        await _handshake(sr, sw, dst_ip, dst_port)
        await asyncio.gather(_pipe(cr, sw), _pipe(sr, cw))
    except Exception: pass
    finally:
        for w in (cw, sw):
            if w:
                try: w.close(); await w.wait_closed()
                except Exception: pass

async def _serve():
    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: stop.set_result(None) if not stop.done() else None)
    srv = await asyncio.start_server(_handle, *_LISTEN, reuse_address=True)
    print(f'flyto-tproxy-py {_LISTEN[0]}:{_LISTEN[1]} -> socks5://{_SOCKS5[0]}:{_SOCKS5[1]}', flush=True)
    async with srv: await stop

if __name__ == '__main__': asyncio.run(_serve())
PYEOF
  chmod +x /usr/local/bin/flyto-tproxy-py
}

_install_tproxy_backend() {
  _info "安装透明代理后端..."
  mkdir -p "${WARP_CACHE_DIR}"
  # 清理旧版 redsocks
  systemctl stop redsocks 2>/dev/null || true
  systemctl disable redsocks 2>/dev/null || true
  rm -f /etc/redsocks.conf /etc/systemd/system/redsocks.service

  local backend="python"
  _install_ipt2socks && backend="ipt2socks"
  [[ "${backend}" == "python" ]] && { _warn "使用 Python tproxy 后端"; _write_python_tproxy; }
  echo "${backend}" > "${TPROXY_BACKEND_FILE}"

  local exec_start
  if [[ "${backend}" == "ipt2socks" ]]; then
    exec_start='/usr/local/bin/ipt2socks -4 -b 127.0.0.1 -l ${TPROXY_PORT} -s 127.0.0.1 -p ${WARP_PROXY_PORT} -j 2'
  else
    exec_start='/usr/local/bin/flyto-tproxy-py'
  fi

  cat > /etc/systemd/system/warp-tproxy.service <<EOF
[Unit]
Description=WARP transparent proxy (${backend}) — FLYTOex Network
After=network-online.target
[Service]
Type=simple
EnvironmentFile=${WARP_ENV_FILE}
ExecStart=${exec_start}
Restart=always
RestartSec=3
StandardOutput=null
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now warp-tproxy >/dev/null 2>&1 || true
  _ok "透明代理就绪 (${backend})"
}

# ============================================================
# warp-google 管理脚本
# ============================================================
_write_warp_google() {
  cat > /usr/local/bin/warp-google <<'WGEOF'
#!/usr/bin/env bash
# warp-google — FLYTOex Network www.flytoex.com
set -euo pipefail
ENV_FILE="/etc/warp-google/env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" || true
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="${TPROXY_PORT:-12345}"
IPSET_NAME="warp_google4"
NAT_CHAIN="WARP_GOOGLE"
QUIC_CHAIN="WARP_GOOGLE_QUIC"
IPV4_CACHE="/etc/warp-google/google_ipv4.txt"
GOOG_JSON="https://www.gstatic.com/ipranges/goog.json"

STATIC_IPS="8.8.4.0/24 8.8.8.0/24 8.34.208.0/20 34.0.0.0/9 35.184.0.0/13
35.192.0.0/12 35.224.0.0/12 64.233.160.0/19 66.102.0.0/20 66.249.64.0/19
72.14.192.0/18 74.125.0.0/16 104.132.0.0/14 104.154.0.0/15 104.196.0.0/14
108.177.0.0/17 130.211.0.0/16 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16
173.194.0.0/16 192.178.0.0/15 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19"

_ipset_apply() {
  for m in ip_set ip_set_hash_net xt_set; do modprobe "${m}" 2>/dev/null || true; done
  ipset create "${IPSET_NAME}" hash:net family inet -exist
  local tmp="${IPSET_NAME}_tmp"
  ipset create "${tmp}" hash:net family inet -exist
  ipset flush "${tmp}" 2>/dev/null || true
  local list
  [[ -s "${IPV4_CACHE}" ]] && list="$(cat "${IPV4_CACHE}")" || list="${STATIC_IPS}"
  while IFS= read -r cidr; do
    [[ -z "${cidr}" ]] && continue
    ipset add "${tmp}" "${cidr}" -exist 2>/dev/null || true
  done <<< "${list}"
  ipset swap "${tmp}" "${IPSET_NAME}" 2>/dev/null || true
  ipset destroy "${tmp}" 2>/dev/null || true
}

_iptables_apply() {
  iptables -t nat    -D OUTPUT -j "${NAT_CHAIN}"  2>/dev/null || true
  iptables -t nat    -F "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t nat    -X "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t filter -D OUTPUT -j "${QUIC_CHAIN}" 2>/dev/null || true
  iptables -t filter -F "${QUIC_CHAIN}"            2>/dev/null || true
  iptables -t filter -X "${QUIC_CHAIN}"            2>/dev/null || true
  iptables -t nat -N "${NAT_CHAIN}" 2>/dev/null || true
  iptables -t nat -A "${NAT_CHAIN}" -p tcp -m set --match-set "${IPSET_NAME}" dst \
    -j REDIRECT --to-ports "${TPROXY_PORT}"
  iptables -t nat -I OUTPUT 1 -j "${NAT_CHAIN}"
  iptables -t filter -N "${QUIC_CHAIN}" 2>/dev/null || true
  iptables -t filter -A "${QUIC_CHAIN}" -p udp --dport 443 \
    -m set --match-set "${IPSET_NAME}" dst -j REJECT
  iptables -t filter -I OUTPUT 1 -j "${QUIC_CHAIN}"
}

_iptables_clean() {
  iptables -t nat    -D OUTPUT -j "${NAT_CHAIN}"  2>/dev/null || true
  iptables -t nat    -F "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t nat    -X "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t filter -D OUTPUT -j "${QUIC_CHAIN}" 2>/dev/null || true
  iptables -t filter -F "${QUIC_CHAIN}"            2>/dev/null || true
  iptables -t filter -X "${QUIC_CHAIN}"            2>/dev/null || true
}

case "${1:-}" in
  start)
    warp-cli connect 2>/dev/null || true
    systemctl restart warp-tproxy >/dev/null 2>&1 || true
    _ipset_apply; _iptables_apply
    echo "[warp-google] 已启动" ;;
  stop)
    systemctl stop warp-tproxy >/dev/null 2>&1 || true
    _iptables_clean
    echo "[warp-google] 已停止" ;;
  restart) "${0}" stop; sleep 0.5; "${0}" start ;;
  update)
    echo "[warp-google] 更新 Google IP 段..."
    mkdir -p /etc/warp-google
    local_tmp="$(mktemp)"; ok=0
    curl -fsSL -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" --max-time 30 \
      "${GOOG_JSON}" -o "${local_tmp}" 2>/dev/null && ok=1
    [[ ${ok} -eq 0 ]] && curl -fsSL --max-time 30 "${GOOG_JSON}" -o "${local_tmp}" 2>/dev/null && ok=1
    if [[ ${ok} -eq 1 ]]; then
      python3 -c "
import json,sys
d=json.load(open('${local_tmp}'))
print('\n'.join(sorted({p['ipv4Prefix'] for p in d.get('prefixes',[]) if 'ipv4Prefix' in p})))
" > "${IPV4_CACHE}" 2>/dev/null || true
      [[ -s "${IPV4_CACHE}" ]] && echo "[warp-google] 已更新 $(wc -l < "${IPV4_CACHE}") 条" \
        || echo "[warp-google] 解析失败，保留旧列表"
    else
      echo "[warp-google] 下载失败"
    fi
    rm -f "${local_tmp}" ;;
  status)
    echo "=== ipset ===" ; ipset list "${IPSET_NAME}" 2>/dev/null | head -8 || echo "不存在"
    echo "=== NAT ===" ; iptables -t nat -S "${NAT_CHAIN}" 2>/dev/null || echo "无"
    echo "=== 后端 ===" ; systemctl is-active warp-tproxy 2>/dev/null || echo "未运行"
    echo "=== 端口 ===" ; cat "${ENV_FILE}" 2>/dev/null ;;
  *) echo "用法: warp-google {start|stop|restart|update|status}" ;;
esac
WGEOF
  chmod +x /usr/local/bin/warp-google
}

# ============================================================
# warp 管理命令
# ============================================================
_write_warp_cmd() {
  cat > /usr/local/bin/warp <<WARPCMD
#!/usr/bin/env bash
# warp — FLYTOex Network www.flytoex.com
set -euo pipefail
ENV_FILE="/etc/warp-google/env"
[[ -f "\${ENV_FILE}" ]] && source "\${ENV_FILE}" || true
WARP_PROXY_PORT="\${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="\${TPROXY_PORT:-12345}"
VER="${WARP_VERSION}"
G='\033[1;32m' R='\033[1;31m' Y='\033[1;33m' C='\033[1;36m' W='\033[1;37m' N='\033[0m'

_sync_ai_route() {
  local updater="/usr/local/bin/update-ai-warp-route.sh"
  if [[ -x "\${updater}" ]]; then
    "\${updater}" >/dev/null 2>&1 || echo -e "\${Y}[WARN]\${N} AI 路由同步失败: \${updater}"
  fi
}

case "\${1:-}" in
  status)
    echo
    _gok=0
    curl -s --max-time 6 -o /dev/null -w "%{http_code}" https://www.google.com 2>/dev/null \
      | grep -q "200" && _gok=1
    if [[ \$_gok -eq 1 ]]; then
      echo -e "\${G}╔══════════════════════════════════════╗\${N}"
      echo -e "\${G}║  ✓  Google / Gemini 已连通           ║\${N}"
      echo -e "\${G}╚══════════════════════════════════════╝\${N}"
    else
      echo -e "\${R}╔══════════════════════════════════════╗\${N}"
      echo -e "\${R}║  ✗  Google / Gemini 未连通           ║\${N}"
      echo -e "\${R}╚══════════════════════════════════════╝\${N}"
      echo -e "  \${Y}运行 'warp test' 查看逐层诊断\${N}"
    fi
    echo
    _ws="\$(warp-cli status 2>/dev/null || echo '未运行')"
    echo "\${_ws}" | grep -qi 'Connected' \
      && echo -e "  WARP     \${G}● 已连接\${N}  端口 \${WARP_PROXY_PORT}" \
      || echo -e "  WARP     \${R}● 未连接\${N}"
    systemctl is-active --quiet warp-tproxy 2>/dev/null \
      && echo -e "  tproxy   \${G}● 运行中\${N}  :\${TPROXY_PORT}" \
      || echo -e "  tproxy   \${R}● 未运行\${N}"
    _cnt="\$(ipset list warp_google4 2>/dev/null | grep -c '/' || echo 0)"
    [[ "\$_cnt" -gt 0 ]] \
      && echo -e "  ipset    \${G}● \${_cnt} 条 Google IP 段\${N}" \
      || echo -e "  ipset    \${R}● 空\${N}"
    iptables -t nat -S WARP_GOOGLE 2>/dev/null | grep -q REDIRECT \
      && echo -e "  iptables \${G}● 规则已加载\${N}" \
      || echo -e "  iptables \${R}● 规则缺失\${N}"
    echo
    echo -e "  \${Y}详细诊断: warp test  |  原始信息: warp debug\${N}"
    echo -e "  \${C}www.flytoex.com\${N}"
    echo ;;

  start)   warp-cli connect 2>/dev/null || true; /usr/local/bin/warp-google start; _sync_ai_route ;;
  stop)    /usr/local/bin/warp-google stop; warp-cli disconnect 2>/dev/null || true ;;
  restart) /usr/local/bin/warp-google restart; _sync_ai_route ;;

  test)
    ok=1
    echo "--- [1] WARP 客户端状态 ---"
    ws="\$(warp-cli status 2>/dev/null || echo '无法获取')"
    echo "\${ws}"
    echo "\${ws}" | grep -qi 'Connected' \
      && echo -e "  \${G}✓ WARP 已连接\${N}" \
      || { echo "  ✗ WARP 未连接"; ok=0; }
    echo
    echo "--- [2] SOCKS5 端口 (:\${WARP_PROXY_PORT}) ---"
    ss -tlnp 2>/dev/null | grep -q ":\${WARP_PROXY_PORT}" \
      && echo -e "  \${G}✓ 端口监听中\${N}" \
      || { echo "  ✗ 未监听"; ok=0; }
    echo
    echo "--- [3] SOCKS5 直连测试 ---"
    sc="\$(curl -s --max-time 10 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" \
      -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null || echo '000')"
    echo "  HTTP: \${sc}"
    [[ "\${sc}" == "200" ]] \
      && echo -e "  \${G}✓ SOCKS5 → Google 正常\${N}" \
      || { echo "  ✗ SOCKS5 不通"; ok=0; }
    echo
    echo "--- [4] warp-tproxy 进程 ---"
    systemctl is-active --quiet warp-tproxy 2>/dev/null \
      && echo -e "  \${G}✓ 运行中 (backend: \$(cat /etc/warp-google/tproxy_backend 2>/dev/null || echo ?))\${N}" \
      || { echo "  ✗ 未运行"; ok=0; }
    echo
    echo "--- [5] iptables 规则 ---"
    iptables -t nat -S WARP_GOOGLE 2>/dev/null | grep -q REDIRECT \
      && echo -e "  \${G}✓ REDIRECT 规则存在\${N}" \
      || { echo "  ✗ 规则缺失"; ok=0; }
    echo
    echo "--- [6] ipset 条目数 ---"
    cnt="\$(ipset list warp_google4 2>/dev/null | grep -c '/' || echo 0)"
    [[ "\${cnt}" -gt 0 ]] \
      && echo -e "  \${G}✓ \${cnt} 条 Google IP 段\${N}" \
      || { echo "  ✗ ipset 为空"; ok=0; }
    echo
    echo "--- [7] 透明代理端到端 ---"
    e2e="\$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null || echo '000')"
    gem="\$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' https://gemini.google.com 2>/dev/null || echo '000')"
    echo "  Google   HTTP \${e2e}"
    echo "  Gemini   HTTP \${gem}"
    [[ "\${e2e}" == "200" ]] \
      && echo -e "  \${G}✓ 透明代理正常\${N}" \
      || { echo "  ✗ 透明代理不通"; ok=0; }
    echo
    echo "--- [8] WARP 节点信息 ---"
    curl -s --max-time 10 \
      -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
      | grep -E "^(warp|loc|ip)=" || echo "  (需 SOCKS5 正常才可获取)"
    echo
    if [[ \${ok} -eq 1 ]]; then
      echo -e "\${G}╔══════════════════════════════════════════════╗\${N}"
      echo -e "\${G}║  ✓  Google Gemini 送中成功！全部检测通过     ║\${N}"
      echo -e "\${G}╚══════════════════════════════════════════════╝\${N}"
      echo -e "  \${C}www.flytoex.com\${N}"
    else
      echo -e "\${R}[✗] 存在异常，请根据上方提示排查\${N}"
      echo    "    详细日志: warp debug"
    fi ;;

  debug)
    echo "=== warp-cli status ==="; warp-cli status 2>&1 || true
    echo; echo "=== warp-tproxy ==="; systemctl status warp-tproxy --no-pager -l 2>&1 | head -25 || true
    echo; echo "=== 端口监听 ==="
    ss -tlnp 2>/dev/null | grep -E ":\${WARP_PROXY_PORT}|:\${TPROXY_PORT}" || echo "无相关端口"
    echo; echo "=== iptables NAT ==="; iptables -t nat -L OUTPUT -v --line-numbers 2>/dev/null | head -10 || true
    echo; echo "=== ipset ==="; ipset list warp_google4 2>/dev/null | head -6 || echo "不存在"
    echo; echo "=== ENV ==="; cat "\${ENV_FILE}" 2>/dev/null || echo "无"
    echo; echo "=== 近期日志 ==="; journalctl -u warp-tproxy -n 20 --no-pager 2>/dev/null || true ;;

  ip)
    echo "直连 IP:"; curl -4 -s --max-time 8 https://ip.sb || echo "获取失败"
    echo; echo "WARP IP:"
    curl -s --max-time 8 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" https://ip.sb || echo "获取失败"
    echo ;;

  update) /usr/local/bin/warp-google update; /usr/local/bin/warp-google restart; _sync_ai_route ;;

  uninstall)
    read -r -p "确定卸载 WARP？[y/N]: " c </dev/tty
    [[ "\${c}" =~ ^[Yy]\$ ]] || { echo "已取消"; exit 0; }
    /usr/local/bin/warp-google stop 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true
    for svc in warp-keepalive.timer warp-keepalive.service warp-tproxy.service warp-svc.service; do
      systemctl disable --now "\${svc}" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/warp-keepalive.{timer,service} \
          /etc/systemd/system/warp-tproxy.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/bin/warp-google /usr/local/bin/flyto-tproxy-py \
          /usr/local/bin/ipt2socks /usr/local/bin/warp-keepalive
    iptables -t nat    -D OUTPUT -j WARP_GOOGLE      2>/dev/null || true
    iptables -t nat    -F WARP_GOOGLE                 2>/dev/null || true
    iptables -t nat    -X WARP_GOOGLE                 2>/dev/null || true
    iptables -t filter -D OUTPUT -j WARP_GOOGLE_QUIC 2>/dev/null || true
    iptables -t filter -F WARP_GOOGLE_QUIC            2>/dev/null || true
    iptables -t filter -X WARP_GOOGLE_QUIC            2>/dev/null || true
    ipset destroy warp_google4 2>/dev/null || true
    rm -rf /etc/warp-google
    # 卸载 cloudflare-warp 包
    if [[ -f /etc/os-release ]]; then
      source /etc/os-release 2>/dev/null || true
      case "\${ID:-}" in
        ubuntu|debian) apt-get remove -y cloudflare-warp 2>/dev/null || true
          rm -f /etc/apt/sources.list.d/cloudflare-client.list \
                /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg ;;
        *) (command -v dnf && dnf || yum) remove -y cloudflare-warp 2>/dev/null || true
           rm -f /etc/yum.repos.d/cloudflare-warp.repo ;;
      esac
    fi
    rm -f /usr/local/bin/warp
    echo "WARP 卸载完成 — www.flytoex.com" ;;

  *)
    echo -e "\${W}WARP 管理工具 v\${VER}\${N}  \${C}Google Gemini 送中\${N}  \${C}www.flytoex.com\${N}"
    echo
    echo "用法: warp <命令>"
    echo
    for cmd_desc in \
      "status:状态（含 Google 连通性）" \
      "start:启动" "stop:停止" "restart:重启" \
      "test:8 层逐层诊断" "debug:原始诊断（日志/端口/规则）" \
      "ip:查看直连 IP 与 WARP IP" \
      "update:更新 Google IP 段" \
      "uninstall:完整卸载"; do
      printf "  \${G}%-12s\${N} %s\n" "\${cmd_desc%%:*}" "\${cmd_desc##*:}"
    done ;;
esac
WARPCMD
  chmod +x /usr/local/bin/warp
}

# ============================================================
# Keepalive
# ============================================================
_write_keepalive() {
  cat > /usr/local/bin/warp-keepalive <<'KEOF'
#!/usr/bin/env bash
ENV_FILE="/etc/warp-google/env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" || true
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
exec 9>/run/warp-keepalive.lock; flock -n 9 || exit 0
if ! curl -s --max-time 10 -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" \
    -o /dev/null https://www.google.com; then
  logger -t warp-keepalive "proxy down, reconnecting..."
  warp-cli disconnect 2>/dev/null || true; sleep 2
  warp-cli connect   2>/dev/null || true; sleep 3
fi
if ! curl -s --max-time 10 -o /dev/null https://www.google.com; then
  logger -t warp-keepalive "tproxy down, restarting..."
  systemctl restart warp-tproxy >/dev/null 2>&1 && logger -t warp-keepalive "ok" || logger -t warp-keepalive "failed"
fi
KEOF
  chmod +x /usr/local/bin/warp-keepalive

  cat > /etc/systemd/system/warp-keepalive.service <<'SVC'
[Unit]
Description=WARP keepalive — FLYTOex Network
[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-keepalive
SVC

  cat > /etc/systemd/system/warp-keepalive.timer <<'TIMER'
[Unit]
Description=WARP keepalive timer (every 10min)
[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable --now warp-keepalive.timer >/dev/null 2>&1 || true
  _ok "keepalive 已配置 (每 10 分钟)"
}

_write_systemd_service() {
  cat > /etc/systemd/system/warp-google.service <<EOF
[Unit]
Description=WARP Google Transparent Proxy — FLYTOex Network
After=network-online.target warp-svc.service warp-tproxy.service
Wants=network-online.target warp-svc.service warp-tproxy.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable warp-google 2>/dev/null || true
}

# ============================================================
# 对外入口 — 完整安装
# ============================================================
warp_do_install() {
  # 独立运行时显示 banner
  [[ "${FLYTO_VERSION:-}" == "" ]] && _warp_banner

  _info "开始安装 WARP v${WARP_VERSION}..."
  [[ ${EUID:-0} -ne 0 ]] && { _err "请以 root 运行"; return 1; }

  _detect_os
  _info "系统: ${WARP_OS} ${WARP_OS_VER} (${WARP_CODENAME:-unknown})"
  _ensure_modules
  _setup_dns
  _install_deps
  _install_warp_client

  # IPv4 优先
  if ! grep -qF "${GAI_MARK}" /etc/gai.conf 2>/dev/null; then
    { echo "${GAI_MARK}"; echo "precedence ::ffff:0:0/96  100"; } >> /etc/gai.conf
    _ok "IPv4 优先已配置"
  fi

  _install_tproxy_backend
  _write_warp_google
  _write_warp_cmd
  _write_keepalive
  _write_systemd_service
  _configure_warp

  systemctl restart warp-tproxy >/dev/null 2>&1 || true
  /usr/local/bin/warp-google update || _warn "IP 段更新失败，使用静态列表"
  /usr/local/bin/warp-google start  || true
  _sync_v2bx_ai_route

  echo
  _ok "WARP 安装完成 — www.flytoex.com"
  echo -e "  管理: ${G}warp {status|start|stop|test|debug|ip|update|uninstall}${N}"
  echo
  _info "安装后逐层诊断..."
  sleep 2
  warp test
}

# ── 独立运行支持 ─────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --install|install) warp_do_install ;;
    status)  command -v warp >/dev/null 2>&1 && warp status  || echo "WARP 未安装" ;;
    test)    command -v warp >/dev/null 2>&1 && warp test    || echo "WARP 未安装" ;;
    *)       _warp_banner
             echo -e "  ${G}1.${N} 安装/升级 WARP"
             echo -e "  ${G}2.${N} 查看状态"
             echo -e "  ${G}3.${N} 逐层诊断"
             echo -e "  ${G}0.${N} 退出"
             read -r -p "  请选择 [0-3]: " c </dev/tty
             case "${c}" in
               1) warp_do_install ;;
               2) command -v warp >/dev/null 2>&1 && warp status || echo "未安装" ;;
               3) command -v warp >/dev/null 2>&1 && warp test   || echo "未安装" ;;
               0) exit 0 ;;
             esac ;;
  esac
fi
