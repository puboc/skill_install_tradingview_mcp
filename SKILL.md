---
name: install-tradingview-mcp
description: Install or update tradingview-mcp-jackson in OpenClaw workspace, patch Linux launch script to use xvfb no-sandbox, and register OpenClaw MCP server config for tradingview.
---

# Install TradingView MCP

Use this skill when asked to install or fix TradingView MCP for OpenClaw.

## Workflow

1. Run `scripts/install-tradingview-mcp-skill.sh`.
2. Do not continue if the script fails.
3. After install, configure OpenClaw as an MCP client for the TradingView server.
4. Confirm MCP config is present before proceeding.

## What the installer does

1. Installs `xvfb` if `xvfb-run` is missing.
2. Clones or updates `https://github.com/LewisWJackson/tradingview-mcp-jackson` at `/data/.openclaw/workspace/tradingview-mcp-jackson`.
3. Patches `scripts/launch_tv_debug_linux.sh` so launch command is exactly:
   `xvfb-run -a "$APP" --remote-debugging-port=$PORT --no-sandbox`
4. Configure OpenClaw MCP server `tradingview` in `openclaw.json` after install:
   - command: `xvfb-run`
   - args: `-a node /data/.openclaw/workspace/tradingview-mcp-jackson/src/server.js`
   - cwd: `/data/.openclaw/workspace/tradingview-mcp-jackson`
5. Ensure OpenClaw is an MCP client before proceeding.
