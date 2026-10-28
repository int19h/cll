#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
function target(className, parentNode = null) {
  return { parentNode, getAttribute: name => name === 'class' ? className : null };
}
function link(href) { return { getAttribute: name => name === 'href' ? href : null }; }
function entry(label, hrefs) {
  return {
    nodeName: 'DT', textContent: label, html: null,
    childNodes: [{ nodeName: '#text', nodeValue: label }],
    getElementsByTagName: () => hrefs.map(link),
    set innerHTML(html) { this.html = html; },
    get nextElementSibling() {
      const siblings = this.parentNode.children;
      return siblings[siblings.indexOf(this) + 1] || null;
    }
  };
}
function index(entries) {
  const list = { children: entries, removeChild: child => list.children.splice(list.children.indexOf(child), 1) };
  for (const row of entries) row.parentNode = list;
  return { list, getElementsByTagName: () => list.children.filter(row => row.nodeName === 'DT') };
}
const hidden = target('extra\tdisplay-none\nother');
const targets = { hidden: target('', hidden), hidden2: target('display-none'), visible: target(''), zero: target('not-display-none') };
const mixed = entry('mixed, ', ['#hidden', '#visible', '#hidden2']);
const onlyHidden = entry('hidden, ', ['#hidden']);
const nextHidden = entry('next hidden, ', ['#hidden2']);
const missing = entry('missing, ', ['#missing']);
const zero = entry('word0, ', ['#zero']);
const first = index([mixed, onlyHidden, nextHidden, missing, zero]);
const secondVisible = entry('second, ', ['#visible']);
const second = index([secondVisible]);
const context = {
  Prince: { addScriptFunc() {} }, window: { addEventListener() {} },
  document: { getElementById: id => targets[id] || null, getElementsByClassName: () => [first, second] }
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(__dirname, '../scripts/prince_shave_index.js'), 'utf8'), context);
assert.equal(context.hidden_index_target(link('#hidden')), true);
assert.equal(context.hidden_index_target(link('#hidden2')), true);
assert.equal(context.hidden_index_target(link('#visible')), false);
assert.equal(context.hidden_index_target(link('#missing')), false, 'unknown targets reach the final audit');
assert.equal(context.hidden_index_target(link('other.html#hidden')), false);
context.prep_index();
assert.deepEqual(first.list.children, [mixed, missing, zero]);
assert.ok(mixed.html.includes('url(#visible)'));
assert.ok(!mixed.html.includes('#hidden'));
assert.ok(mixed.html.includes('class="index-pages"'));
assert.ok(missing.html.includes('#missing'));
assert.ok(zero.html.includes('#zero'));
assert.ok(secondVisible.html.includes('#visible'));

const heading = entry('heading, ', ['#hidden']);
const details = { nodeName: 'DD', textContent: 'visible subentry' };
const nested = index([heading, details]);
context.document.getElementsByClassName = () => [nested];
context.prep_index();
assert.equal(heading.textContent, 'heading');
assert.equal(nested.list.children.length, 2);
const emptyHeading = entry('empty, ', ['#hidden']);
const empty = index([emptyHeading, { nodeName: 'DD', textContent: ' \n' }]);
context.document.getElementsByClassName = () => [empty];
context.prep_index();
assert.equal(empty.list.children.length, 0);
console.log('Prince index preparation tests passed');
