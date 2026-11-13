#!/usr/bin/env node
// Registration for the book service worker.
// Run: node tests/test-offline-register.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SOURCE = fs.readFileSync(path.join(__dirname, '../assets/scripts/offline.js'), 'utf8');
const BOOK = 'https://example.test/cll/1.3.8/xhtml_section_chunks/';
const SCRIPT = BOOK + 'assets/scripts/offline.js';
const unhandled = [];
process.on('unhandledRejection', (error) => unhandled.push(error));

function boot({ href, src = SCRIPT, protocol = 'https:', secure = true, readyState = 'loading',
  serviceWorker, saveData = false, connection = true }) {
  const calls = [];
  const attrs = {};
  const listeners = {};
  let ready = Promise.resolve();
  const navigator = {};
  if (serviceWorker !== null) {
    navigator.serviceWorker = serviceWorker || {
      register(url) { calls.push(url); return Promise.resolve(); },
      get ready() { return ready; },
    };
  }
  if (connection) navigator.connection = { saveData };
  const sandbox = {
    URL, Promise,
    location: { protocol, href },
    window: {
      isSecureContext: secure,
      addEventListener(name, fn) { listeners[name] = fn; },
    },
    navigator,
    document: {
      readyState,
      currentScript: src ? { src } : null,
      documentElement: { setAttribute(name, value) { attrs[name] = value; } },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(SOURCE, sandbox);
  return { calls, attrs, listeners };
}

async function settle() {
  await new Promise((resolve) => setImmediate(resolve));
}

(async () => {
  // 1. A page in the book folder registers once, after load.
  const page = boot({ href: BOOK + 'section-gismu.html', saveData: false });
  assert.deepEqual(page.calls, []);
  assert.equal(typeof page.listeners.load, 'function');
  page.listeners.load();
  await settle();
  assert.deepEqual(page.calls, [BOOK + 'sw.js']);
  assert.equal(page.attrs['data-offline'], 'ready');

  const loaded = boot({ href: BOOK + 'index.html', readyState: 'complete' });
  await settle();
  assert.deepEqual(loaded.calls, [BOOK + 'sw.js']);
  assert.equal(loaded.listeners.load, undefined);
  assert.equal(loaded.attrs['data-offline'], 'ready');

  // 2. A comparison page loads the script from the book folder and does not register.
  const diffSrc = 'https://example.test/cll/1.3.8/xhtml_no_chunks/assets/scripts/offline.js';
  const diff = boot({
    href: 'https://example.test/cll/1.3.8/diff_from_previous/difference.html',
    src: diffSrc,
  });
  if (diff.listeners.load) diff.listeners.load();
  await settle();
  assert.deepEqual(diff.calls, []);

  // 3. A file: page does not register. Secure context is set so the protocol check is the one that returns.
  const filePage = boot({
    href: 'file:///tmp/book/index.html',
    src: 'file:///tmp/book/assets/scripts/offline.js',
    protocol: 'file:',
    secure: true,
  });
  if (filePage.listeners.load) filePage.listeners.load();
  await settle();
  assert.deepEqual(filePage.calls, []);

  // 4. A browser with no service worker does not throw.
  const oldBrowser = boot({ href: BOOK + 'index.html', serviceWorker: null });
  assert.deepEqual(oldBrowser.calls, []);
  assert.equal(oldBrowser.listeners.load, undefined);

  // 5. Data saver skips registration.
  const saver = boot({ href: BOOK + 'index.html', saveData: true });
  if (saver.listeners.load) saver.listeners.load();
  await settle();
  assert.deepEqual(saver.calls, []);

  // 6. A rejected register call is handled, and the attribute stays unset.
  const before = unhandled.length;
  const seen = [];
  const failed = boot({
    href: BOOK + 'index.html',
    readyState: 'complete',
    serviceWorker: {
      register(url) { seen.push(url); return Promise.reject(new Error('nope')); },
      ready: Promise.resolve(),
    },
  });
  await settle();
  assert.deepEqual(seen, [BOOK + 'sw.js']);
  assert.equal(failed.attrs['data-offline'], undefined);
  assert.equal(unhandled.length, before);

  // 7. The attribute is set only after ready resolves. Case 1 already covers a resolved ready.
  let finishReady;
  const waiting = boot({
    href: BOOK + 'index.html',
    readyState: 'complete',
    serviceWorker: {
      register() { return Promise.resolve(); },
      ready: new Promise((resolve) => { finishReady = resolve; }),
    },
  });
  await settle();
  assert.equal(waiting.attrs['data-offline'], undefined);
  finishReady();
  await settle();
  assert.equal(waiting.attrs['data-offline'], 'ready');

  assert.equal(unhandled.length, 0);
  console.log('Offline registration tests passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
