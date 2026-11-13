// Manual browser test for the book service worker.
// Run: node tests/browser-offline.mjs chromium [executable]
//      node tests/browser-offline.mjs firefox [executable]
//
// Needs a build of both HTML forms. See docs/checks.md.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const playwrightCore = process.env.PLAYWRIGHT_CORE
  || '/build/bickr/scratch/d1-browser-test/node_modules/playwright-core';
const sectionDir = path.resolve(process.env.CLL_SECTION || path.join(repo, 'build/xhtml_section_chunks'));
const singleDir = path.resolve(process.env.CLL_SINGLE || path.join(repo, 'build/xhtml_no_chunks'));
const port = Number(process.env.CLL_PORT || 18905);
const browserName = process.argv[2] || 'chromium';
const executable = process.argv[3];
const versionPath = '/cll/1.3.8';
const failures = [];

function check(name, ok, extra = '') {
  console.log(ok ? 'PASS' : 'FAIL', name, extra);
  if (!ok) failures.push(name + (extra ? ' ' + extra : ''));
  return ok;
}

function parseWorker(file) {
  const text = fs.readFileSync(file, 'utf8');
  const build = text.match(/const BUILD = '([0-9a-f]{16})'/);
  const precache = text.match(/const PRECACHE = (\[[\s\S]*?\n\]);/);
  const lazy = text.match(/const LAZY = new Set\((\[.*\])\);/);
  if (!build || !precache || !lazy) throw new Error('cannot parse ' + file);
  return { build: build[1], precache: JSON.parse(precache[1]), lazy: JSON.parse(lazy[1]) };
}

function fileTitle(file) {
  const match = fs.readFileSync(file, 'utf8').match(/<title>([^<]*)<\/title>/);
  if (!match) return '';
  return match[1].replace(/&nbsp;|&#160;/g, '\u00a0').replace(/&amp;/g, '&');
}

function largestHtml(dir) {
  let best = null;
  let size = -1;
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith('.html')) continue;
    const bytes = fs.statSync(path.join(dir, name)).size;
    if (bytes > size) { best = name; size = bytes; }
  }
  return best;
}

function firstMp3(dir) {
  const root = path.join(dir, 'assets/media');
  const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    if (!fs.existsSync(current)) continue;
    for (const name of fs.readdirSync(current)) {
      const full = path.join(current, name);
      if (fs.statSync(full).isDirectory()) stack.push(full);
      else if (name.endsWith('.mp3')) return path.relative(dir, full);
    }
  }
  return null;
}

function assertList(label, parsed, { section }) {
  const paths = parsed.precache.map((entry) => entry[0]);
  const forbidden = /(^|\/)(vreji|dtd|context)\b|noto-cjk|weasyprint|polyfill|sance-next|\.mp3$|\.ogg$|cll\.appcache/;
  const bad = paths.filter((item) => forbidden.test(item));
  if (bad.length) throw new Error(label + ' precache has ' + bad.slice(0, 5).join(', '));
  for (const required of ['final.css', 'assets/scripts/offline.js', 'index.html']) {
    if (!paths.includes(required)) throw new Error(label + ' precache lacks ' + required);
  }
  if (!paths.some((item) => /libertine/i.test(item))) throw new Error(label + ' precache lacks a Libertine font');
  if (!paths.some((item) => item.endsWith('.png'))) throw new Error(label + ' precache lacks a picture');
  if (section && !paths.includes('assets/scripts/sance.js')) throw new Error(label + ' precache lacks sance.js');
  if (paths.includes('sw.js')) throw new Error(label + ' precache lists sw.js');
  const expectedLazy = [
    'assets/fonts/noto-cjk-korean-serif.otf',
    'assets/fonts/noto-cjk-simplified-chinese-serif.otf',
  ];
  if (JSON.stringify(parsed.lazy) !== JSON.stringify(expectedLazy)) {
    throw new Error(label + ' lazy list is ' + JSON.stringify(parsed.lazy));
  }
  return paths.length;
}

