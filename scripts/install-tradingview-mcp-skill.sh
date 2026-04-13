#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-openclaw}"
REPO_URL="${REPO_URL:-https://github.com/LewisWJackson/tradingview-mcp-jackson}"
REPO_REF="${REPO_REF:-main}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/data/.openclaw/workspace}"
REPO_DIR="${WORKSPACE_DIR}/tradingview-mcp-jackson"
LAUNCH_SCRIPT="${REPO_DIR}/scripts/launch_tv_debug_linux.sh"
SERVER_NAME="${SERVER_NAME:-tradingview}"
SERVER_SCRIPT="${REPO_DIR}/src/server.js"

docker exec "${CONTAINER_NAME}" sh -lc "
set -eu

if ! command -v git >/dev/null 2>&1; then
  echo 'Missing required command inside container: git' >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo 'Missing required command inside container: python3' >&2
  exit 1
fi

if ! command -v xvfb-run >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo 'xvfb-run is missing and apt-get is unavailable.' >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y xvfb
fi

mkdir -p '${WORKSPACE_DIR}'

if [ -d '${REPO_DIR}/.git' ]; then
  git -C '${REPO_DIR}' remote set-url origin '${REPO_URL}'
  git -C '${REPO_DIR}' fetch --prune origin
  if git -C '${REPO_DIR}' rev-parse --verify --quiet 'origin/${REPO_REF}' >/dev/null; then
    git -C '${REPO_DIR}' checkout -B '${REPO_REF}' 'origin/${REPO_REF}'
  else
    git -C '${REPO_DIR}' checkout '${REPO_REF}'
  fi
else
  rm -rf '${REPO_DIR}'
  git clone '${REPO_URL}' '${REPO_DIR}'
  if git -C '${REPO_DIR}' rev-parse --verify --quiet 'origin/${REPO_REF}' >/dev/null; then
    git -C '${REPO_DIR}' checkout -B '${REPO_REF}' 'origin/${REPO_REF}'
  else
    git -C '${REPO_DIR}' checkout '${REPO_REF}'
  fi
fi

if [ ! -f '${LAUNCH_SCRIPT}' ]; then
  echo 'Missing launch script: ${LAUNCH_SCRIPT}' >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path

launch_path = Path('${LAUNCH_SCRIPT}')
text = launch_path.read_text(encoding='utf-8')
lines = text.splitlines()
target = 'xvfb-run -a \"$APP\" --remote-debugging-port=$PORT --no-sandbox'
replaced = False
next_lines = []
for line in lines:
    stripped = line.strip()
    if '\"$APP\"' in stripped and '--remote-debugging-port=$PORT' in stripped:
        indent = line[: len(line) - len(line.lstrip())]
        next_lines.append(f'{indent}{target}')
        replaced = True
        continue
    next_lines.append(line)
if not replaced:
    if next_lines and next_lines[-1] != '':
        next_lines.append('')
    next_lines.append(target)
launch_path.write_text('\\n'.join(next_lines) + '\\n', encoding='utf-8')
PY

if ! grep -Fq 'xvfb-run -a \"$APP\" --remote-debugging-port=$PORT --no-sandbox' '${LAUNCH_SCRIPT}'; then
  echo 'Failed to enforce launch command pattern in ${LAUNCH_SCRIPT}' >&2
  exit 1
fi

OPENCLAW_MCP_SERVER_NAME='${SERVER_NAME}' \
OPENCLAW_MCP_REPO_DIR='${REPO_DIR}' \
OPENCLAW_MCP_SERVER_SCRIPT='${SERVER_SCRIPT}' \
python3 - <<'PY'
import json
import os
from pathlib import Path

server_name = os.environ['OPENCLAW_MCP_SERVER_NAME'].strip() or 'tradingview'
repo_dir = os.environ['OPENCLAW_MCP_REPO_DIR'].strip()
server_script = os.environ['OPENCLAW_MCP_SERVER_SCRIPT'].strip()

if not repo_dir or not server_script:
    raise SystemExit('Missing MCP repo/script path values.')

targets = [
    Path('/data/.openclaw/openclaw.json'),
    Path('/home/node/.openclaw/openclaw.json'),
]

server_doc = {
    'command': 'xvfb-run',
    'args': ['-a', 'node', server_script],
    'cwd': repo_dir,
}

updated_paths = []
for path in targets:
    if not path.exists():
        continue
    try:
        doc = json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        doc = {}
    if not isinstance(doc, dict):
        doc = {}

    mcp_servers = doc.get('mcpServers')
    if not isinstance(mcp_servers, dict):
        mcp_servers = {}
    mcp_servers[server_name] = server_doc
    doc['mcpServers'] = mcp_servers

    tools = doc.get('tools')
    if not isinstance(tools, dict):
        tools = {}
    mcp_tools = tools.get('mcp')
    if not isinstance(mcp_tools, dict):
        mcp_tools = {}
    mcp_tools['enabled'] = True
    nested_servers = mcp_tools.get('servers')
    if not isinstance(nested_servers, dict):
        nested_servers = {}
    nested_servers[server_name] = server_doc
    mcp_tools['servers'] = nested_servers
    tools['mcp'] = mcp_tools
    doc['tools'] = tools

    agents = doc.get('agents')
    if not isinstance(agents, dict):
        agents = {}
    defaults = agents.get('defaults')
    if not isinstance(defaults, dict):
        defaults = {}
    agent_mcp_servers = defaults.get('mcpServers')
    if not isinstance(agent_mcp_servers, dict):
        agent_mcp_servers = {}
    agent_mcp_servers[server_name] = server_doc
    defaults['mcpServers'] = agent_mcp_servers
    agents['defaults'] = defaults
    doc['agents'] = agents

    path.write_text(json.dumps(doc, indent=2) + '\\n', encoding='utf-8')
    updated_paths.append(path)

if not updated_paths:
    raise SystemExit('No openclaw.json target found to update.')

verified = False
for path in updated_paths:
    try:
        doc = json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        continue

    top = doc.get('mcpServers', {})
    tools = ((doc.get('tools') or {}).get('mcp') or {}).get('servers', {})
    agents = (((doc.get('agents') or {}).get('defaults') or {}).get('mcpServers', {}))

    candidates = []
    if isinstance(top, dict):
        candidates.append(top.get(server_name))
    if isinstance(tools, dict):
        candidates.append(tools.get(server_name))
    if isinstance(agents, dict):
        candidates.append(agents.get(server_name))

    for entry in candidates:
        if not isinstance(entry, dict):
            continue
        if (
            entry.get('command') == 'xvfb-run'
            and entry.get('args') == ['-a', 'node', server_script]
            and entry.get('cwd') == repo_dir
        ):
            verified = True
            break
    if verified:
        break

if not verified:
    raise SystemExit('OpenClaw MCP config verification failed for server tradingview.')
PY
"

echo "[tradingview-mcp-skill] Installed and verified MCP server '${SERVER_NAME}' in OpenClaw config."
