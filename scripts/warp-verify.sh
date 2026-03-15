#!/usr/bin/env bash
set -euo pipefail

G='\033[1;32m'
R='\033[1;31m'
Y='\033[1;33m'
C='\033[1;36m'
N='\033[0m'

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo -e "  ${G}✓${N} $*"
}

bad() {
  FAIL=$((FAIL + 1))
  echo -e "  ${R}✗${N} $*"
}

info() {
  echo -e "${C}[verify]${N} $*"
}

warn() {
  echo -e "${Y}[warn]${N} $*"
}

need_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || { bad "缺少命令: ${cmd}"; return 1; }
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash scripts/warp-verify.sh"
  exit 1
fi

for c in curl iptables ipset ss python3; do
  need_cmd "${c}" || true
done

WARP_PROXY_PORT=40000
TPROXY_PORT=12345
if [[ -f /etc/warp-google/env ]]; then
  # shellcheck disable=SC1091
  source /etc/warp-google/env || true
fi
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="${TPROXY_PORT:-12345}"

http_code() {
  local code
  code="$(curl -s "$@" -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
  [[ "${code}" =~ ^[0-9]{3}$ ]] || code="000"
  echo "${code}"
}

is_http_reachable() {
  local code="$1"
  [[ "${code}" =~ ^[12345][0-9][0-9]$ ]]
}

nat_pkts() {
  local p
  p="$(iptables -t nat -L WARP_GOOGLE -n -v -x 2>/dev/null | awk '/REDIRECT/{print $1; exit}' || true)"
  [[ "${p}" =~ ^[0-9]+$ ]] || p=0
  echo "${p}"
}

print_header() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

print_header "FLYTO WARP 验收脚本"
info "端口配置: WARP_PROXY_PORT=${WARP_PROXY_PORT}, TPROXY_PORT=${TPROXY_PORT}"

print_header "1) 基础状态"
if command -v warp-cli >/dev/null 2>&1; then
  ws="$(warp-cli --accept-tos status 2>/dev/null || true)"
  if echo "${ws}" | grep -qi 'Connected'; then
    ok "warp-cli 显示已连接"
  else
    bad "warp-cli 未连接"
  fi
else
  bad "未安装 warp-cli"
fi

if ss -tlnp 2>/dev/null | grep -q ":${WARP_PROXY_PORT}\\b"; then
  ok "WARP SOCKS5 端口监听中 (:${WARP_PROXY_PORT})"
else
  bad "WARP SOCKS5 端口未监听 (:${WARP_PROXY_PORT})"
fi

if systemctl is-active --quiet warp-tproxy 2>/dev/null; then
  ok "warp-tproxy 服务运行中"
else
  bad "warp-tproxy 服务未运行"
fi

ipset_count="$(ipset list warp_google4 2>/dev/null | grep -c '/' 2>/dev/null || true)"
[[ "${ipset_count}" =~ ^[0-9]+$ ]] || ipset_count=0
if [[ "${ipset_count}" -gt 0 ]]; then
  ok "ipset 规则存在 (${ipset_count} 条 Google 段)"
else
  bad "ipset 为空 (warp_google4)"
fi

if iptables -t nat -S WARP_GOOGLE 2>/dev/null | grep -q REDIRECT; then
  ok "iptables WARP_GOOGLE REDIRECT 已加载"
else
  bad "iptables WARP_GOOGLE REDIRECT 缺失"
fi

print_header "2) Google / Gemini 分流命中验证"
g_ok=0
for u in https://www.google.com https://gemini.google.com; do
  before="$(nat_pkts)"
  code="$(http_code -4 --max-time 15 "${u}")"
  after="$(nat_pkts)"
  delta=$((after - before))
  if [[ "${delta}" -gt 0 ]]; then
    ok "${u} 命中透明分流 (REDIRECT ${before}->${after}, HTTP=${code})"
    g_ok=$((g_ok + 1))
  else
    bad "${u} 未命中透明分流 (REDIRECT ${before}->${after}, HTTP=${code})"
  fi
done

if [[ "${g_ok}" -eq 2 ]]; then
  ok "Google/Gemini 分流生效"
else
  bad "Google/Gemini 分流不完整"
fi

echo
info "补充探测：SOCKS5 域名解析模式差异（用于定位 502 / reset）"
socks5h_code="$(http_code --max-time 12 -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" https://www.google.com)"
socks5_code="$(http_code --max-time 12 -x "socks5://127.0.0.1:${WARP_PROXY_PORT}" https://www.google.com)"
echo "  socks5h (远端解析) HTTP=${socks5h_code}"
echo "  socks5  (本地解析) HTTP=${socks5_code}"
if is_http_reachable "${socks5h_code}" && ! is_http_reachable "${socks5_code}"; then
  warn "出现 socks5h 正常 / socks5 异常，透明分流可能受 CONNECT(IP) 限制影响"
