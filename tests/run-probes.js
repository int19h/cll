#!/usr/bin/env node
// Run magic-word probes against ilmentufa camxes-std (and optionally jbotci).
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ILM = process.env.ILMENTUFA_DIR;
if (!ILM) { console.error('set ILMENTUFA_DIR'); process.exit(2); }
const JBOTCI = process.env.JBOTCI_BIN || null;

const tsv = fs.readFileSync(path.join(__dirname, 'fixtures/magic-word-probes.tsv'), 'utf8');
let fail = 0, ran = 0;
for (const line of tsv.split('\n')) {
  if (!line.trim() || line.startsWith('#')) continue;
  const [id, input, expIlm, expJbo, note] = line.split('\t');
  let gotIlm;
  try {
    const out = execFileSync('node', [path.join(ILM, 'run_camxes.js'), input],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    gotIlm = /Expected|error/i.test(out) ? 'R' : 'A';
  } catch (e) { gotIlm = 'R'; }
  ran++;
  const ok = gotIlm === expIlm;
  if (!ok) { fail++; console.log(`MISMATCH ${id}: ilmentufa expected ${expIlm}, got ${gotIlm}  [${input}]  (${note})`); }
  if (JBOTCI && expJbo !== '-') {
    let gotJbo;
    try { execFileSync(JBOTCI, [input], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); gotJbo = 'A'; }
    catch (e) { gotJbo = 'R'; }
    if (gotJbo !== expJbo) console.log(`INFO ${id}: jbotci expected ${expJbo}, got ${gotJbo}  [${input}]`);
  }
}
console.log(`${ran} probes, ${fail} ilmentufa mismatches`);
process.exit(fail ? 1 : 0);
