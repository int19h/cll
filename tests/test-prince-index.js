#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = { Prince: { addScriptFunc() {} }, window: { addEventListener() {} } };
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(__dirname, '../scripts/prince_shave_index.js'), 'utf8'), context);
for (const [pages, expected] of [
  [[], ''], [[0], ''], [[0, 0, 1], '1'], [[0, 2, 3], '2-3'], [['0', '1'], '1'], [[1], '1'], [[1, 1, 1], '1'], [[1, 2], '1-2'],
  [[1, 2, 3, 3, 3, 7, 7, 7], '1-3, 7'],
  [[2, 3, 4], '2-4'], [[6, 6, 7, 8, 11, 16, 17, 20], '6-8, 11, 16-17, 20'],
  [['1', '2', '3', '7'], '1-3, 7'], [[1, 3, 5], '1, 3, 5']
]) assert.equal(context.index_term(...pages), expected, JSON.stringify(pages));
console.log('Prince index formatter: 13 cases passed');
