#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element extends EventTarget {
  constructor(text = '') { super(); this.innerText = text; this.children = []; this.parentNode = null; this.html = ''; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  set innerHTML(value) { for (const child of this.children) child.parentNode = null; this.children = []; this.html = value; }
  get innerHTML() { return this.html; }
  insertAdjacentHTML(position, value) { this.html += value; }
  remove() { this.parentNode.children = this.parentNode.children.filter(child => child !== this); this.parentNode = null; }
}
function setup(fetchImpl = async () => ({ status: 200 })) {
  const audios = [], timers = new Map(), requests = [];
  let nextTimer = 0, ready;
  class Audio extends Element {
    constructor(src) { super(); this.src = src; this.plays = 0; audios.push(this); }
    play() { this.plays++; }
  }
  const box = new Element();
  const words = ['badri', 'bajra'].map(text => box.appendChild(new Element()).appendChild(new Element(text)));
  const exampleParent = new Element();
  const example = exampleParent.appendChild(new Element('Example\u00a01.\u00a0'));
  const termParent = new Element();
  const term = termParent.appendChild(new Element('klama'));
  const context = {
    encodeURIComponent, Audio, AbortController,
    setTimeout: callback => { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout: id => timers.delete(id),
    fetch: (url, options) => { requests.push(url); return fetchImpl(url, options); },
    document: {
      location: { href: 'http://localhost/chapter.html' },
      createElement: () => new Element(),
      addEventListener: (name, callback) => { ready = callback; },
      querySelectorAll: selector => selector === 'em.glossterm' ? words
        : selector === '.example > .title > strong' ? [example] : [term]
    }
  };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../assets/scripts/sance-next.js'), 'utf8'), context);
  return { context, audios, timers, requests, box, words, example, term, ready: () => ready() };
}
const flush = () => new Promise(setImmediate);
async function settles(promise) {
  await Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error('audio operation did not settle')), 100))]);
}
(async () => {
  // A successful HEAD followed by a media error must settle.
  const failed = setup();
  const operation = failed.context.processNode('/bad.mp3', failed.words[0], 'badri', () => assert.fail('failed media gets no control'));
  await flush();
  failed.audios[0].dispatchEvent(new Event('error'));
  await settles(operation);
  assert.equal(failed.timers.size, 0);

  // Preserve both links and bind each button to its own Audio object.
  const shared = setup();
  shared.context.funcContentGloss(shared.words[0], new shared.context.Audio(), 'badri');
  shared.context.funcContentGloss(shared.words[1], new shared.context.Audio(), 'bajra');
  assert.equal(shared.box.children.length, 6);
  assert.ok(shared.words.every(word => word.parentNode.parentNode === shared.box));
  const buttons = shared.box.children.filter(child => child.className === 'tutci');
  assert.equal(buttons.length, 2);
  buttons[1].dispatchEvent(new Event('click'));
  assert.equal(shared.audios[0].plays, 0);
  assert.equal(shared.audios[1].plays, 1);

  // Timeout includes a HEAD request that never responds, and late success is inert.
  let respond;
  const timeout = setup(() => new Promise(resolve => { respond = resolve; }));
  const timed = timeout.context.processNode('/slow.mp3', timeout.words[0], 'slow', () => assert.fail('late result'));
  for (const callback of [...timeout.timers.values()]) callback();
  await settles(timed);
  respond({ status: 200 });
  await flush();
  assert.equal(timeout.audios.length, 0);

  const stalled = setup();
  const waiting = stalled.context.processNode('/stall.mp3', stalled.words[0], 'stall', () => assert.fail('late media event'));
  await flush();
  for (const callback of [...stalled.timers.values()]) callback();
  await settles(waiting);
  stalled.audios[0].dispatchEvent(new Event('canplaythrough'));

  for (const fetchImpl of [async () => ({ status: 404 }), async () => { throw new Error('network'); }]) {
    const missing = setup(fetchImpl);
    await settles(missing.context.processNode('/missing', missing.words[0], 'missing', () => assert.fail('missing media')));
  }

  // The complete loader starts unrelated files and reaches guibutton controls.
  const complete = setup();
  const loading = complete.ready();
  await flush();
  assert.equal(complete.requests.length, 3);
  complete.audios[0].dispatchEvent(new Event('error'));
  complete.audios[1].dispatchEvent(new Event('canplaythrough'));
  complete.audios[1].dispatchEvent(new Event('canplaythrough'));
  complete.audios[2].dispatchEvent(new Event('canplaythrough'));
  await settles(loading);
  assert.equal(complete.term.parentNode, null);
  assert.equal(complete.box.children.filter(child => child.className === 'tutci').length, 1);
  assert.equal(complete.example.parentNode.children.length, 3);
  assert.equal(complete.timers.size, 0);
  console.log('Audio loading tests passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
