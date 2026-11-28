// Convert a batch of glossary TeX fragments to inline MathML.
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');

const dependencies = process.env.CLL_MATHJAX_DIR || path.resolve(__dirname, '../build/weasyprint-tools');
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

function toMathML(tex) {
  const node = document.convert(tex, {display: false, end: STATE.COMPILED});
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