function startServer(root) {
  const types = {
    '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'application/javascript',
    '.png': 'image/png', '.otf': 'font/otf', '.mp3': 'audio/mpeg', '.svg': 'image/svg+xml',
  };
  const log = [];
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/__log') { res.end(JSON.stringify(log)); return; }
    if (url.pathname === '/__clear') { log.length = 0; res.end('ok'); return; }
    log.push(req.method + ' ' + url.pathname + (req.headers.range ? ' [' + req.headers.range + ']' : ''));
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '');
    const filePath = path.resolve(root, rel);
    if (filePath !== root && !filePath.startsWith(root + path.sep)) {
      res.writeHead(403).end();
      return;
    }
    let stat = fs.existsSync(filePath) ? fs.statSync(filePath) : null;
    if (stat && stat.isDirectory()) {
      if (!url.pathname.endsWith('/')) {
        res.writeHead(301, { location: url.pathname + '/' }).end();
        return;
      }
      const index = path.join(filePath, 'index.html');
      stat = fs.existsSync(index) ? fs.statSync(index) : null;
      if (!stat) { res.writeHead(404).end('missing index'); return; }
      return send(res, req, index, stat, types);
    }
    if (!stat) { res.writeHead(404, { 'content-type': 'text/html' }).end('<h1>404</h1>'); return; }
    send(res, req, filePath, stat, types);
  });
  function send(res, req, file, stat, typeMap) {
    const headers = {
      'content-type': typeMap[path.extname(file)] || 'application/octet-stream',
      'cache-control': 'max-age=600',
      'accept-ranges': 'bytes',
    };
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
    if (range) {
      const start = range[1] ? Number(range[1]) : 0;
      const end = range[2] ? Number(range[2]) : stat.size - 1;
      res.writeHead(206, {
        ...headers,
        'content-range': `bytes ${start}-${end}/${stat.size}`,
        'content-length': end - start + 1,
      });
      if (req.method === 'HEAD') { res.end(); return; }
      fs.createReadStream(file, { start, end }).pipe(res);
      return;
    }
    res.writeHead(200, { ...headers, 'content-length': stat.size });
    if (req.method === 'HEAD') { res.end(); return; }
    fs.createReadStream(file).pipe(res);
  }
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve({ server, log }));
  });
}

async function serverLog() {
  return fetch('http://127.0.0.1:' + port + '/__log').then((response) => response.json());
}
async function requestUpdate(page) {
  await page.evaluate(async () => {
    const registration = await navigator.serviceWorker.getRegistration();
    if (registration) await registration.update();
  });
}
async function clearLog() {
  await fetch('http://127.0.0.1:' + port + '/__clear');
}
function ignoredOffline(line) {
  return line.includes(' sw.js') || line.endsWith('/sw.js') || line.includes('favicon.ico');
}

const sectionList = assertList('section', parseWorker(path.join(sectionDir, 'sw.js')), { section: true });
const singleList = assertList('one-page', parseWorker(path.join(singleDir, 'sw.js')), { section: false });
for (const name of ['section-gismu.html', 'section-pronunciation.html', 'section-topic-comments.html', 'chapter-tour.html']) {
  if (!fs.existsSync(path.join(sectionDir, name))) throw new Error('missing ' + name);
}
const sample = fs.readFileSync(path.join(sectionDir, 'section-gismu.html'), 'utf8');
if (sample.includes('manifest=')) throw new Error('section page still has a manifest attribute');
if (!sample.includes('src="assets/scripts/offline.js"')) throw new Error('section page has no offline.js');
const biggest = largestHtml(sectionDir);
const audio = firstMp3(sectionDir);
if (!biggest) throw new Error('section folder has no html page');
if (!audio) throw new Error('section folder has no mp3');
console.log('precache', sectionList, singleList, 'largest', biggest, 'audio', audio);

const scratch = fs.mkdtempSync(path.join('/build/cll/service-worker-205', 'browser-'));
const book = path.join(scratch, 'cll/1.3.8');
fs.mkdirSync(path.join(book, 'diff_from_previous'), { recursive: true });
fs.symlinkSync(sectionDir, path.join(book, 'xhtml_section_chunks'));
fs.cpSync(singleDir, path.join(book, 'xhtml_no_chunks'), { recursive: true, dereference: true });
fs.writeFileSync(path.join(book, 'index.html'), '<!DOCTYPE html><html><head><title>CLL</title></head><body><p>landing</p></body></html>\n');
fs.writeFileSync(path.join(book, 'diff_from_previous/difference.html'),
  '<!DOCTYPE html><html><head><script defer src="../xhtml_no_chunks/assets/scripts/offline.js"></script></head><body><p>comparison</p></body></html>\n');

