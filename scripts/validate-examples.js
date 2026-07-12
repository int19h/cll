#!/usr/bin/env node
// Parse every extracted example with ilmentufa camxes-std; report failures.
// Genuine parse rejections are report-only (exit 0 with a report);
// configuration/invocation problems exit 2 (same contract as tests/run-probes.js).
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// camxes-std reports syntax errors as '@<offset> "…": Expected …' lines.
const CAMXES_ERROR = /(^|\n)@\d+\s/;

function die(msg) { console.error(`CONFIG ERROR: ${msg}`); process.exit(2); }

const ILM = process.env.ILMENTUFA_DIR;
if (!ILM) die('set ILMENTUFA_DIR');
const runner = path.join(ILM, 'run_camxes.js');
if (!fs.existsSync(runner)) die(`${runner} not found`);

// The runner catches engine-load failures (e.g. missing camxes.js), prints
// the exception to STDOUT, and exits 0 — indistinguishable from a parse by
// exit status alone. Smoke-test the engine positively before trusting it.
const smoke = spawnSync('node', ['--stack-size=16384', runner, 'mi klama'],
                        { encoding: 'utf8', timeout: 30000 });
if (smoke.error || smoke.signal || smoke.status !== 0
    || !(smoke.stdout || '').includes('(mi klama)')) {
  die(`engine smoke test failed: status=${smoke.status} signal=${smoke.signal} `
      + `output=${((smoke.stdout || '') + (smoke.stderr || '')).slice(0, 200)}`);
}

// Exception-shaped output (an Error line or stack frames) is never a parse
// outcome, whatever the exit status.
const EXCEPTION_SHAPE = /^\s*\w*Error\b|^\s+at /m;

const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n');
let ok = 0, bad = 0;
for (const row of rows) {
  const [file, id, text] = row.split('\t');
  if (!text) continue;
  // --stack-size: the chrestomathy rows are whole continuous texts; the
  // camxes PEG recursion exhausts the default V8 stack on the longest ones.
  const res = spawnSync('node', ['--stack-size=16384', runner, text],
                        { encoding: 'utf8', timeout: 30000 });
  if (res.error) die(`failed to invoke ${runner}: ${res.error.message}`);
  // A crashed or killed parser is an infrastructure error, never a parse
  // outcome (camxes reports genuine rejections on stdout with exit 0).
  if (res.signal) die(`${runner} killed by ${res.signal} for: ${text.slice(0, 90)}`);
  if (res.status !== 0) die(`${runner} exited ${res.status} for: ${text.slice(0, 90)}\n${(res.stderr || '').slice(0, 300)}`);
  const out = (res.stdout || '') + (res.stderr || '');
  if (!out.trim()) die(`empty output from ${runner} for: ${text}`);
  if (EXCEPTION_SHAPE.test(out)) die(`exception-shaped output from ${runner} for: ${text.slice(0, 90)}\n${out.slice(0, 300)}`);
  if (CAMXES_ERROR.test(out)) { bad++; console.log(`FAIL ${file} ${id}: ${text.slice(0, 90)}`); }
  else ok++;
}
console.log(`\n${ok} parsed, ${bad} failed (report-only; intentional-bad-example allowlist TBD)`);
