#!/usr/bin/env node
// Parse every extracted example with ilmentufa camxes-std; report failures.
// Report-only: exits 0 always; CI surfaces the report as an artifact.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const ILM = process.env.ILMENTUFA_DIR;
if (!ILM) { console.error('set ILMENTUFA_DIR'); process.exit(2); }
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n');
let ok = 0, bad = 0;
for (const row of rows) {
  const [file, id, text] = row.split('\t');
  if (!text) continue;
  let good;
  try {
    const out = execFileSync('node', [path.join(ILM, 'run_camxes.js'), text],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 20000 });
    good = !/Expected|error/i.test(out);
  } catch (e) { good = false; }
  if (good) ok++;
  else { bad++; console.log(`FAIL ${file} ${id}: ${text.slice(0, 90)}`); }
}
console.log(`\n${ok} parsed, ${bad} failed (report-only; intentional-bad-example allowlist TBD)`);
