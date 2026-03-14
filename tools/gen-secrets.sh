#!/usr/bin/env bash
# ============================================================
# tools/gen-secrets.sh — 生成/更新加密配置文件
#
# 用途:
#   - 首次设置：交互式输入面板信息，加密保存为 secrets.enc
#   - 更新配置：修改 ApiHost / ApiKey 后重新加密
#   - 更换口令：用旧口令解密后重新加密
#
# 项目地址: https://github.com/panwudi/flyto-network
# 官网:     www.flytoex.com
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_ENC="${SCRIPT_DIR}/../secrets.enc"
SECRETS_CACHE="/etc/flyto/.secrets"

G='\033[1;32m' R='\033[1;31m' Y='\033[1;33m' C='\033[1;36m' N='\033[0m'

_ok()  { echo -e "${G}[OK]${N} $*"; }
_err() { echo -e "${R}[ERR]${N} $*" >&2; }
_info(){ echo -e "${C}[INFO]${N} $*"; }

echo
echo -e "  ${C}FLYTOex Network — secrets.enc 管理工具${N}"
echo -e "  ${G}www.flytoex.com${N}"
echo

echo "请选择操作:"
echo "  1. 创建/更新 secrets.enc（手动输入配置）"
echo "  2. 更换加密口令（需提供旧口令）"
echo "  3. 查看当前配置（需提供口令）"
echo "  0. 退出"
echo
read -r -p "请选择 [0-3]: " choice

case "${choice}" in
  1)
    echo
    _info "输入面板配置（回车使用默认值）:"
    echo
    read -r -p "  PANEL_API_HOST [https://panel.flytoex.net]: " api_host
    [[ -z "${api_host}" ]] && api_host="https://panel.flytoex.net"
    read -r -p "  PANEL_API_KEY  [flyto20221227.com]: " api_key
    [[ -z "${api_key}" ]] && api_key="flyto20221227.com"

    echo
    echo -n "  设置加密口令: "
    read -rs pass1; echo
    echo -n "  确认加密口令: "
    read -rs pass2; echo

    if [[ "${pass1}" != "${pass2}" ]]; then
      _err "两次口令不一致"; exit 1
    fi
    if [[ ${#pass1} -lt 4 ]]; then
      _err "口令过短（至少 4 位）"; exit 1
    fi

    local_tmp="$(mktemp)"
    cat > "${local_tmp}" <<EOF
PANEL_API_HOST=${api_host}
PANEL_API_KEY=${api_key}
EOF

    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass "pass:${pass1}" \
      -base64 \
      -in "${local_tmp}" \
      -out "${SECRETS_ENC}"
    rm -f "${local_tmp}"

    # 清除旧缓存
    [[ -f "${SECRETS_CACHE}" ]] && rm -f "${SECRETS_CACHE}" && _info "已清除旧缓存"

    _ok "secrets.enc 已生成: ${SECRETS_ENC}"
    echo
    echo -e "  ${Y}重要提醒:${N}"
    echo "  1. 请牢记口令，无法从加密文件反推"
    echo "  2. secrets.enc 可以提交到 Git 仓库（密文安全）"
    echo "  3. 口令请保存在本地密码管理器中"
    echo "  4. /etc/flyto/.secrets 是解密缓存，仅存于本机"
    ;;

  2)
    if [[ ! -f "${SECRETS_ENC}" ]]; then
      _err "未找到 ${SECRETS_ENC}"; exit 1
    fi
    echo
    echo -n "  旧口令: "; read -rs old_pass; echo
    local_tmp="$(mktemp)"
    if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass "pass:${old_pass}" -d -base64 \
        -in "${SECRETS_ENC}" -out "${local_tmp}" 2>/dev/null; then
      rm -f "${local_tmp}"; _err "旧口令错误"; exit 1
    fi
    _ok "旧口令验证通过"
    echo -n "  新口令: "; read -rs new_pass; echo
    echo -n "  确认新口令: "; read -rs new_pass2; echo
    if [[ "${new_pass}" != "${new_pass2}" ]]; then
      rm -f "${local_tmp}"; _err "两次口令不一致"; exit 1
    fi

    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass "pass:${new_pass}" -base64 \
      -in "${local_tmp}" -out "${SECRETS_ENC}"
    rm -f "${local_tmp}"
    [[ -f "${SECRETS_CACHE}" ]] && rm -f "${SECRETS_CACHE}"

    _ok "口令已更新，旧缓存已清除"
    ;;

  3)
    if [[ ! -f "${SECRETS_ENC}" ]]; then
      _err "未找到 ${SECRETS_ENC}"; exit 1
    fi
    echo -n "  口令: "; read -rs pass; echo
    local_tmp="$(mktemp)"
    if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass "pass:${pass}" -d -base64 \
        -in "${SECRETS_ENC}" -out "${local_tmp}" 2>/dev/null; then
      rm -f "${local_tmp}"; _err "口令错误"; exit 1
    fi
    echo
    echo -e "  ${C}当前配置:${N}"
    cat "${local_tmp}"
    rm -f "${local_tmp}"
    echo
    ;;

  0) echo "退出"; exit 0 ;;
  *) _err "无效选项"; exit 1 ;;
esac
