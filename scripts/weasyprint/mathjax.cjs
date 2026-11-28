// Read MathML strings as JSON on stdin and emit static CommonHTML and CSS.
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');

const dependencies = process.env.CLL_MATHJAX_DIR;
if (!dependencies) throw new Error('Set CLL_MATHJAX_DIR to the pinned MathJax installation.');
const load = createRequire(path.join(path.resolve(dependencies), 'package.json'));
const {mathjax} = load('@mathjax/src/js/mathjax.js');
const {MathML} = load('@mathjax/src/js/input/mathml.js');
const {CHTML} = load('@mathjax/src/js/output/chtml.js');
const {liteAdaptor} = load('@mathjax/src/js/adaptors/liteAdaptor.js');
const {RegisterHTMLHandler} = load('@mathjax/src/js/handlers/html.js');
const {MathJaxNewcmFont} = load('@mathjax/mathjax-newcm-font/js/chtml.js');
load('@mathjax/src/js/util/asyncLoad/node.js');
const fontManifest = '@mathjax/mathjax-newcm-font/package.json';
const fontPin = require('./package.json').dependencies['@mathjax/mathjax-newcm-font'];
const fontVersion = load(fontManifest).version;
if (fontVersion !== fontPin) {
  throw new Error(`WeasyPrint needs MathJax New Computer Modern ${fontPin}. Found ${fontVersion} in ${dependencies}.`);
}
const fonts = path.join(path.dirname(load.resolve(fontManifest)), 'chtml/woff2');
if (!fs.statSync(fonts, {throwIfNoEntry: false})?.isDirectory()) {
  throw new Error(`MathJax font directory is missing: ${fonts}`);
}

async function main() {
  const inputs = JSON.parse(fs.readFileSync(0, 'utf8'));
  const adaptor = liteAdaptor({fontSize: 12});
  RegisterHTMLHandler(adaptor);
  const output = new CHTML({
    font: new MathJaxNewcmFont(),
    fontURL: './mathjax-fonts',
    // Keep a predictable 9pt math size; do not guess the surrounding x-height.
    matchFontHeight: false,
  });
  const document = mathjax.document('', {
    InputJax: new MathML(), OutputJax: output,
  });
  const expressions = [];
  for (const input of inputs) {
    const node = await document.convertPromise(input, {em: 12, ex: 6, containerWidth: 500});
    const result = adaptor.outerHTML(node);
    if (result.includes('<mjx-merror')) {
      throw new Error(`MathJax rejected an expression: ${input}`);
    }
    expressions.push(result);
  }
  process.stdout.write(JSON.stringify({
    expressions,
    css: adaptor.cssText(output.styleSheet(document)),
    fonts,
    version: mathjax.version,
  }));
}
if (require.main === module) {
  main().catch(error => { console.error(error); process.exitCode = 1; });
}
