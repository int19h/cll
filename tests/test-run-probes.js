#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const source = fs.readFileSync(path.join(__dirname, 'run-probes.js'), 'utf8');
const row = 'probe\tmi klama\tA\t-\ttest\n';
function run(result, fixture = row) {
  let exit;
  const messages = [];
  const stopped = {};
  const context = {
    __dirname, console: { log: s => messages.push(s), error: s => messages.push(s) },
    process: { env: { ILMENTUFA_DIR: '/fake' }, exit: code => { exit = code; throw stopped; } },
    require: name => {
      if (name === 'fs') return { existsSync: () => true, readFileSync: () => fixture };
      if (name === 'child_process') return {
        spawnSync: command => command === 'git'
          ? { status: 0, stdout: '778ea138f7d150121ca722db7536ce3b123943ac\n' }
          : result
      };
      return require(name);
    }
  };
  try { vm.runInNewContext(source, context); } catch (e) { if (e !== stopped) throw e; }
  return { exit, messages: messages.join('\n') };
}

const crash = spawnSync(process.execPath, ['-e', "throw new Error('injected parser crash')"], { encoding: 'utf8' });
for (const [name, result] of [
  ['real crash', crash],
  ['signal', { status: null, signal: 'SIGTERM', stdout: 'partial tree' }],
  ['exception with exit zero', { status: 0, stdout: 'TypeError: missing engine\n    at load (runner.js:1:1)' }],
  ['stack frame', { status: 0, stderr: '    at load (runner.js:1:1)' }],
  ['empty output', { status: 0, stdout: ' \n' }],
  ['invocation error', { error: new Error('ENOENT') }]
]) {
  assert.equal(run(result).exit, 2, name);
}
const accepted = { status: 0, stdout: '(mi klama)' };
assert.equal(run(accepted).exit, 0);
assert.equal(run({ status: 0, stdout: '@0 "mi": Expected something' }, row.replace('\tA\t', '\tR\t')).exit, 0);
assert.equal(run(accepted, row.replace('\tA\t', '\tR\t')).exit, 1);
assert.equal(run(accepted, '# comment only\n\n').exit, 2, 'empty fixture');
assert.equal(run(accepted, 'malformed\n').exit, 2);
console.log('Parser probe runner tests passed');
