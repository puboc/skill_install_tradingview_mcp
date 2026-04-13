#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-openclaw}"
REPO_URL="${REPO_URL:-https://github.com/LewisWJackson/tradingview-mcp-jackson}"
REPO_REF="${REPO_REF:-main}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/data/.openclaw/workspace}"
REPO_DIR="${WORKSPACE_DIR}/tradingview-mcp-jackson"
LAUNCH_SCRIPT="${REPO_DIR}/scripts/launch_tv_debug_linux.sh"
SERVER_NAME="${SERVER_NAME:-tradingview}"
STATUS_LOG_FILE="${STATUS_LOG_FILE:-/tmp/tradingview-mcp-install.log}"
TV_DEB_URL="${TV_DEB_URL:-https://tvd-packages.tradingview.com/ubuntu/stable/latest/jammy/tradingview_amd64.deb}"

log_status() {
  local message="$1"
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${message}" >> "${STATUS_LOG_FILE}"
}

is_inside_container() {
  if [[ -f "/.dockerenv" ]]; then
    return 0
  fi
  grep -qaE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null
}

INNER_CMD="$(cat <<'EOF'
set -eu

if ! command -v git >/dev/null 2>&1; then
  echo 'Missing required command inside container: git' >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo 'Missing required command inside container: python3' >&2
  exit 1
fi

if [ ! -x /usr/bin/apt ]; then
  echo '/usr/bin/apt is required but not available in this runtime.' >&2
  exit 1
fi

if ! command -v xvfb-run >/dev/null 2>&1; then
  install_ok=0
  apt_log="/tmp/tradingview-mcp-apt.log"
  export DEBIAN_FRONTEND=noninteractive
  if /usr/bin/apt update -y >"$apt_log" 2>&1 && /usr/bin/apt install -y xvfb >>"$apt_log" 2>&1; then
    install_ok=1
  fi
  if [ "$install_ok" -ne 1 ]; then
    echo '/usr/bin/apt failed to install xvfb.' >&2
    echo 'apt error (tail):' >&2
    tail -n 50 "$apt_log" >&2 || true
    exit 1
  fi
fi

if ! command -v curl >/dev/null 2>&1; then
  echo 'Missing required command inside container: curl' >&2
  exit 1
fi
if ! command -v dpkg >/dev/null 2>&1; then
  echo 'Missing required command inside container: dpkg' >&2
  exit 1
fi

TV_DEB_TMP="/tmp/tradingview_amd64.deb"
curl -fL "$TV_DEB_URL" -o "$TV_DEB_TMP"
if ! dpkg -i "$TV_DEB_TMP"; then
  /usr/bin/apt -f install -y >/dev/null 2>&1
  dpkg -i "$TV_DEB_TMP"
fi
rm -f "$TV_DEB_TMP"

mkdir -p "$WORKSPACE_DIR"

if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  git -C "$REPO_DIR" fetch --prune origin
  if git -C "$REPO_DIR" rev-parse --verify --quiet "origin/$REPO_REF" >/dev/null; then
    git -C "$REPO_DIR" checkout -B "$REPO_REF" "origin/$REPO_REF"
  else
    git -C "$REPO_DIR" checkout "$REPO_REF"
  fi
else
  rm -rf "$REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
  if git -C "$REPO_DIR" rev-parse --verify --quiet "origin/$REPO_REF" >/dev/null; then
    git -C "$REPO_DIR" checkout -B "$REPO_REF" "origin/$REPO_REF"
  else
    git -C "$REPO_DIR" checkout "$REPO_REF"
  fi
fi

if [ ! -f "$LAUNCH_SCRIPT" ]; then
  echo "Missing launch script: $LAUNCH_SCRIPT" >&2
  exit 1
fi

LAUNCH_SCRIPT="$LAUNCH_SCRIPT" python3 - <<'PY'
import os
from pathlib import Path

launch_path = Path(os.environ['LAUNCH_SCRIPT'])
text = launch_path.read_text(encoding='utf-8')
lines = text.splitlines()
target = 'xvfb-run -a "$APP" --remote-debugging-port=$PORT --no-sandbox'
replaced = False
next_lines = []
for line in lines:
    stripped = line.strip()
    if '"$APP"' in stripped and '--remote-debugging-port=$PORT' in stripped:
        indent = line[: len(line) - len(line.lstrip())]
        next_lines.append(f'{indent}{target}')
        replaced = True
        continue
    next_lines.append(line)
if not replaced:
    if next_lines and next_lines[-1] != '':
        next_lines.append('')
    next_lines.append(target)
launch_path.write_text('\n'.join(next_lines) + '\n', encoding='utf-8')
PY

if ! grep -Fq 'xvfb-run -a "$APP" --remote-debugging-port=$PORT --no-sandbox' "$LAUNCH_SCRIPT"; then
  echo "Failed to enforce launch command pattern in $LAUNCH_SCRIPT" >&2
  exit 1
fi
EOF
)"

if is_inside_container; then
  log_status "[tradingview-mcp] install started"
  trap 'log_status "[tradingview-mcp] install failed"' ERR
  WORKSPACE_DIR="$WORKSPACE_DIR" \
  REPO_DIR="$REPO_DIR" \
  REPO_URL="$REPO_URL" \
  REPO_REF="$REPO_REF" \
  LAUNCH_SCRIPT="$LAUNCH_SCRIPT" \
  TV_DEB_URL="$TV_DEB_URL" \
  sh -lc "$INNER_CMD"
else
  log_status "[tradingview-mcp] install started"
  trap 'log_status "[tradingview-mcp] install failed"' ERR
  docker exec \
    -e WORKSPACE_DIR="$WORKSPACE_DIR" \
    -e REPO_DIR="$REPO_DIR" \
    -e REPO_URL="$REPO_URL" \
    -e REPO_REF="$REPO_REF" \
    -e LAUNCH_SCRIPT="$LAUNCH_SCRIPT" \
    -e TV_DEB_URL="$TV_DEB_URL" \
    "$CONTAINER_NAME" sh -lc "$INNER_CMD"
fi

log_status "[tradingview-mcp] install completed successfully"
echo "[tradingview-mcp-skill] Installed TradingView MCP prerequisites and repository successfully."
