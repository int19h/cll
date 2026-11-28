// Convert a batch of glossary TeX fragments to inline MathML.
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');

const dependencies = process.env.CLL_MATHJAX_DIR;
if (!dependencies) throw new Error('Set CLL_MATHJAX_DIR to the pinned MathJax installation.');
const load = createRequire(path.join(path.resolve(dependencies), 'package.json'));
const {mathjax} = load('@mathjax/src/js/mathjax.js');
const pinnedVersion = require('./weasyprint/package.json').dependencies['@mathjax/src'];
if (mathjax.version !== pinnedVersion) {
  throw new Error(`Glossary math needs MathJax ${pinnedVersion}. Found ${mathjax.version} in ${dependencies}.`);
}
const {TeX} = load('@mathjax/src/js/input/tex.js');
const {STATE} = load('@mathjax/src/js/core/MathItem.js');
const {SerializedMmlVisitor} = load('@mathjax/src/js/core/MmlTree/SerializedMmlVisitor.js');
const {liteAdaptor} = load('@mathjax/src/js/adaptors/liteAdaptor.js');
const {RegisterHTMLHandler} = load('@mathjax/src/js/handlers/html.js');
load('@mathjax/src/js/input/tex/ams/AmsConfiguration.js');

class DocBookMathML extends SerializedMmlVisitor {
  getAttributeList(node) {
    const attributes = super.getAttributeList(node);
    for (const name of Object.keys(attributes)) {
      // Strip MathJax's private attributes to satisfy the DocBook DTD.
      if (name.startsWith('data-mjx-') || name.startsWith('data-latex')) delete attributes[name];
    }
    return attributes;
  }
}

RegisterHTMLHandler(liteAdaptor());
const document = mathjax.document('', {
  InputJax: new TeX({
    packages: ['base', 'ams'],
    formatError: (_jax, error) => { throw error; },
  }),
});
const visitor = new DocBookMathML();

function checkMath(node, adjacent = '', visible = true) {
  if (node.isKind('merror') || node.attributes?.get('data-mjx-error')) {
    throw new Error('MathJax produced an error node');
  }
  if (node.attributes?.get('class') === 'MathJax_ref' && node.attributes.get('href') === '#') {
    throw new Error('MathJax could not resolve an equation reference');
  }
  if (node.isKind('mspace')) return '';
  visible = visible && !node.isKind('mphantom');
  if (node.isToken) {
    if (!visible) return '';
    const text = adjacent + node.getText();
    if (text.includes('???')) throw new Error('MathJax produced a question-mark placeholder');
    return text.slice(-2);
  }

  // Only row wrappers preserve adjacency. Layout elements break the outer
  // run, and each of their operands starts a separate run.
  if (visible && ['math', 'mrow', 'inferredMrow', 'mstyle', 'TeXAtom'].includes(node.kind)) {
    return node.childNodes.reduce((run, child) => checkMath(child, run), adjacent);
  }
  for (const child of node.childNodes) checkMath(child, '', visible);
  return '';
}

function toMathML(tex) {
  const node = document.convert(tex, {display: false, end: STATE.COMPILED});
  checkMath(node);
  return visitor.visitTree(node);
}

if (require.main === module) {
  try {
    const inputs = JSON.parse(fs.readFileSync(0, 'utf8'));
    const expressions = inputs.map(({word, tex}) => {
      try {
        return toMathML(tex);
      } catch (error) {
        throw new Error(`${word}: $${tex}$: ${error.message}`);
      }
    });
    process.stdout.write(JSON.stringify(expressions));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {toMathML};
