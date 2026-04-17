#!/usr/bin/env node
import fs from 'fs';
import os from 'os';
import path from 'path';
import CDP from 'chrome-remote-interface';

const host = process.env.CDP_HOST || '127.0.0.1';
const port = Number(process.env.CDP_PORT || '9222');
const targetMatch = process.env.TARGET_MATCH || 'https://www.tradingview.com/chart/';
const pageWaitMs = Math.max(0, Number(process.env.PAGE_WAIT_MS || '5000'));
const defaultTargetUrl = process.env.TARGET_URL || '';

function usage() {
  console.error(`Usage:
  node scripts/tv_inject_cookies_flexible.js --file /path/to/cookies.json [--target-url https://www.tradingview.com/chart/]
  node scripts/tv_inject_cookies_flexible.js --string 'name=value; other=value' [--target-url https://www.tradingview.com/chart/]

Accepted JSON formats:
  1) [ { ...cookie }, ... ]
  2) { "cookies": [ ... ] }
  3) { "url"|"targetUrl"|"baseUrl": "...", "cookies": [ ... ] }
`);
}

function parseArgs(argv) {
  const args = { file: '', string: '', targetUrl: defaultTargetUrl };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--file') args.file = argv[++i] || '';
    else if (a === '--string') args.string = argv[++i] || '';
    else if (a === '--target-url') args.targetUrl = argv[++i] || '';
    else if (a === '--help' || a === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${a}`);
  }
  return args;
}

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

function normalizeExpires(value) {
  if (value === undefined || value === null || value === '') return undefined;
  if (typeof value === 'number' && Number.isFinite(value)) return Math.floor(value);
  if (typeof value === 'string') {
    const asNumber = Number(value);
    if (Number.isFinite(asNumber)) return Math.floor(asNumber);
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) return Math.floor(parsed / 1000);
  }
  return undefined;
}

function extractCookies(rawData) {
  if (Array.isArray(rawData)) return rawData;
  if (rawData && Array.isArray(rawData.cookies)) return rawData.cookies;
  throw new Error('Unsupported cookie JSON format. Use either an array or an object with a "cookies" array.');
}

function inferTargetUrl(rootConfig, cookies, cliTargetUrl) {
  const candidates = [
    cliTargetUrl,
    rootConfig?.targetUrl,
    rootConfig?.url,
    rootConfig?.baseUrl,
    rootConfig?.origin,
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

  throw new Error('Could not determine target URL. Pass --target-url or include url/targetUrl in the JSON.');
}

function buildCookieUrl(cookie, fallbackUrl) {
  if (typeof cookie.url === 'string' && cookie.url.trim()) return cookie.url.trim();

  const domain = normalizeDomain(cookie.domain);
  const cookiePath = normalizePath(cookie.path);

  if (domain) {
    let protocol = cookie.secure === true ? 'https:' : 'http:';
    if (fallbackUrl) {
      try {
        const fp = new URL(fallbackUrl).protocol;
        if (fp) protocol = cookie.secure === true ? 'https:' : fp;
      } catch (_) {}
    }
    return `${protocol}//${domain}${cookiePath}`;
  }

  if (fallbackUrl) {
    const url = new URL(fallbackUrl);
    url.pathname = cookiePath;
    url.search = '';
    url.hash = '';
    return url.toString();
  }

  return null;
}

function parseCookieString(cookieString, targetUrl) {
  const cookies = [];
  for (const part of cookieString.split(';')) {
    const chunk = part.trim();
    if (!chunk || !chunk.includes('=')) continue;
    const [nameRaw, ...rest] = chunk.split('=');
    const name = nameRaw.trim();
    const value = rest.join('=').trim();
    if (!name) continue;
    cookies.push({
      name,
      value,
      domain: '.tradingview.com',
      path: '/',
      secure: true,
    });
  }
  if (!cookies.length) throw new Error('No valid cookies found in cookie string.');
  return { targetUrl: targetUrl || targetMatch, cookies };
}

async function findTradingViewTarget() {
  const targets = await CDP.List({ host, port });
  const preferred = targets.find(t =>
    t.type === 'page' && (
      (t.url && t.url.includes(targetMatch)) ||
      (t.title && t.title.toLowerCase().includes('tradingview'))
    )
  );
  if (preferred) return preferred;

  const signin = targets.find(t => t.type === 'page' && /tradingview/i.test(t.url || ''));
  if (signin) return signin;

  const fallback = targets.find(t => t.type === 'page');
  if (fallback) return fallback;

  throw new Error('No page target found in TradingView Desktop.');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || (!args.file && !args.string) || (args.file && args.string)) {
    usage();
    process.exit(args.help ? 0 : 1);
  }

  let rawData;
  let cleanupPath = '';
  if (args.file) {
    rawData = JSON.parse(fs.readFileSync(args.file, 'utf8'));
  } else {
    rawData = parseCookieString(args.string, args.targetUrl);
    cleanupPath = path.join(os.tmpdir(), `tv-cookies-${Date.now()}.json`);
    fs.writeFileSync(cleanupPath, JSON.stringify(rawData, null, 2));
  }

  try {
    const rootConfig = Array.isArray(rawData) ? {} : rawData;
    const cookies = extractCookies(rawData).filter(cookie =>
      cookie &&
      typeof cookie.name === 'string' &&
      cookie.name.length > 0 &&
      cookie.value !== undefined &&
      cookie.value !== null &&
      cookie.value !== 'deleted'
    );

    if (!cookies.length) throw new Error('No valid cookies found in input.');

    const targetUrl = inferTargetUrl(rootConfig, cookies, args.targetUrl);
    const target = await findTradingViewTarget();
    const client = await CDP({ host, port, target: target.id || target.targetId });
    const { Network, Page, Runtime } = client;

    try {
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
        const expires = normalizeExpires(ck.expires ?? ck.expirationDate);
        if (expires !== undefined) params.expires = expires;

        const sameSite = normalizeSameSite(ck.sameSite);
        if (sameSite) params.sameSite = sameSite;

        try {
          const res = await Network.setCookie(params);
          if (res?.success) ok++;
          else failures.push({ name: ck.name, reason: 'setCookie returned unsuccessful result' });
        } catch (err) {
          failures.push({ name: ck.name, reason: err?.message || String(err) });
        }
      }

      console.log(`attached_target: ${target.title || '(untitled)'} | ${target.url || ''}`);
      console.log(`cookies_set: ${ok}/${cookies.length}`);

      await Page.navigate({ url: targetUrl });
      await Page.loadEventFired();
      await Runtime.evaluate({ expression: `new Promise(r => setTimeout(r, ${pageWaitMs}))` });

      const finalUrl = await Runtime.evaluate({ expression: 'location.href', returnByValue: true });
      const title = await Runtime.evaluate({ expression: 'document.title', returnByValue: true });
      const cookieDump = await Runtime.evaluate({ expression: 'document.cookie', returnByValue: true });

      console.log('target_url:', targetUrl);
      console.log('final_url:', finalUrl.result.value);
      console.log('title:', title.result.value);
      console.log('document_cookie_length:', String(cookieDump.result.value || '').length);

      if (failures.length) {
        console.log('failures:', JSON.stringify(failures, null, 2));
      }
    } finally {
      await client.close();
    }
  } finally {
    if (cleanupPath) {
      try { fs.unlinkSync(cleanupPath); } catch (_) {}
    }
  }
}

main().catch(err => {
  console.error('tv_inject_cookies_flexible failed:', err?.stack || String(err));
  process.exit(1);
});