fi

print_header "3) OpenAI / Claude 路由命中验证（sing-box）"
if [[ ! -f /etc/V2bX/sing_origin.json ]]; then
  bad "缺少 /etc/V2bX/sing_origin.json"
else
  py_out="$(python3 - <<'PY'
import json
import sys

path = "/etc/V2bX/sing_origin.json"
try:
    cfg = json.load(open(path, "r", encoding="utf-8"))
except Exception as e:
    print(f"ERR|json_parse|{e}")
    sys.exit(0)

out = {item.get("tag"): item for item in cfg.get("outbounds", []) if isinstance(item, dict)}
rules = [r for r in cfg.get("route", {}).get("rules", []) if isinstance(r, dict) and r.get("outbound") == "warp-ai"]

def has_domain(d: str) -> bool:
    for r in rules:
        if d in r.get("domain_suffix", []):
            return True
        if d in r.get("domain", []):
            return True
    return False

if "warp-ai" not in out:
    print("ERR|outbound|missing")
else:
    print(f"OK|outbound|{out['warp-ai'].get('server_port', 'unknown')}")

for d in ["openai.com", "chatgpt.com", "claude.ai", "anthropic.com"]:
    print(f"{'OK' if has_domain(d) else 'ERR'}|domain|{d}")

print(f"INFO|rules|{len(rules)}")
PY
)"

  while IFS='|' read -r kind type value; do
    [[ -z "${kind}" ]] && continue
    case "${kind}|${type}" in
      OK|outbound) ok "warp-ai outbound 存在 (port=${value})" ;;
      ERR|outbound) bad "warp-ai outbound 缺失" ;;
      OK|domain) ok "域名规则包含 ${value}" ;;
      ERR|domain) bad "域名规则缺少 ${value}" ;;
      ERR|json_parse) bad "sing_origin.json 解析失败: ${value}" ;;
      INFO|rules) info "warp-ai 规则条目: ${value}" ;;
      *) warn "未识别输出: ${kind}|${type}|${value}" ;;
    esac
  done <<< "${py_out}"
fi

print_header "4) OpenAI / Claude 通过 WARP SOCKS5 可达性"
ai_ok=0
for u in https://chatgpt.com https://claude.ai; do
  code="$(http_code --max-time 15 -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" "${u}")"
  if is_http_reachable "${code}"; then
    ok "${u} 通过 WARP SOCKS5 可达 (HTTP=${code})"
    ai_ok=$((ai_ok + 1))
  else
    bad "${u} 通过 WARP SOCKS5 不可达 (HTTP=${code})"
  fi
done

if [[ "${ai_ok}" -eq 2 ]]; then
  ok "OpenAI/Claude WARP SOCKS5 通道可用"
else
  bad "OpenAI/Claude WARP SOCKS5 通道异常"
fi

print_header "5) 出口 IP 归属验证（直连 vs WARP）"
direct_ip="$(curl -4 -s --max-time 10 https://ip.sb 2>/dev/null || true)"
warp_ip="$(curl -4 -s --max-time 10 -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" https://ip.sb 2>/dev/null || true)"
trace="$(curl -s --max-time 10 -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"

echo "  直连出口 IP : ${direct_ip:-N/A}"
echo "  WARP 出口 IP: ${warp_ip:-N/A}"
echo "  WARP trace   :"
echo "${trace}" | grep -E '^(ip|loc|warp)=' || echo "    (无 trace 输出)"

if [[ -n "${trace}" ]] && echo "${trace}" | grep -q '^warp=on$'; then
  ok "WARP trace 显示 warp=on"
else
  bad "WARP trace 未显示 warp=on"
fi

if [[ -n "${direct_ip}" && -n "${warp_ip}" && "${direct_ip}" != "${warp_ip}" ]]; then
  ok "WARP 流量出口 IP 与直连不同（符合预期）"
else
  warn "直连与 WARP 出口 IP 相同或为空，请结合 trace 判断"
fi

print_header "验收结论"
echo "  PASS=${PASS}"
echo "  FAIL=${FAIL}"

if [[ "${FAIL}" -eq 0 ]]; then
  echo -e "  ${G}结论: 通过（WARP 分流与 AI 路由均生效）${N}"
  exit 0
fi

echo -e "  ${R}结论: 未通过（存在 ${FAIL} 项失败）${N}"
echo "  建议先执行: warp test && warp debug"
exit 1
