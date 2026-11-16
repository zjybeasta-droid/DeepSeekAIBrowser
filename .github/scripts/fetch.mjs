import { chromium } from 'playwright';
import fs from 'node:fs';

const target = process.argv[2];
if (!target) {
  console.error('usage: node fetch.mjs <url>');
  process.exit(1);
}

const outDir = 'out';
fs.mkdirSync(outDir, { recursive: true });

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const MEDIA_RE = /\.(m3u8|mpd|mp4|m4v|webm|mov|flv)(\?|#|$)/i;

const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--disable-dev-shm-usage'],
});

const context = await browser.newContext({
  userAgent: UA,
  locale: 'en-US',
  timezoneId: 'America/New_York',
  viewport: { width: 1440, height: 900 },
  extraHTTPHeaders: { 'Accept-Language': 'en-US,en;q=0.9' },
});

// 去掉最明显的自动化指纹，Cloudflare 的挑战对 navigator.webdriver 很敏感
await context.addInitScript(() => {
  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
  Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
});

const page = await context.newPage();

const requests = [];
const mediaHits = [];
const apiCalls = [];

page.on('request', (req) => {
  const url = req.url();
  requests.push(`${req.method()} ${url}`);
  if (MEDIA_RE.test(url)) mediaHits.push(url);
  if (/\/(api|ajax|graphql)\//i.test(url) && !MEDIA_RE.test(url)) {
    apiCalls.push(`${req.method()} ${url}`);
  }
});

page.on('response', async (res) => {
  try {
    const ct = (res.headers()['content-type'] || '').toLowerCase();
    if (/mpegurl|dash\+xml|video\//.test(ct)) {
      mediaHits.push(`[${res.status()} ${ct}] ${res.url()}`);
    }
  } catch {}
});

let navError = '';
let status = 0;
try {
  const resp = await page.goto(target, { waitUntil: 'domcontentloaded', timeout: 90000 });
  status = resp ? resp.status() : 0;
  await page.waitForTimeout(12000);
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)).catch(() => {});
  await page.waitForTimeout(4000);
} catch (e) {
  navError = String(e);
}

const info = await page.evaluate(() => {
  const cut = (s, n) => (s || '-').slice(0, n);
  const lines = [];
  lines.push('URL: ' + location.href);
  lines.push('TITLE: ' + cut(document.title, 140));
  lines.push('READY: ' + document.readyState);

  const vids = Array.from(document.querySelectorAll('video'));
  lines.push('VIDEO(' + vids.length + ')');
  vids.slice(0, 6).forEach((v, i) => {
    lines.push('  [' + i + '] src=' + cut(v.src, 200) + ' cur=' + cut(v.currentSrc, 200) +
               ' rs=' + v.readyState + ' dur=' + (isFinite(v.duration) ? v.duration : '?') +
               ' poster=' + cut(v.getAttribute('poster'), 100));
  });

  const srcs = Array.from(document.querySelectorAll('source'));
  lines.push('SOURCE(' + srcs.length + ')');
  srcs.slice(0, 6).forEach((s, i) => lines.push('  [' + i + '] ' + cut(s.src, 200) + ' type=' + cut(s.getAttribute('type'), 40)));

  const frames = Array.from(document.querySelectorAll('iframe'));
  lines.push('IFRAME(' + frames.length + ')');
  frames.slice(0, 10).forEach((f, i) => {
    let host = '';
    try { host = new URL(f.src, location.href).host; } catch (e) {}
    lines.push('  [' + i + '] host=' + host + ' | ' + cut(f.src, 200));
  });

  const scripts = Array.from(document.querySelectorAll('script[src]')).map((s) => s.src);
  lines.push('SCRIPTS(' + scripts.length + ')');
  scripts.slice(0, 15).forEach((u) => lines.push('  ' + cut(u, 180)));

  // 视频页链接：下一步挑一页深挖
  const links = Array.from(document.querySelectorAll('a[href]'))
    .map((a) => a.getAttribute('href'))
    .filter((h) => h && /\/(video|watch|v)\//i.test(h));
  lines.push('VIDEO-LINKS(' + links.length + ')');
  Array.from(new Set(links)).slice(0, 25).forEach((h) => lines.push('  ' + cut(h, 180)));

  const mags = Array.from(document.querySelectorAll('a[href^="magnet:"]')).length;
  lines.push('MAGNET-LINKS: ' + mags);

  return lines.join('\n');
});

fs.writeFileSync(`${outDir}/report.txt`, `status=${status}\nerror=${navError}\n\n${info}\n`);
fs.writeFileSync(`${outDir}/requests.txt`, Array.from(new Set(requests)).join('\n'));
fs.writeFileSync(`${outDir}/media.txt`, Array.from(new Set(mediaHits)).join('\n'));
fs.writeFileSync(`${outDir}/api.txt`, Array.from(new Set(apiCalls)).slice(0, 200).join('\n'));
fs.writeFileSync(`${outDir}/page.html`, await page.content());

console.log(`status=${status} error=${navError || 'none'}`);
console.log(`requests=${requests.length} media=${mediaHits.length} api=${apiCalls.length}`);

await browser.close();
