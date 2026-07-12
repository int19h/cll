#!/usr/bin/env node
// Run magic-word probes against ilmentufa camxes-std (and optionally jbotci).
//
// Exit codes: 0 = all ilmentufa expectations match; 1 = expectation mismatch;
// 2 = configuration/invocation failure (bad ILMENTUFA_DIR, wrong pin, empty
// parser output, malformed fixture). jbotci rows never affect the exit code.
const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const PINNED_ILMENTUFA = '778ea138f7d150121ca722db7536ce3b123943ac';
// camxes-std reports syntax errors as '@<offset> "…": Expected …' lines.
const CAMXES_ERROR = /(^|\n)@\d+\s/;

function die(msg) { console.error(`CONFIG ERROR: ${msg}`); process.exit(2); }

const ILM = process.env.ILMENTUFA_DIR;
if (!ILM) die('set ILMENTUFA_DIR to an ilmentufa checkout');
const runner = path.join(ILM, 'run_camxes.js');
if (!fs.existsSync(runner)) die(`${runner} not found`);
const rev = spawnSync('git', ['-C', ILM, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
const head = (rev.stdout || '').trim();
if (head !== PINNED_ILMENTUFA) {
  if (process.env.ALLOW_UNPINNED_ILMENTUFA) {
    console.error(`WARNING: ilmentufa at ${head || 'unknown'}, expected ${PINNED_ILMENTUFA}; results may not match fixtures`);
  } else {
    die(`ilmentufa is at ${head || 'unknown revision'}, fixtures are pinned to ${PINNED_ILMENTUFA} (set ALLOW_UNPINNED_ILMENTUFA=1 to override)`);
  }
}
const JBOTCI = process.env.JBOTCI_BIN || null; // invoked as: $JBOTCI_BIN gentufa <text>

function classifyIlmentufa(input) {
  const res = spawnSync('node', [runner, input], { encoding: 'utf8', timeout: 30000 });
  if (res.error) die(`failed to invoke ${runner}: ${res.error.message}`);
  const out = (res.stdout || '') + (res.stderr || '');
  if (!out.trim()) die(`empty output from ${runner} for input: ${input}`);
  return CAMXES_ERROR.test(out) ? 'R' : 'A';
}

function classifyJbotci(input) {
  const res = spawnSync(JBOTCI, ['gentufa', input], { encoding: 'utf8', timeout: 30000 });
  if (res.error) { console.error(`jbotci invocation failed: ${res.error.message}`); return null; }
  const out = (res.stdout || '') + (res.stderr || '');
  return (res.status !== 0 || /error\[/.test(out)) ? 'R' : 'A';
}

const tsvPath = path.join(__dirname, 'fixtures/magic-word-probes.tsv');
const lines = fs.readFileSync(tsvPath, 'utf8').split('\n');
let fail = 0, ran = 0;
lines.forEach((line, i) => {
  if (!line.trim() || line.startsWith('#')) return;
  const fields = line.split('\t');
  if (fields.length !== 5) die(`${tsvPath}:${i + 1}: expected 5 tab-separated fields, got ${fields.length}`);
  const [id, input, expIlm, expJbo, note] = fields;
  if (!/^[AR]$/.test(expIlm)) die(`${tsvPath}:${i + 1}: bad ilmentufa expectation ${JSON.stringify(expIlm)}`);
  if (!/^[AR-]$/.test(expJbo)) die(`${tsvPath}:${i + 1}: bad jbotci expectation ${JSON.stringify(expJbo)}`);
  const gotIlm = classifyIlmentufa(input);
  ran++;
  if (gotIlm !== expIlm) {
    fail++;
    console.log(`MISMATCH ${id}: ilmentufa expected ${expIlm}, got ${gotIlm}  [${input}]  (${note})`);
  }
  if (JBOTCI && expJbo !== '-') {
    const gotJbo = classifyJbotci(input);
    if (gotJbo && gotJbo !== expJbo) console.log(`INFO ${id}: jbotci expected ${expJbo}, got ${gotJbo}  [${input}]`);
  }
});
console.log(`${ran} probes, ${fail} ilmentufa mismatches`);
process.exit(fail ? 1 : 0);
