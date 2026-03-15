#!/usr/bin/env bash
# ============================================================
# lib/validate.sh — FLYTOex Network 输入校验库
# 每个函数接受一个值，返回 0=合法 1=非法
# 并在非法时输出人类可读的错误原因
# ============================================================

# ── IPv4 地址（不带前缀）───────────────────────────────────
validate_ipv4() {
  local v="$1"
  if [[ ! "${v}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "格式错误，应为 x.x.x.x（例如 1.2.3.4）"
    return 1
  fi
  local IFS='.'
  read -ra octets <<< "${v}"
  for oct in "${octets[@]}"; do
    if (( oct > 255 )); then
      echo "每段数字应在 0-255 之间（${oct} 超出范围）"
      return 1
    fi
  done
  return 0
}

# ── IPv4 CIDR（带前缀，如 10.0.0.1/32）────────────────────
validate_ipv4_cidr() {
  local v="$1"
  if [[ ! "${v}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
    echo "格式错误，应为 x.x.x.x/prefix（例如 10.0.0.3/32）"
    return 1
  fi
  local ip="${v%%/*}"
  local err
  err="$(validate_ipv4 "${ip}")" || { echo "${err}"; return 1; }
  return 0
}

# ── WireGuard Endpoint（IP:端口 或 域名:端口）──────────────
validate_wg_endpoint() {
  local v="$1"
  if [[ ! "${v}" =~ ^.+:[0-9]+$ ]]; then
    echo "格式错误，应为 IP:端口 或 域名:端口（例如 1.2.3.4:51820）"
    return 1
  fi
  local port="${v##*:}"
  if (( port < 1 || port > 65535 )); then
    echo "端口号应在 1-65535 之间（当前: ${port}）"
    return 1
  fi
  return 0
}

# ── WireGuard 密钥（base64，44 字符）───────────────────────
validate_wg_key() {
  local v="$1"
  if [[ ! "${v}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "格式错误，WireGuard 密钥应为 44 位 base64 字符串（以 = 结尾）"
    return 1
  fi
  return 0
}

# ── 纯数字（节点 ID 等）──────────────────────────────────
validate_positive_integer() {
  local v="$1"
  local label="${2:-值}"
  if [[ ! "${v}" =~ ^[0-9]+$ ]]; then
    echo "${label}应为纯数字（当前: ${v}）"
    return 1
  fi
  if (( v == 0 )); then
    echo "${label}不能为 0"
    return 1
  fi
  return 0
}

# ── Keepalive（1-300 秒）─────────────────────────────────
validate_keepalive() {
  local v="$1"
  local err
  err="$(validate_positive_integer "${v}" "Keepalive")" || { echo "${err}"; return 1; }
  if (( v > 300 )); then
    echo "Keepalive 建议不超过 300 秒（当前: ${v}）"
    return 1
  fi
  return 0
}

# ── 网络接口名（eth0, ens3, ...）─────────────────────────
validate_iface() {
  local v="$1"
  if [[ ! "${v}" =~ ^[a-zA-Z][a-zA-Z0-9_@.-]{0,14}$ ]]; then
    echo "接口名格式错误（应为字母开头，最长 15 字符，如 eth0、ens3）"
    return 1
  fi
  # 检查接口是否真实存在
  if ! ip link show "${v}" >/dev/null 2>&1; then
    echo "接口 ${v} 在本机不存在，请确认接口名是否正确"
    return 1
  fi
  return 0
}

# ── 口令强度 ────────────────────────────────────────────
validate_passphrase() {
  local v="$1"
  local min_len="${2:-8}"
  if [[ "${#v}" -lt "${min_len}" ]]; then
    echo "口令过短（最少 ${min_len} 位，当前 ${#v} 位）"
    return 1
  fi
  return 0
}

# ── URL（http/https）────────────────────────────────────
validate_url() {
  local v="$1"
  if [[ ! "${v}" =~ ^https?:// ]]; then
    echo "应为有效的 http/https URL（例如 https://panel.example.com）"
    return 1
  fi
  # 去掉协议头后不能为空
  local host="${v#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  if [[ -z "${host}" ]]; then
    echo "URL 中主机名不能为空"
    return 1
  fi
  return 0
}

# ── 占位值检测（识别备份块中的 REPLACE_WITH_* 等）──────
validate_not_placeholder() {
  local v="$1"
  local u="${v^^}"
  if [[ -z "${v}" ]]; then
    echo "值不能为空"
    return 1
  fi
  if [[ "${u}" =~ ^REPLACE(_WITH_.*)?$ ]] \
  || [[ "${u}" == "DEFAULT" ]] \
  || [[ "${u}" == "ENDPOINT" ]] \
  || [[ "${u}" == "<EMPTY>" ]] \
  || [[ "${u}" == "NULL" ]]; then
    echo "检测到占位值（${v}），请填写真实值"
    return 1
  fi
  return 0
}

# ── 带重试的校验输入 ─────────────────────────────────────
# validate_input_loop 变量名 "标签" "默认值" validator_fn [hint]
# 循环提示输入直到通过校验
validate_input_loop() {
  local __var="$1"
  local label="$2"
  local default="${3:-}"
  local validator="$4"
  local hint="${5:-}"
  local val=""

  while true; do
    ui_input val "${label}" "${default}" "${hint}" || return 1
    if [[ -z "${val}" ]]; then
      ui_warn "该项不能为空，请重新输入"
      continue
    fi
    local err
    err="$("${validator}" "${val}")" && break
    ui_warn "输入无效：${err}"
    default="${val}"   # 保留上次输入方便修改
  done

  printf -v "${__var}" '%s' "${val}"
}

# ── 组合校验（先检查非占位，再检查格式）────────────────
validate_input_loop_strict() {
  local __var="$1"
  local label="$2"
  local default="${3:-}"
  local validator="$4"
  local hint="${5:-}"
  local val=""

  while true; do
    ui_input val "${label}" "${default}" "${hint}" || return 1
    local err

    err="$(validate_not_placeholder "${val}" 2>&1)" || {
      ui_warn "${err}"
      continue
    }
    err="$("${validator}" "${val}" 2>&1)" || {
      ui_warn "输入无效：${err}"
      default="${val}"
      continue
    }
    break
  done

  printf -v "${__var}" '%s' "${val}"
}
