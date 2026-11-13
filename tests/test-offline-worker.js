#!/usr/bin/env node
// The book service worker, run against mock caches and fetch.
// Run: node tests/test-offline-worker.js
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const SCOPE = 'https://example.test/cll/1.3.8/xhtml_section_chunks/';
const ORIGIN = 'https://example.test';
const BUILD = '0123456789abcdef';
const CACHE = 'cll-book:/cll/1.3.8/xhtml_section_chunks/:' + BUILD;
const PRECACHE = [
  ['index.html', 'sha256-index'],
  ['final.css', 'sha256-css'],
];
const LAZY = ['assets/fonts/noto-cjk-x.otf'];

const template = fs.readFileSync(path.join(__dirname, '../scripts/sw.template.js'), 'utf8');

function fill(precache, lazy) {
  return template
    .replace('@BUILD@', BUILD)
    .replace('@PRECACHE@', JSON.stringify(precache))
    .replace('@LAZY@', JSON.stringify(lazy));
}

const code = fill(PRECACHE, LAZY);
assert.equal(code.includes('@'), false);
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cll-sw-'));
  const file = path.join(dir, 'sw.js');
  fs.writeFileSync(file, code);
  execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
  fs.rmSync(dir, { recursive: true, force: true });
}

function response(fields) {
  return { status: 200, redirected: false, type: 'basic', clone() { return this; }, ...fields };
}

function boot(routes = new Map(), options = {}) {
  const calls = [];
  const stores = new Map();
  const state = { skipped: 0, claimed: 0, openError: null, opens: [] };
  function bucket(name) {
    if (!stores.has(name)) stores.set(name, new Map());
    return stores.get(name);
  }
  const caches = {
    async open(name) {
      state.opens.push(name);
      if (state.openError) throw state.openError;
      bucket(name);
      return {
        async keys() { return [...bucket(name).keys()].map((url) => ({ url })); },
        async put(url, body) { bucket(name).set(String(url), body); },
        async match(url) { return bucket(name).get(String(url)); },
      };
    },
    async keys() { return [...stores.keys()]; },
    async delete(name) { return stores.delete(name); },
  };
  const listeners = {};
  const sandbox = {
    URL, Promise, Set, Map, Array, Error, JSON, Object,
    caches,
    async fetch(input, options) {
      const url = typeof input === 'string' ? input : input.url;
      calls.push({ url, options, method: typeof input === 'string' ? 'GET' : input.method });
      const made = routes.get(url);
      return made ? made() : response({});
    },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    registration: { scope: SCOPE },
    location: { origin: ORIGIN },
    skipWaiting: async () => { state.skipped += 1; },
    clients: { claim: async () => { state.claimed += 1; } },
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fill(options.precache || PRECACHE, options.lazy || LAZY), sandbox);
  return { calls, stores, state, listeners, bucket };
}

async function fire(worker, type, event) {
  let pending = Promise.resolve();
  event.waitUntil = (promise) => { pending = promise; };
  for (const fn of worker.listeners[type]) fn(event);
  await pending;
}

async function respond(worker, request) {
  let handled = false;
  let promise = null;
  let waited = null;
  const event = {
    request,
    respondWith(value) { handled = true; promise = value; },
    waitUntil(value) { waited = value; },
  };
  for (const fn of worker.listeners.fetch) fn(event);
  return { handled, body: promise ? await promise : null, waited };
}

