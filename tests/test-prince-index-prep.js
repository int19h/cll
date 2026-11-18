#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
function target(className, parentNode = null) {
  return { parentNode, getAttribute: name => name === 'class' ? className : null };
}
function link(href) { return { getAttribute: name => name === 'href' ? href : null }; }
// Prince 16.2 has no outerHTML, so this double has none either: a script
// that serializes a node gets "undefined", as Prince prints it.
function span(className, text) {
  return { nodeName: 'SPAN', getAttribute: name => name === 'class' ? className : null, text };
}
function entry(label, hrefs, spans = []) {
  return {
    nodeName: 'DT', html: null, text: label, appended: [],
    childNodes: [{ nodeName: '#text', nodeValue: label }],
    getElementsByTagName: tag => tag === 'a' ? hrefs.map(link) : tag === 'span' ? spans : [],
    get textContent() { return this.text; },
    // Replacing the content drops the old child nodes, spans included.
    set textContent(text) { this.text = text; this.html = null; this.appended = []; },
    appendChild(node) { this.appended.push(node); return node; },
    set innerHTML(html) { this.html = html; this.text = null; this.appended = []; },
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
  document: {
    getElementById: id => targets[id] || null, getElementsByClassName: () => [first, second],
    createTextNode: text => ({ nodeName: '#text', nodeValue: text })
  }
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

// A see entry, as DocBook XSL writes it: a dt with no page links and an
// empty dd. It is a cross-reference, so it must survive (issue #9).
const see = entry('masses ', [], [span('index-see', '(see groups)')]);
const seeAlso = entry('', [], [span('index-seealso', '(see also groups)')]);
const linkless = entry('nothing ', []);
const crossRefs = index([see, { nodeName: 'DD', textContent: '' }, seeAlso, { nodeName: 'DD', textContent: '' }, linkless, { nodeName: 'DD', textContent: '' }]);
context.document.getElementsByClassName = () => [crossRefs];
context.prep_index();
assert.deepEqual(crossRefs.list.children.filter(row => row.nodeName === 'DT'), [see, seeAlso], 'see entries stay, an empty entry goes');
assert.equal(crossRefs.list.children.length, 4);
assert.equal(see.html, null, 'a see entry without page links is left as written');
const pagesAndSee = entry('groups: ', ['#visible'], [span('index-see', '(see sets)')]);
const hiddenAndSee = entry('hidden see: ', ['#hidden'], [span('index-see', '(see visible)')]);
context.document.getElementsByClassName = () => [index([pagesAndSee, hiddenAndSee])];
context.prep_index();
// What the entry shows after the script: its HTML or text, then the
// nodes appended to it.
const shown = row => (row.html ?? row.text) + row.appended.map(node => node.nodeValue ?? `<${node.text}>`).join('');
assert.ok(pagesAndSee.html.includes('url(#visible)'));
assert.ok(pagesAndSee.html.endsWith(')"></span>'), `nothing serialized after the pages (Prince prints "undefined"): ${pagesAndSee.html}`);
assert.deepEqual(pagesAndSee.appended[1], pagesAndSee.getElementsByTagName('span')[0], 'the see span itself goes back into the entry');
assert.ok(shown(pagesAndSee).endsWith(')"></span> <(see sets)>'), 'page collapsing keeps the see text');
assert.equal(shown(hiddenAndSee), 'hidden see <(see visible)>', 'hidden pages go, the see text stays');
console.log('Prince index preparation tests passed');
