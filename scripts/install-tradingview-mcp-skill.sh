#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-openclaw}"
REPO_URL="${REPO_URL:-https://github.com/LewisWJackson/tradingview-mcp-jackson}"
REPO_REF="${REPO_REF:-main}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/data/.openclaw/workspace}"
REPO_DIR="${WORKSPACE_DIR}/tradingview-mcp-jackson"
SKILLS_DIR="${WORKSPACE_DIR}/skills"
LAUNCH_SKILL_DIR="${SKILLS_DIR}/launch_tradingview_debug_linux"
INJECT_COOKIES_SKILL_DIR="${SKILLS_DIR}/inject_cookies"
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

INNER_CMD="$(cat <<'__INNER_CMD__'
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
mkdir -p "$SKILLS_DIR"

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

if ! command -v npm >/dev/null 2>&1; then
  echo 'Missing required command inside container: npm' >&2
  exit 1
fi
npm --prefix "$REPO_DIR" install
npm --prefix "$REPO_DIR" link

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
target = 'xvfb-run -a "$APP" --remote-debugging-port=$PORT --no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage'
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

if ! grep -Fq 'xvfb-run -a "$APP" --remote-debugging-port=$PORT --no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage' "$LAUNCH_SCRIPT"; then
  echo "Failed to enforce launch command pattern in $LAUNCH_SCRIPT" >&2
  exit 1
fi

rm -rf "$LAUNCH_SKILL_DIR"
mkdir -p "$LAUNCH_SKILL_DIR"
cp "$LAUNCH_SCRIPT" "$LAUNCH_SKILL_DIR/launch_tv_debug_linux.sh"
chmod +x "$LAUNCH_SKILL_DIR/launch_tv_debug_linux.sh"
cat > "$LAUNCH_SKILL_DIR/SKILL.md" <<'EOF'
---
name: launch-tradingview-debug-linux
description: Launch the installed TradingView desktop app in Linux with remote debugging enabled for OpenClaw integrations.
---

# Launch TradingView Debug Linux

Use this skill when asked to start or restart the local TradingView desktop app for the TradingView MCP integration.

## Workflow

1. Confirm `/data/.openclaw/workspace/tradingview-mcp-jackson/scripts/launch_tv_debug_linux.sh` exists.
2. Run `./launch_tv_debug_linux.sh` from this skill directory.
3. If startup fails, inspect `/data/tradingview-launch.log`.

## Files

- `launch_tv_debug_linux.sh`: copied from the installed `tradingview-mcp-jackson` repo and kept executable.
EOF

rm -rf "$INJECT_COOKIES_SKILL_DIR"
mkdir -p "$INJECT_COOKIES_SKILL_DIR"
cat > "$INJECT_COOKIES_SKILL_DIR/cookies-inject-tradingview.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CDP_HOST="${CDP_HOST:-127.0.0.1}"
CDP_PORT="${CDP_PORT:-9222}"
TARGET_MATCH="${TARGET_MATCH:-https://www.tradingview.com/chart/}"
PAGE_WAIT_MS="${PAGE_WAIT_MS:-5000}"
WORKSPACE="${WORKSPACE:-/root/.openclaw/workspace}"
NODE_DEPS_DIR="${NODE_DEPS_DIR:-$WORKSPACE/node-deps}"

COOKIES_JSON="${1:?Usage: $0 /path/to/cookies.json [target-url]}"
CLI_TARGET_URL="${2:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1"
    exit 1
  }
}

ensure_node_dep() {
  export NODE_PATH="$NODE_DEPS_DIR/node_modules${NODE_PATH:+:$NODE_PATH}"
  if [[ ! -d "$NODE_DEPS_DIR/node_modules/chrome-remote-interface" ]]; then
    mkdir -p "$NODE_DEPS_DIR"
    npm install --prefix "$NODE_DEPS_DIR" chrome-remote-interface >/dev/null
  fi
}

need_cmd python3
need_cmd node
need_cmd npm
[[ -r "$COOKIES_JSON" ]] || { echo "ERROR: cannot read cookies JSON: $COOKIES_JSON"; exit 1; }
ensure_node_dep

NODE_PATH="$NODE_DEPS_DIR/node_modules${NODE_PATH:+:$NODE_PATH}" \
node - <<'NODE' "$COOKIES_JSON" "$CLI_TARGET_URL" "$CDP_HOST" "$CDP_PORT" "$TARGET_MATCH" "$PAGE_WAIT_MS"
const fs = require('fs');
const CDP = require('chrome-remote-interface');

const cookieFile = process.argv[2];
const cliTargetUrl = process.argv[3];
const host = process.argv[4];
const port = Number(process.argv[5]);
const targetMatch = process.argv[6];
const waitMs = Math.max(0, Number(process.argv[7]) || 5000);

function normalizePath(pathValue) {
  if (typeof pathValue !== 'string' || pathValue.length === 0) return '/';
  return pathValue.startsWith('/') ? pathValue : `/${pathValue}`;
}

