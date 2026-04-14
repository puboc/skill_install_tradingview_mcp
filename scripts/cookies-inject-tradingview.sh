#!/usr/bin/env bash
set -Eeuo pipefail

# Inject cookies into a running TradingView Desktop app via CDP.
#
# Usage:
#   cookies-inject-tradingview.sh /path/to/cookies.json
#   cookies-inject-tradingview.sh /path/to/cookies.json https://www.tradingview.com/chart/
#
# Supported cookie JSON formats:
#   1) { "url": "https://www.tradingview.com/chart/", "cookies": [ ... ] }
#   2) { "targetUrl": "https://www.tradingview.com/chart/", "cookies": [ ... ] }
#   3) [ ... ]
#
# Expected flow:
#   1) Start TradingView Desktop with remote debugging enabled, e.g.
#      xvfb-run -a tradingview --no-sandbox --remote-debugging-port=9222
#   2) Run this script against the same debug port.
#
# Env:
#   CDP_HOST=127.0.0.1
#   CDP_PORT=9222
#   TARGET_MATCH=https://www.tradingview.com/chart/
#   PAGE_WAIT_MS=5000
#   NODE_DEPS_DIR=/root/.openclaw/workspace/node-deps

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
