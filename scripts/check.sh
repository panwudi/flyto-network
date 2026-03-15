#!/usr/bin/env bash
# ============================================================
# scripts/check.sh — FLYTOex Network 仓库质量检查 v2
#
# 修复：
#   - 原 bash -n "${FILES[@]}" 一次传多个文件只检查第一个的 bug
#     → 改为逐文件循环
#   - 新增 shellcheck（如已安装）
#   - 新增 set -euo pipefail 检查
#   - 新增 lib/ 目录检查
# ============================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PASS=0; WARN=0; FAIL=0

_ok()   { echo -e "\033[1;32m  [OK]\033[0m $*";   PASS=$((PASS+1)); }
_warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; WARN=$((WARN+1)); }
_fail() { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; FAIL=$((FAIL+1)); }

# ── 检查脚本文件列表 ─────────────────────────────────────
SHELL_FILES=(
  "flyto.sh"
  "install.sh"
  "modules/hk-setup.sh"
  "modules/warp.sh"
  "tools/gen-secrets.sh"
  "scripts/check.sh"
  "lib/ui.sh"
  "lib/validate.sh"
  "lib/progress.sh"
  "lib/error.sh"
)

echo
echo "=== [1] 目录结构检查 ==="
for dir in docs modules tools scripts lib; do
  if [[ -d "${dir}" ]]; then
    _ok "目录存在：${dir}/"
  else
    _fail "目录缺失：${dir}/"
  fi
done

echo
echo "=== [2] 关键文件存在性 ==="
REQUIRED_FILES=(
  "flyto.sh"
  "install.sh"
  "secrets.enc"
  "modules/hk-setup.sh"
  "modules/warp.sh"
  "tools/gen-secrets.sh"
  "lib/ui.sh"
  "lib/validate.sh"
  "lib/progress.sh"
  "lib/error.sh"
  "scripts/check.sh"
  "docs/ARCHITECTURE.md"
  "docs/RISK-AUDIT.md"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    _ok "存在：${f}"
  else
    _fail "缺失：${f}"
  fi
done

echo
echo "=== [3] bash 语法检查（逐文件）==="
# 修复原 bug：逐文件检查，不一次传多个参数
for f in "${SHELL_FILES[@]}"; do
  if [[ ! -f "${f}" ]]; then
    _warn "跳过（文件不存在）：${f}"
    continue
  fi
  if bash -n "${f}" 2>/dev/null; then
    _ok "语法 OK：${f}"
  else
    _fail "语法错误：${f}"
    bash -n "${f}" 2>&1 | head -5 | sed 's/^/    /' >&2
  fi
done

echo
echo "=== [4] set -euo pipefail 检查 ==="
for f in "${SHELL_FILES[@]}"; do
  [[ ! -f "${f}" ]] && continue
  # lib 文件作为 source 加载，允许不含 set -euo pipefail
  if [[ "${f}" == lib/* ]]; then
    _ok "跳过（lib 库文件）：${f}"
    continue
  fi
  if grep -q 'set -euo pipefail' "${f}"; then
    _ok "包含 set -euo pipefail：${f}"
  else
    _fail "缺少 set -euo pipefail：${f}"
  fi
done

echo
echo "=== [5] shellcheck（如已安装）==="
if command -v shellcheck >/dev/null 2>&1; then
  SC_FAIL=0
  for f in "${SHELL_FILES[@]}"; do
    [[ ! -f "${f}" ]] && continue
    if shellcheck -S warning \
         --exclude=SC1090,SC1091,SC2034 \
         "${f}" 2>/dev/null; then
      _ok "shellcheck OK：${f}"
    else
      SC_FAIL=$((SC_FAIL+1))
      _warn "shellcheck 有警告：${f}（非阻断）"
    fi
  done
  [[ "${SC_FAIL}" -eq 0 ]] || _warn "共 ${SC_FAIL} 个文件有 shellcheck 警告，建议修复"
else
  _warn "shellcheck 未安装，跳过此项检查"
  _warn "安装方式：apt-get install shellcheck 或 brew install shellcheck"
fi

echo
echo "=== [6] 可执行权限检查 ==="
EXEC_FILES=(
  "flyto.sh"
  "install.sh"
  "modules/hk-setup.sh"
  "modules/warp.sh"
  "tools/gen-secrets.sh"
  "scripts/check.sh"
)
for f in "${EXEC_FILES[@]}"; do
  [[ ! -f "${f}" ]] && continue
  if [[ -x "${f}" ]]; then
    _ok "可执行：${f}"
  else
    _warn "无可执行权限：${f}（运行 chmod +x ${f} 修复）"
  fi
done

# ── 汇总 ─────────────────────────────────────────────────
echo
echo "════════════════════════════════════"
echo -e "  通过：\033[1;32m${PASS}\033[0m  警告：\033[1;33m${WARN}\033[0m  失败：\033[1;31m${FAIL}\033[0m"
echo "════════════════════════════════════"
echo

if [[ "${FAIL}" -gt 0 ]]; then
  echo -e "\033[1;31m  检查未通过，请修复上述问题后重试\033[0m"
  exit 1
else
  echo -e "\033[1;32m  所有关键检查通过\033[0m"
  exit 0
fi