function normalizeDomain(domainValue) {
  if (typeof domainValue !== 'string') return '';
  return domainValue.replace(/^\.+/, '').trim();
}

function normalizeSameSite(value) {
  if (!value) return undefined;
  const lowered = String(value).toLowerCase();
  if (lowered === 'lax') return 'Lax';
  if (lowered === 'strict') return 'Strict';
  if (lowered === 'none' || lowered === 'no_restriction') return 'None';
  return undefined;
}

function extractCookies(rawData) {
  if (Array.isArray(rawData)) return rawData;
  if (rawData && Array.isArray(rawData.cookies)) return rawData.cookies;
  throw new Error('Unsupported cookie JSON format. Use either an array or an object with a "cookies" array.');
}

function inferTargetUrl(rootConfig, cookies) {
  const candidates = [
    cliTargetUrl,
    rootConfig.targetUrl,
    rootConfig.url,
    rootConfig.baseUrl,
    rootConfig.origin,
    targetMatch,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim()) return candidate.trim();
  }

  for (const cookie of cookies) {
    if (typeof cookie.url === 'string' && cookie.url.trim()) return cookie.url.trim();
    const domain = normalizeDomain(cookie.domain);
    if (domain) return `https://${domain}${normalizePath(cookie.path)}`;
  }

  throw new Error('Could not determine target URL.');
}

function buildCookieUrl(cookie, fallbackUrl) {
  if (typeof cookie.url === 'string' && cookie.url.trim()) return cookie.url.trim();

  const domain = normalizeDomain(cookie.domain);
  const path = normalizePath(cookie.path);

  if (domain) {
    let protocol = cookie.secure === true ? 'https:' : 'http:';
    if (fallbackUrl) {
      try {
        const fp = new URL(fallbackUrl).protocol;
        if (fp) protocol = cookie.secure === true ? 'https:' : fp;
      } catch (_) {}
    }
    return `${protocol}//${domain}${path}`;
  }

  if (fallbackUrl) {
    const url = new URL(fallbackUrl);
    url.pathname = path;
    url.search = '';
    url.hash = '';
    return url.toString();
  }

  return null;
}

async function findTradingViewTarget(host, port, targetMatch) {
  const targets = await CDP.List({ host, port });
  const preferred = targets.find(t =>
    t.type === 'page' && (
      (t.url && t.url.includes(targetMatch)) ||
      (t.title && t.title.toLowerCase().includes('tradingview'))
    )
  );
  if (preferred) return preferred;

  const fallback = targets.find(t => t.type === 'page');
  if (fallback) return fallback;

  throw new Error('No page target found in TradingView Desktop.');
}

(async () => {
  const rawData = JSON.parse(fs.readFileSync(cookieFile, 'utf8'));
  const rootConfig = Array.isArray(rawData) ? {} : rawData;
  const cookies = extractCookies(rawData).filter(cookie =>
    cookie &&
    typeof cookie.name === 'string' &&
    cookie.name.length > 0 &&
    cookie.value !== undefined &&
    cookie.value !== null &&
    cookie.value !== 'deleted'
  );

  if (cookies.length === 0) throw new Error('No valid cookies found in input JSON.');

  const targetUrl = inferTargetUrl(rootConfig, cookies);
  const target = await findTradingViewTarget(host, port, targetMatch);
  const client = await CDP({ host, port, target: target.id || target.targetId });
  const { Network, Page, Runtime } = client;

  await Network.enable();
  await Page.enable();

  let ok = 0;
  const failures = [];

  for (const ck of cookies) {
    const cookieUrl = buildCookieUrl(ck, targetUrl);
    if (!cookieUrl) continue;

    const params = {
      name: ck.name,
      value: String(ck.value),
      url: cookieUrl,
    };
    if (ck.domain) params.domain = ck.domain;
    if (ck.path) params.path = ck.path;
    if (typeof ck.httpOnly === 'boolean') params.httpOnly = ck.httpOnly;
    if (typeof ck.secure === 'boolean') params.secure = ck.secure;
    if (ck.expires) params.expires = Math.floor(ck.expires);
    else if (ck.expirationDate) params.expires = Math.floor(ck.expirationDate);

    const sameSite = normalizeSameSite(ck.sameSite);
    if (sameSite) params.sameSite = sameSite;

    try {
      const res = await Network.setCookie(params);
      if (res && res.success) ok++;
      else failures.push({ name: ck.name, reason: 'setCookie returned unsuccessful result' });
    } catch (err) {
      failures.push({ name: ck.name, reason: err && err.message ? err.message : String(err) });
    }
  }

  console.log(`attached_target: ${target.title || '(untitled)'} | ${target.url || ''}`);
  console.log(`cookies_set: ${ok}/${cookies.length}`);

  await Page.navigate({ url: targetUrl });
  await Page.loadEventFired();
  await Runtime.evaluate({ expression: `new Promise(r => setTimeout(r, ${waitMs}))` });

  const finalUrl = await Runtime.evaluate({ expression: 'location.href', returnByValue: true });
  const title = await Runtime.evaluate({ expression: 'document.title', returnByValue: true });
  const cookieDump = await Runtime.evaluate({
    expression: 'document.cookie',
    returnByValue: true,
  });

  console.log('target_url:', targetUrl);
  console.log('final_url:', finalUrl.result.value);
  console.log('title:', title.result.value);
  console.log('document_cookie_length:', String(cookieDump.result.value || '').length);

  if (failures.length) {
    console.log('failures:', JSON.stringify(failures, null, 2));
  }

  await client.close();
})().catch(err => {
  console.error('CDP failed:', err && err.stack ? err.stack : String(err));
  process.exit(1);
});
NODE
EOF
chmod +x "$INJECT_COOKIES_SKILL_DIR/cookies-inject-tradingview.sh"
cat > "$INJECT_COOKIES_SKILL_DIR/inject-cookies" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

