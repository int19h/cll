#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../scripts/prince_check_index.js'), 'utf8');
function run(fragments, priorFailure = false) {
  let complete;
  const errors = [];
  const context = {
    Prince: { failStatus: priorFailure, addEventListener: (name, fn) => { assert.equal(name, 'complete'); complete = fn; } },
    Log: { error: message => errors.push(message) },
    document: { querySelectorAll: () => fragments.map(parts => ({
      parentNode: { textContent: 'word0, pages' },
      getPrinceBoxes: () => parts.map(text => ({ type: 'SPAN', children: [{ type: 'TEXT', text }] }))
    })) }
  };
  vm.runInNewContext(source, context);
  assert.equal(context.Prince.trackBoxes, true);
  complete();
  return { failed: context.Prince.failStatus, errors };
}
for (const parts of [['0'], ['1, 0'], ['1-', '0'], ['0, 20'], [], ['  '], ['unresolved']]) {
  const result = run([parts]);
  assert.equal(result.failed, true, JSON.stringify(parts));
  assert.equal(result.errors.length, 1);
  assert.match(result.errors[0], /word0/);
}
assert.deepEqual(run([['1'], ['10, 20'], ['101-102, ', '200'], ['i, ii']]), { failed: false, errors: [] });
assert.equal(run([['1']], true).failed, true, 'retain another audit failure');
assert.equal(run([]).failed, false);
console.log('Prince index guard tests passed');