(async () => {
  const indexUrl = SCOPE + 'index.html';
  const cssUrl = SCOPE + 'final.css';
  const lazyUrl = SCOPE + LAZY[0];

  // 1. Install fetches each entry once and stores the answer.
  const installed = boot();
  await fire(installed, 'install', {});
  assert.equal(installed.state.skipped, 1);
  assert.equal(installed.calls.length, 2);
  for (const [file, integrity] of PRECACHE) {
    const call = installed.calls.find((item) => item.url === SCOPE + file);
    assert.ok(call, file);
    assert.equal(call.options.cache, 'no-cache');
    assert.equal(call.options.integrity, integrity);
    assert.equal(installed.bucket(CACHE).has(SCOPE + file), true);
  }

  // 2. A 404 rejects the install and does not call skipWaiting.
  const missing = boot(new Map([[cssUrl, () => response({ status: 404 })]]));
  await assert.rejects(() => fire(missing, 'install', {}));
  assert.equal(missing.state.skipped, 0);
  assert.equal(missing.bucket(CACHE).has(cssUrl), false);

  // 3. A redirect rejects the install.
  const redirected = boot(new Map([[indexUrl, () => response({ redirected: true })]]));
  await assert.rejects(() => fire(redirected, 'install', {}));
  assert.equal(redirected.state.skipped, 0);
  assert.equal(redirected.bucket(CACHE).has(indexUrl), false);

  // 4. Install skips a file this cache already holds.
  const partial = boot();
  partial.bucket(CACHE).set(indexUrl, response({ marker: 'kept' }));
  await fire(partial, 'install', {});
  assert.equal(partial.calls.some((item) => item.url === indexUrl), false);
  assert.equal(partial.calls.filter((item) => item.url === cssUrl).length, 1);
  assert.equal(partial.bucket(CACHE).get(indexUrl).marker, 'kept');

  // 5. Activate deletes only this scope's older cache.
  const active = boot();
  const otherScope = 'cll-book:/cll/1.3.8/xhtml_no_chunks/:x';
  active.bucket(CACHE);
  active.bucket(CACHE.replace(BUILD, 'old'));
  active.bucket(otherScope);
  active.bucket('other-project-cache');
  await fire(active, 'activate', {});
  assert.deepEqual(active.stores.has(CACHE.replace(BUILD, 'old')), false);
  assert.equal(active.stores.has(CACHE), true);
  assert.equal(active.stores.has(otherScope), true);
  assert.equal(active.stores.has('other-project-cache'), true);
  assert.equal(active.state.claimed, 1);

  function request(url, init) { return new Request(url, init); }

  // 6. These requests are not handled.
  const fetchWorker = boot();
  const ignored = [
    request(cssUrl, { method: 'POST' }),
    request(cssUrl, { method: 'HEAD' }),
    request(cssUrl, { headers: { Range: 'bytes=0-9' } }),
    request('https://cdn.example/mathjax.js'),
    request('https://example.test/cll/1.3.8/xhtml_no_chunks/index.html'),
    request('https://example.test/cll/1.3.8/xhtml_section_chunks'),
    request('https://example.test/cll/1.3.8/xhtml_section_chunks-evil/index.html'),
    request(SCOPE + 'assets/media/vreji/cabna.mp3'),
  ];
  for (const item of ignored) {
    const result = await respond(fetchWorker, item);
    assert.equal(result.handled, false, item.url + ' ' + item.method);
  }
  assert.equal(fetchWorker.calls.length, 0);
  assert.equal(new Headers({ Range: 'bytes=0-9' }).has('range'), true);

  // 7. The scope URL is the cached index page.
  const cached = boot();
  const indexBody = response({ marker: 'index' });
  cached.bucket(CACHE).set(indexUrl, indexBody);
  const folder = await respond(cached, request(SCOPE));
  assert.equal(folder.handled, true);
  assert.equal(folder.body, indexBody);
  assert.equal(cached.calls.length, 0);

  // 8. A query string still hits the cached file.
  const cssBody = response({ marker: 'css' });
  cached.bucket(CACHE).set(cssUrl, cssBody);
  const queried = await respond(cached, request(cssUrl + '?x=1'));
  assert.equal(queried.body, cssBody);
  assert.equal(cached.calls.length, 0);

  // 9. A lazy file is stored on a 200 and left out on a 404.
  // The cache already holds the precache, as it does after install.
  const lazyHit = boot(new Map([[lazyUrl, () => response({ marker: 'font' })]]));
  lazyHit.bucket(CACHE).set(indexUrl, response({ marker: 'index' }));
  const stored = await respond(lazyHit, request(lazyUrl));
  assert.equal(stored.handled, true);
  assert.equal(stored.body.marker, 'font');
  await stored.waited;
  assert.equal(lazyHit.bucket(CACHE).get(lazyUrl).marker, 'font');

  const lazyMiss = boot(new Map([[lazyUrl, () => response({ status: 404, marker: 'gone' })]]));
  lazyMiss.bucket(CACHE).set(indexUrl, response({ marker: 'index' }));
  const missed = await respond(lazyMiss, request(lazyUrl));
  assert.equal(missed.body.status, 404);
  if (missed.waited) await missed.waited;
  assert.equal(lazyMiss.bucket(CACHE).has(lazyUrl), false);

  // 10. A cache error falls through to the network.
  const broken = boot();
  broken.state.openError = new Error('full');
  broken.bucket(CACHE).set(indexUrl, response({ marker: 'stale' }));
  const fell = await respond(broken, request(indexUrl));
  assert.equal(fell.handled, true);
  assert.equal(fell.body.status, 200);
  assert.equal(broken.calls.length, 1);
  assert.equal(broken.calls[0].url, indexUrl);

  // 11. A precached path missing from a live cache is fetched and stored.
  const repaired = boot(new Map([[cssUrl, () => response({ marker: 'fresh' })]]));
  repaired.bucket(CACHE).set(indexUrl, response({ marker: 'index' }));
  const fetched = await respond(repaired, request(cssUrl));
  assert.equal(fetched.body.marker, 'fresh');
  await fetched.waited;
  assert.equal(repaired.bucket(CACHE).get(cssUrl).marker, 'fresh');
  assert.equal(repaired.bucket(CACHE).get(indexUrl).marker, 'index');

  // 12. A deleted cache is not opened again, so an old worker cannot recreate it.
  const retired = boot(new Map([[indexUrl, () => response({ marker: 'network' })]]));
  const fromNetwork = await respond(retired, request(indexUrl));
  assert.equal(fromNetwork.body.marker, 'network');
  assert.deepEqual(retired.state.opens, []);
  if (fromNetwork.waited) await fromNetwork.waited;
  assert.equal(retired.stores.has(CACHE), false);

  // 13. Opening a cache that has no entries deletes it and uses the network.
  const emptied = boot(new Map([[indexUrl, () => response({ marker: 'network' })]]));
  emptied.bucket(CACHE);
  const dropped = await respond(emptied, request(indexUrl));
  assert.equal(dropped.body.marker, 'network');
  assert.deepEqual(emptied.state.opens, [CACHE]);
  if (dropped.waited) await dropped.waited;
  assert.equal(emptied.stores.has(CACHE), false);

  // 14. An integrity failure stops the other downloads and does not call skipWaiting.
  const many = Array.from({ length: 12 }, (_, index) => [
    `file-${index}.html`,
    index === 0 ? 'sha256-bad' : `sha256-${index}`,
  ]);
  let releaseHold;
  const hold = new Promise((resolve) => { releaseHold = resolve; });
  const routes = new Map(many.map(([file, integrity]) => {
    const url = SCOPE + file;
    if (integrity === 'sha256-bad') {
      return [url, () => Promise.reject(new TypeError('integrity mismatch'))];
    }
    return [url, () => hold.then(() => response({ marker: file }))];
  }));
  const mismatch = boot(routes, { precache: many, lazy: [] });
  await assert.rejects(() => fire(mismatch, 'install', {}), /integrity mismatch/);
  assert.equal(mismatch.state.skipped, 0);
  const requested = mismatch.calls.map((item) => item.url);
  assert.equal(requested.includes(SCOPE + 'file-0.html'), true);
  assert.equal(requested.includes(SCOPE + 'file-7.html'), true);
  assert.equal(requested.includes(SCOPE + 'file-8.html'), false);
  releaseHold();
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(mismatch.calls.some((item) => item.url === SCOPE + 'file-8.html'), false);
  assert.equal(mismatch.bucket(CACHE).size, 0);

  console.log('Offline worker tests passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
