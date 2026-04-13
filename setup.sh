#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/scripts/install-tradingview-mcp-skill.sh"

if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
  echo "Install script not found: ${INSTALL_SCRIPT}" >&2
  exit 1
fi

bash "${INSTALL_SCRIPT}" "$@"