const pw = require(playwrightCore);
const base = 'http://127.0.0.1:' + port + versionPath + '/';
let browser;
let server;
try {
  ({ server } = await startServer(scratch));
  browser = await pw[browserName].launch({ headless: true, ...(executable ? { executablePath: executable } : {}) });
  console.log(browserName, browser.version());
  const context = await browser.newContext();
  const page = await context.newPage();
  page.setDefaultTimeout(60000);
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error)));

  await clearLog();
  await page.goto(base + 'diff_from_previous/difference.html', { waitUntil: 'load' });
  await page.waitForTimeout(1500);
  let regs = await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).map((item) => item.scope));
  let log = await serverLog();
  check('diff page loads offline.js', log.some((line) => line.includes('xhtml_no_chunks/assets/scripts/offline.js')));
  check('diff page registers nothing', regs.length === 0, JSON.stringify(regs));
  check('diff page requests no sw.js', !log.some((line) => line.includes('sw.js')));

  await clearLog();
  const started = Date.now();
  await page.goto(base + 'xhtml_section_chunks/section-gismu.html', { waitUntil: 'load' });
  await page.waitForFunction(() => document.documentElement.getAttribute('data-offline') === 'ready', null, { timeout: 180000 });
  console.log('install ms', Date.now() - started);
  regs = await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).map((item) => item.scope));
  check('one registration for the section folder', regs.length === 1 && regs[0] === base + 'xhtml_section_chunks/', JSON.stringify(regs));
  let info = await page.evaluate(async () => {
    const out = {};
    for (const name of await caches.keys()) out[name] = (await (await caches.open(name)).keys()).length;
    return out;
  });
  const counts = Object.values(info);
  check('one cache with the precache count', Object.keys(info).length === 1 && counts[0] === sectionList, JSON.stringify(info));
  log = await serverLog();
  const fetched = log.filter((line) => /GET /.test(line) && !line.includes('[bytes=')
    && /vreji|media\/examples|\/dtd\/|noto-cjk|weasyprint|polyfill|sance-next|\/context\//.test(line));
  check('install fetches no audio, Noto, dtd, or PDF-only file', fetched.length === 0, fetched.slice(0, 3).join(' | '));

  await context.setOffline(true);
  await clearLog();
  let response = await page.goto(base + 'xhtml_section_chunks/section-pronunciation.html', { waitUntil: 'load' }).catch((error) => ({ err: String(error) }));
  const title = response && !response.err ? await page.title() : '';
  const expectedTitle = fileTitle(path.join(sectionDir, 'section-pronunciation.html'));
  check('offline unvisited page opens', !!(response && !response.err && response.status() === 200 && response.fromServiceWorker()), response && response.err);
  check('offline title matches the built page', title === expectedTitle, JSON.stringify(title));
  const fonts = await page.evaluate(async () => {
    await document.fonts.ready;
    return [...document.fonts].filter((font) => font.status === 'loaded').map((font) => font.family);
  });
  check('offline Libertine is active', fonts.some((family) => /Libertine/.test(family)), fonts.join(', '));

  response = await page.goto(base + 'xhtml_section_chunks/', { waitUntil: 'load' }).catch((error) => ({ err: String(error) }));
  check('offline folder URL opens', !!(response && !response.err && response.status() === 200), response && response.err);
  response = await page.goto(base + 'xhtml_section_chunks/chapter-tour.html?x=1#section-bridi', { waitUntil: 'load' }).catch((error) => ({ err: String(error) }));
  check('offline query and fragment open', !!(response && !response.err && response.status() === 200), response && response.err);
  const picture = await page.evaluate(() => [...document.images].some((image) => image.complete && image.naturalWidth > 0 && /chapter-/.test(image.getAttribute('src') || '')));
  check('offline chapter picture has width', picture);

  const href = await page.evaluate(() => {
    const link = [...document.querySelectorAll('a[href]')].find((item) => /^[A-Za-z0-9._-]+\.html$/.test(item.getAttribute('href')));
    return link ? link.getAttribute('href') : '';
  });
  const beforeUrl = page.url();
  if (href) await page.click('a[href="' + href + '"]');
  await page.waitForLoadState('load');
  check('offline link opens the next page', !!href && page.url() !== beforeUrl, page.url());

  response = await page.goto(base + 'xhtml_section_chunks/' + biggest, { waitUntil: 'load' }).catch((error) => ({ err: String(error) }));
  check('offline largest page opens', !!(response && !response.err && response.status() === 200), biggest + ' ' + (response && response.err || ''));
  response = await page.goto(base + 'xhtml_no_chunks/index.html', { waitUntil: 'load' }).catch((error) => ({ err: String(error) }));
  check('offline other form is outside this worker', !!(response && response.err), response && (response.err || '').slice(0, 120));
  response = await page.goto(base + 'index.html', { waitUntil: 'load' }).catch((error) => ({ err: String(error) }));
  check('offline landing page is outside this worker', !!(response && response.err));
  log = await serverLog();
  const leaked = log.filter((line) => !ignoredOffline(line));
  check('offline server log is empty', leaked.length === 0, leaked.slice(0, 3).join(' | '));

  await context.setOffline(false);
  await clearLog();
  await page.goto(base + 'xhtml_section_chunks/section-gismu.html', { waitUntil: 'load' });
  await page.waitForTimeout(1500);
  log = await serverLog();
  const pageGets = log.filter((line) => line.startsWith('GET ') && !line.includes('[bytes=')
    && (line.includes('section-gismu.html') || line.includes('final.css')) && !line.endsWith('/sw.js'));
  check('controlled page serves html and css from the cache', pageGets.length === 0, pageGets.slice(0, 3).join(' | '));
  const probed = await page.evaluate(async (file) => {
    const head = await fetch(file, { method: 'HEAD' }).then((item) => item.status).catch((error) => String(error));
    const range = await fetch(file, { headers: { Range: 'bytes=0-99' } })
      .then(async (item) => item.status + ':' + (await item.arrayBuffer()).byteLength)
      .catch((error) => String(error));
    return { head, range };
  }, audio);
  check('HEAD returns 200 and Range returns 206', probed.head === 200 && probed.range === '206:100', JSON.stringify(probed));

  await page.goto(base + 'xhtml_no_chunks/index.html', { waitUntil: 'load' });
  await page.waitForFunction(() => document.documentElement.getAttribute('data-offline') === 'ready', null, { timeout: 180000 });
  info = await page.evaluate(async () => {
    const out = {};
    for (const name of await caches.keys()) out[name] = (await (await caches.open(name)).keys()).length;
    return out;
  });
  const names = Object.keys(info);
  check('two caches, one per folder', names.length === 2
    && names.some((name) => name.includes('/xhtml_section_chunks/:'))
    && names.some((name) => name.includes('/xhtml_no_chunks/:'))
    && info[names.find((name) => name.includes('/xhtml_no_chunks/:'))] === singleList, JSON.stringify(info));

  await clearLog();
  await page.goto(base + 'xhtml_section_chunks/section-topic-comments.html', { waitUntil: 'load' });
  await page.evaluate(async () => { await document.fonts.ready; });
  let noto = [];
  for (let attempt = 0; attempt < 40; attempt += 1) {
    noto = await page.evaluate(async () => {
      const keys = [];
      for (const name of await caches.keys()) {
        if (!name.includes('/xhtml_section_chunks/:')) continue;
        for (const request of await (await caches.open(name)).keys()) keys.push(request.url);
      }
      return keys.filter((url) => url.includes('noto-cjk-simplified-chinese'));
    });
    if (noto.length) break;
    await page.waitForTimeout(500);
  }
  check('Chinese page stores the Noto font', noto.length >= 1, JSON.stringify(noto));
  await context.setOffline(true);
  await page.goto(base + 'xhtml_section_chunks/section-topic-comments.html', { waitUntil: 'load' });
  const cjk = await page.evaluate(async () => {
    await document.fonts.ready;
    return [...document.fonts].filter((font) => font.status === 'loaded').map((font) => font.family);
  });
  check('offline Noto font is active', cjk.some((family) => /noto-cjk-simplified-chinese/.test(family)), cjk.join(', '));
  await context.setOffline(false);

  const singleCopy = path.join(book, 'xhtml_no_chunks');
  const indexFile = path.join(singleCopy, 'index.html');
  const generate = () => execFileSync('ruby', [
    path.join(repo, 'scripts/xhtml_postprocess_offline.rb'),
    singleCopy,
    path.join(repo, 'scripts/sw.template.js'),
  ], { stdio: 'pipe' });
  fs.appendFileSync(indexFile, '\n<!-- offline-build-two -->\n');
  generate();
  await page.goto(base + 'xhtml_no_chunks/index.html', { waitUntil: 'load' });
  await requestUpdate(page);
  const previous = names.find((name) => name.includes('/xhtml_no_chunks/:')) || '';
  let updated = previous;
  for (let attempt = 0; attempt < 90; attempt += 1) {
    const now = Object.keys(await page.evaluate(async () => {
      const out = {};
      for (const name of await caches.keys()) out[name] = true;
      return out;
    }));
    updated = now.find((name) => name.includes('/xhtml_no_chunks/:')) || '';
    if (updated && updated !== previous && now.length <= 2) break;
    await page.waitForTimeout(1000);
  }
  check('update replaces the one-page cache', !!updated && updated !== previous, updated);
  await page.goto(base + 'xhtml_no_chunks/index.html', { waitUntil: 'load' });
  const seenUpdate = await page.evaluate(async () => (await (await fetch('index.html')).text()).includes('offline-build-two'));
  check('second reload shows the new page', seenUpdate === true);

  fs.appendFileSync(indexFile, '\n<!-- offline-torn -->\n');
  const swFile = path.join(singleCopy, 'sw.js');
  const swText = fs.readFileSync(swFile, 'utf8');
  const currentBuild = swText.match(/const BUILD = '([0-9a-f]{16})'/)[1];
  const fake = currentBuild === 'deadbeefdeadbeef' ? 'cafebabecafebabe' : 'deadbeefdeadbeef';
  fs.writeFileSync(swFile, swText.replace(/const BUILD = '[0-9a-f]{16}'/, "const BUILD = '" + fake + "'"));
  await page.goto(base + 'xhtml_no_chunks/index.html', { waitUntil: 'load' });
  await requestUpdate(page);
  let state = { active: false, waiting: true, installing: true };
  for (let attempt = 0; attempt < 60; attempt += 1) {
    state = await page.evaluate(async () => {
      const registration = await navigator.serviceWorker.getRegistration();
      return {
        active: !!(registration && registration.active),
        waiting: !!(registration && registration.waiting),
        installing: !!(registration && registration.installing),
      };
    });
    if (state.active && !state.waiting && !state.installing) break;
    await page.waitForTimeout(1000);
  }
  const tornText = await page.evaluate(async () => (await (await fetch('index.html')).text()));
  check('broken deploy keeps the previous page', tornText.includes('offline-build-two') && !tornText.includes('offline-torn'));
  check('broken deploy leaves no waiting worker', state.active && !state.waiting && !state.installing, JSON.stringify(state));
  await context.setOffline(true);
  response = await page.goto(base + 'xhtml_no_chunks/index.html', { waitUntil: 'load' }).catch((error) => ({ err: String(error) }));
  check('broken deploy still opens offline', !!(response && !response.err && response.status() === 200), response && response.err);
  await context.setOffline(false);
  generate();
  await page.goto(base + 'xhtml_no_chunks/index.html', { waitUntil: 'load' });
  await requestUpdate(page);
  let repaired = false;
  for (let attempt = 0; attempt < 90; attempt += 1) {
    repaired = await page.evaluate(async () => (await (await fetch('index.html')).text()).includes('offline-torn'));
    if (repaired) break;
    await page.waitForTimeout(1000);
  }
  check('generator repair completes the next visit', repaired === true);

  check('no page script error', errors.length === 0, errors.slice(0, 3).join(' | '));
} finally {
  if (browser) await browser.close();
  if (server) await new Promise((resolve) => server.close(resolve));
  fs.rmSync(scratch, { recursive: true, force: true });
}

if (failures.length) {
  console.log(failures.length + ' FAILED');
  process.exit(1);
}
console.log('ALL PASS');
