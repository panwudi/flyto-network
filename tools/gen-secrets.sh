#!/usr/bin/env bash
# ============================================================
# tools/gen-secrets.sh — 生成/更新加密配置文件 v2
#
# 重构改动：
#   - 接入 lib/ui.sh（dialog 菜单 + 密码框）
#   - 口令最低长度从 4 位提高到 8 位
#   - URL 格式校验（接入 validate.sh）
#   - 菜单改为 dialog 或纯文本自适应
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_ENC="${SCRIPT_DIR}/../secrets.enc"
SECRETS_CACHE="/etc/flyto/.secrets"

# 加载 lib
for _lib in ui.sh validate.sh; do
  # shellcheck disable=SC1090
  [[ -f "${SCRIPT_DIR}/../lib/${_lib}" ]] && source "${SCRIPT_DIR}/../lib/${_lib}"
done

# 兜底
if ! command -v ui_info >/dev/null 2>&1; then
  ui_info()    { echo "[INFO] $*"; }
  ui_ok()      { echo "[ OK ] $*"; }
  ui_warn()    { echo "[WARN] $*" >&2; }
  ui_error()   { echo "[ERR ] $*" >&2; }
  ui_password(){ local __v="$1"; read -rsp "  $2: " "${__v}"; echo; }
  ui_input()   { local __v="$1"; read -rp "  $3 [$4]: " "${__v}"; }
  ui_confirm() { local a; read -rp "  $1 [y/N]: " a; [[ "${a}" =~ ^[Yy] ]]; }
  ui_menu()    {
    local __v="$1"; shift 3
    local i=0
    while [[ "$i" -lt "$#" ]]; do
      local tag="${@:$((i+1)):1}" lbl="${@:$((i+2)):1}"
      echo "  ${tag}. ${lbl}"; i=$((i+2))
    done
    read -rp "  请选择: " "${__v}"
  }
fi

# ── 主菜单 ───────────────────────────────────────────────────
echo
echo -e "\033[1;36m  FLYTOex Network — secrets.enc 管理工具\033[0m"
echo -e "\033[2;37m  www.flytoex.com\033[0m"
echo

choice=""
ui_menu choice \
  "secrets.enc 管理" \
  "请选择操作" \
  "1" "创建 / 更新 secrets.enc（手动输入配置）" \
  "2" "更换加密口令（需提供旧口令）" \
  "3" "查看当前配置（需提供口令）" \
  "0" "退出" || exit 0

case "${choice}" in
# ──────────────────────────────────────────────────────────
  1)
    echo
    ui_info "输入面板配置："

    local_api_host=""
    ui_input local_api_host \
      "PANEL_API_HOST" \
      "面板 API 地址" \
      "https://panel.flytoex.net"
    [[ -z "${local_api_host}" ]] && local_api_host="https://panel.flytoex.net"
    # URL 格式校验
    if command -v validate_url >/dev/null 2>&1; then
      local url_err
      url_err="$(validate_url "${local_api_host}")" || {
        ui_warn "URL 格式警告：${url_err}，请确认是否正确"
      }
    fi

    local_api_key=""
    ui_input local_api_key \
      "PANEL_API_KEY" \
      "面板 API 密钥" \
      "your-api-key-here"
    [[ -z "${local_api_key}" ]] && { ui_error "API 密钥不能为空"; exit 1; }

    echo
    local pass1="" pass2=""
    while true; do
      ui_password pass1 "设置加密口令（至少 8 位）"
      if command -v validate_passphrase >/dev/null 2>&1; then
        local perr
        perr="$(validate_passphrase "${pass1}" 8 2>&1)" || { ui_warn "${perr}"; continue; }
      elif [[ "${#pass1}" -lt 8 ]]; then
        ui_warn "口令过短（至少 8 位，当前 ${#pass1} 位）"; continue
      fi
      ui_password pass2 "确认加密口令"
      if [[ "${pass1}" != "${pass2}" ]]; then
        ui_warn "两次口令不一致，请重新输入"; continue
      fi
      break
    done

    local tmp_plain
    tmp_plain="$(mktemp)"
    cat > "${tmp_plain}" <<EOF
PANEL_API_HOST=${local_api_host}
PANEL_API_KEY=${local_api_key}
EOF
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass "pass:${pass1}" -base64 \
      -in "${tmp_plain}" -out "${SECRETS_ENC}"
    rm -f "${tmp_plain}"

    # 清除旧缓存
    [[ -f "${SECRETS_CACHE}" ]] && rm -f "${SECRETS_CACHE}" && ui_info "已清除旧缓存"

    ui_ok "secrets.enc 已生成：${SECRETS_ENC}"
    echo
    echo "  重要提醒："
    echo "  1. 请牢记口令，无法从加密文件反推"
    echo "  2. secrets.enc 可以提交到 Git 仓库（密文安全）"
    echo "  3. 口令请保存在本地密码管理器中"
    echo "  4. /etc/flyto/.secrets 是解密缓存，仅存于本机"
    ;;

# ──────────────────────────────────────────────────────────
  2)
    [[ -f "${SECRETS_ENC}" ]] || { ui_error "未找到 ${SECRETS_ENC}"; exit 1; }
    echo
    old_pass=""
    ui_password old_pass "旧口令"
    local tmp_plain
    tmp_plain="$(mktemp)"
    if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass "pass:${old_pass}" -d -base64 \
        -in "${SECRETS_ENC}" -out "${tmp_plain}" 2>/dev/null; then
      rm -f "${tmp_plain}"; ui_error "旧口令错误"; exit 1
    fi
    ui_ok "旧口令验证通过"

    local new_pass="" new_pass2=""
    while true; do
      ui_password new_pass "新口令（至少 8 位）"
      if [[ "${#new_pass}" -lt 8 ]]; then
        ui_warn "口令过短（至少 8 位）"; continue
      fi
      ui_password new_pass2 "确认新口令"
      [[ "${new_pass}" == "${new_pass2}" ]] && break
      ui_warn "两次口令不一致"
    done

    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass "pass:${new_pass}" -base64 \
      -in "${tmp_plain}" -out "${SECRETS_ENC}"
    rm -f "${tmp_plain}"
    [[ -f "${SECRETS_CACHE}" ]] && rm -f "${SECRETS_CACHE}"

    ui_ok "口令已更新，旧缓存已清除"
    ;;

# ──────────────────────────────────────────────────────────
  3)
    [[ -f "${SECRETS_ENC}" ]] || { ui_error "未找到 ${SECRETS_ENC}"; exit 1; }
    echo
    view_pass=""
    ui_password view_pass "请输入口令"
    local tmp_plain
    tmp_plain="$(mktemp)"
    if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass "pass:${view_pass}" -d -base64 \
        -in "${SECRETS_ENC}" -out "${tmp_plain}" 2>/dev/null; then
      rm -f "${tmp_plain}"; ui_error "口令错误"; exit 1
    fi
    echo
    ui_info "当前配置："
    cat "${tmp_plain}"
    rm -f "${tmp_plain}"
    echo
    ;;

# ──────────────────────────────────────────────────────────
  0|"") echo "退出"; exit 0 ;;
  *) ui_error "无效选项"; exit 1 ;;
esac