COOKIE_STRING="${1:-}"
TARGET_URL="${2:-https://www.tradingview.com/chart/}"

if [[ -z "$COOKIE_STRING" ]]; then
  echo 'Usage: ./inject-cookies "name=value; other=value" [target-url]' >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

python3 - <<'PY' "$COOKIE_STRING" "$TARGET_URL" "$TMP_JSON"
import json
import sys

cookie_string = sys.argv[1]
target_url = sys.argv[2]
output_path = sys.argv[3]

cookies = []
for part in cookie_string.split(';'):
    chunk = part.strip()
    if not chunk or '=' not in chunk:
        continue
    name, value = chunk.split('=', 1)
    name = name.strip()
    value = value.strip()
    if not name:
        continue
    cookies.append(
        {
            "name": name,
            "value": value,
            "domain": ".tradingview.com",
            "path": "/",
            "secure": True,
        }
    )

if not cookies:
    raise SystemExit("No valid cookies found in cookie string.")

with open(output_path, "w", encoding="utf-8") as fh:
    json.dump({"targetUrl": target_url, "cookies": cookies}, fh)
    fh.write("\n")
PY

"$SCRIPT_DIR/cookies-inject-tradingview.sh" "$TMP_JSON" "$TARGET_URL"
EOF
chmod +x "$INJECT_COOKIES_SKILL_DIR/inject-cookies"
cat > "$INJECT_COOKIES_SKILL_DIR/SKILL.md" <<'EOF'
---
name: inject-cookies
description: Inject a raw TradingView cookie string into the running TradingView desktop app through Chrome DevTools Protocol.
---

# Inject Cookies

Use this skill when asked to inject TradingView cookies into the running desktop app.

## Workflow

1. Confirm TradingView Desktop is already running with remote debugging enabled.
2. Run `./inject-cookies "name=value; other=value"` from this skill directory.
3. Optionally pass a second argument to override the target URL.
4. If injection fails, inspect `/data/tradingview-launch.log` and confirm the debug port is reachable.

## Examples

- `./inject-cookies "sessionid=abc123; cachec=xyz456"`
- `./inject-cookies "sessionid=abc123; cachec=xyz456" https://www.tradingview.com/chart/`

## Files

- `inject-cookies`: wrapper that converts a raw cookie string into JSON and calls the injector.
- `cookies-inject-tradingview.sh`: low-level CDP cookie injector.
EOF

chown -R 1000:1000 "$SKILLS_DIR" 2>/dev/null || true
chmod -R u+rwX,g+rwX "$SKILLS_DIR" 2>/dev/null || true
__INNER_CMD__
)"

if is_inside_container; then
  log_status "[tradingview-mcp] install started"
  trap 'log_status "[tradingview-mcp] install failed"' ERR
  WORKSPACE_DIR="$WORKSPACE_DIR" \
  REPO_DIR="$REPO_DIR" \
  SKILLS_DIR="$SKILLS_DIR" \
  LAUNCH_SKILL_DIR="$LAUNCH_SKILL_DIR" \
  INJECT_COOKIES_SKILL_DIR="$INJECT_COOKIES_SKILL_DIR" \
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
    -e SKILLS_DIR="$SKILLS_DIR" \
    -e LAUNCH_SKILL_DIR="$LAUNCH_SKILL_DIR" \
    -e INJECT_COOKIES_SKILL_DIR="$INJECT_COOKIES_SKILL_DIR" \
    -e REPO_URL="$REPO_URL" \
    -e REPO_REF="$REPO_REF" \
    -e LAUNCH_SCRIPT="$LAUNCH_SCRIPT" \
    -e TV_DEB_URL="$TV_DEB_URL" \
    "$CONTAINER_NAME" sh -lc "$INNER_CMD"
fi

log_status "[tradingview-mcp] install completed successfully"
echo "[tradingview-mcp-skill] Installed TradingView MCP prerequisites and repository successfully."
