#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

FILES=(
  "install.sh"
  "flyto.sh"
  "modules/hk-setup.sh"
  "modules/warp.sh"
  "tools/gen-secrets.sh"
)

echo "[check] bash syntax"
bash -n "${FILES[@]}"

echo "[check] expected directories"
for path in docs modules tools scripts; do
  [[ -d "${path}" ]] || { echo "missing directory: ${path}" >&2; exit 1; }
done

if [[ -e "{modules,tools,docs}" ]]; then
  echo "unexpected legacy directory exists: {modules,tools,docs}" >&2
  exit 1
fi

echo "[check] ok"
