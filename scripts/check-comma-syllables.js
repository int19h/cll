#!/usr/bin/env node
// Reproduce the reviewed comma boundaries with the CI-pinned camxes-std.
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const directory = process.env.ILMENTUFA_DIR;
if (!directory) throw new Error('Set ILMENTUFA_DIR to the pinned ilmentufa checkout.');
const camxes = require(path.resolve(directory, 'camxes.js'));
const reviewed = JSON.parse(fs.readFileSync(path.join(__dirname, 'reviewed-comma-words.json'), 'utf8'));
function letters(node) {
  if (typeof node === 'string') return node;
  if (!Array.isArray(node)) return '';
  return (typeof node[0] === 'string' ? node.slice(1) : node).map(letters).join('');
}
function syllables(node) {
  if (!Array.isArray(node)) return [];
  if (['any_syllable', 'syllable', 'final_syllable'].includes(node[0])) {
    return [letters(node).replaceAll(',', '')];
  }
  return node.flatMap(syllables);
}
for (const [word, expected] of Object.entries(reviewed.words)) {
  const plain = word.replaceAll(',', '');
  assert.deepEqual(syllables(camxes.parse(`.${word}.`)), expected, word);
  assert.deepEqual(syllables(camxes.parse(`.${plain}.`)), expected, plain);
  assert.equal(expected.join(''), plain, word);
  const boundaries = expected.slice(0, -1).map((_, i) => expected.slice(0, i + 1).join('').length);
  let position = 0;
  for (const letter of word) {
    if (letter === ',') assert(boundaries.includes(position), `${word}: comma inside a syllable`);
    else position++;
  }
}
console.log(`${Object.keys(reviewed.words).length} reviewed comma words: syllables and boundaries match`);
