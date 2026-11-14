# Checks and tests

The `checks` workflow (`.github/workflows/checks.yml`) runs on every pull request to `main` and on every push to `main`.
This page lists each check that it runs, what the check tests, and the command that runs it locally.
Run the commands from the repository root.
None of them builds the book.

## Tools

The workflow uses these tools.
Install the tools for the checks that you want to run.

- Python 3 and Pillow. On Debian and Ubuntu, Pillow is `python3-pil`.
- `xmllint` and `zip`. On Debian and Ubuntu, `xmllint` is in `libxml2-utils`.
- Ruby 3.2 with Nokogiri 1.18.8: `gem install --no-document nokogiri:1.18.8`.
- `xsltproc`, for the ePub navigation check. On Debian and Ubuntu, it is in the `xsltproc` package.
- Node.js 24.
- For the parser checks, a checkout of [ilmentufa](https://github.com/lojban/ilmentufa) at the commit that the workflow pins (see [Parser probes](#parser-probes)).

The WeasyPrint and Typst checks install their own pinned tools, as described in their sections.

## Quick run

These commands cover the checks that need only Python with Pillow, Ruby with Nokogiri, `xmllint`, `xsltproc`, `zip`, `unzip`, and Node.js.
The first two lines join the book into one file and check it with `xmllint`.
In CI, a problem makes the workflow print the `xmllint` output.
Locally, read the output for warnings that contain `not defined`, `parser error`, or `already defined`.

```sh
{ cat scripts/header.xml chapters/*.xml; echo '</book>'; } > book-assembled.xml
xmllint --loaddtd --noent --noout book-assembled.xml; rm book-assembled.xml
python3 scripts/test-build-actions.py
ruby scripts/test-build-workflow.rb
python3 scripts/test-makefile.py
python3 scripts/test-chapter-pictures.py
python3 scripts/test-lint-undotted-cmevla.py
python3 scripts/lint-undotted-cmevla.py chapters/*.xml
python3 scripts/test-extract-examples.py
python3 scripts/check-cross-reference.py chapters/21.xml
python3 scripts/test-check-cross-reference.py
python3 scripts/lint-status-markup.py chapters/*.xml
python3 scripts/test-lint-status-markup.py
python3 scripts/test-html-mathjax.py
python3 scripts/check-peg-grammar.py
python3 scripts/test-check-peg-grammar.py
python3 scripts/test-build-pins.py
scripts/check-edition-branding.sh
python3 scripts/test-build-epub.py
python3 scripts/test-epubcheck.py
python3 scripts/test-epub-nav.py
python3 scripts/test-xml-prince-postprocess.py
python3 scripts/test-offline-list.py
python3 scripts/test-nokogiri-spaces.py
ruby scripts/test-html-format.rb
ruby scripts/test-html-table-spans.rb
ruby scripts/test-lint-gloss-columns.rb
ruby scripts/lint-gloss-columns.rb chapters/*.xml
ruby scripts/test-lint-index-types.rb
ruby scripts/lint-index-types.rb chapters/*.xml
ruby scripts/test-merge-branding.rb
ruby scripts/test-partial-references.rb
ruby scripts/test-generate-glossary.rb
ruby scripts/test-lint-word-spellings.rb
ruby scripts/lint-word-spellings.rb chapters/*.xml
ruby scripts/test-jbophrase-frames.rb
ruby scripts/test-docbook-to-context.rb
python3 scripts/test-context-assets.py
python3 scripts/test-build-version.py
node tests/test-run-probes.js
node tests/test-audio-loading.js
node tests/test-offline-worker.js
node tests/test-offline-register.js
node tests/test-prince-index-guard.js
node tests/test-prince-index-prep.js
node tests/test-prince-index.js
```

## xml-wellformed

| Check | What it tests | Command |
| --- | --- | --- |
| Build workflow | The format selection, preview guard, and helper scripts of the "Build selected formats" workflow, and its action pins, permissions, and timeouts | `python3 scripts/test-build-actions.py` and `ruby scripts/test-build-workflow.rb` |
| Build helpers | The XHTML post-processors stop after a tool fails. They keep the original page. `cll_build` reports a failed comparison and exits with that status. `cll_build -j` refreshes `dictionary/all_words.xml`. `Gemfile.lock` matches the Docker gem pins. | `python3 scripts/test-build-helpers.py` |
| Chapter artwork | Each of chapters 1 to 21 references its own chapter picture, a large RGBA PNG in `assets/media/`, no unreferenced chapter picture is shipped, and the chapter 2 diagram keeps its size and padding | `python3 scripts/test-chapter-pictures.py` |
| Well-formed book | The book header and all chapters together are well-formed XML, with no undefined entity and no duplicate ID | See [Quick run](#quick-run) |

The book check joins `scripts/header.xml`, every `chapters/*.xml` file, and a closing `</book>` into one file.
`xmllint` reports undefined entities and duplicate IDs only as warnings, so the workflow searches its output for them and fails on a match.

## cmevla-dot-lint

| Check | What it tests | Command |
| --- | --- | --- |
| Dotside lint self-test | The lint below, on small fixtures | `python3 scripts/test-lint-undotted-cmevla.py` |
| Dotside lint | A name after `la`, `lai`, `la'i`, or `doi` has a dot on both sides, as the dotside rule requires | `python3 scripts/lint-undotted-cmevla.py chapters/*.xml` |
| Example extraction | `scripts/extract-examples.py`, which the example parse below uses | `python3 scripts/test-extract-examples.py` |
| EBNF cross-reference | Chapter 21's EBNF rules, their anchors, and the printed cross-reference agree | `python3 scripts/check-cross-reference.py chapters/21.xml` |
| EBNF cross-reference self-test | The check above fails on planted defects | `python3 scripts/test-check-cross-reference.py` |
| Status markup | The `role="status-note"` and `condition` markup follows [status-markup.md](status-markup.md) | `python3 scripts/lint-status-markup.py chapters/*.xml` |
| Status markup self-test | The lint above, on fixtures | `python3 scripts/test-lint-status-markup.py` |
| Browser MathJax | The HTML loads one pinned MathJax script with an integrity hash | `python3 scripts/test-html-mathjax.py` |
| PEG grammar | The word-form grammar printed in chapter 21 matches `tests/fixtures/peg-morphology.peg` rule for rule | `python3 scripts/check-peg-grammar.py` |
| PEG grammar self-test | The check above detects corrupted copies | `python3 scripts/test-check-peg-grammar.py` |
| Container pins | The Dockerfiles keep their fixed image digest, package snapshot, and ConTeXt inputs (see [build-pins.md](build-pins.md)) | `python3 scripts/test-build-pins.py` |

The dotside lint is a heuristic.
It treats a word that ends in a consonant after one of those cmavo as a name.
`scripts/lint-undotted-cmevla.allow` lists known cases, with a maximum count for each.
If a file has more cases than the list allows, the lint fails.
Do not add entries for new text.

The status lint reports a `status-note` without `condition` as a warning, and the warnings do not fail the job.

## edition-branding

| Check | What it tests | Command |
| --- | --- | --- |
| Edition branding | The PDF running head and the ePub name this edition from `.env`, and never the first edition | `scripts/check-edition-branding.sh` |
| ePub packaging | The ePub packager, run on a small book, keeps the reader's assets and leaves out the renderer sources | `python3 scripts/test-build-epub.py` |
| EPUBCheck pin and status | The installer rejects a bad archive before extraction. A warning is printed and the build continues. An error stops the build. CI installs the pinned checker first. If `CI` is set and the jar is missing, the live check fails. A missing spine page fails the real checker | `./scripts/install-epubcheck.sh build/tools/epubcheck` and `python3 scripts/test-epubcheck.py` |

## epub-nav

| Check | What it tests | Command |
| --- | --- | --- |
| ePub navigation document | The stylesheets write `toc.xhtml` from the DocBook source. The entries match the visible table of contents. `scripts/check_epub_nav.rb` rejects a broken navigation document or spine | `python3 scripts/test-epub-nav.py` |

The check needs `xsltproc` as well as Ruby and Nokogiri.

## prince-postprocess-smoke

| Check | What it tests | Command |
| --- | --- | --- |
| Prince postprocessor | `scripts/xml_prince_postprocess.rb`, the last step before Prince, on `tests/fixtures/xml-prince-postprocess.xhtml` | `python3 scripts/test-xml-prince-postprocess.py` |
| Offline file list | `scripts/xhtml_postprocess_offline.rb` writes `sw.js` for one HTML folder. It stops for a missing file or an unsafe name. It stops for a path that starts with `/`. It stops for a reference in a form it does not read, or for a precache above 20 MiB | `python3 scripts/test-offline-list.py` |
| Nokogiri spaces | The Ruby build scripts keep the spaces between inline elements | `python3 scripts/test-nokogiri-spaces.py` |
| HTML formatter | The formatter indents only between visible blocks. The guard rejects every other change. The stylesheet test recomputes the exclusion set and the whitespace-freeze set. If `origin/pages` is missing, that test fails and names `git fetch origin pages` | `ruby scripts/test-html-format.rb` |
| HTML table spans | The cleanup step drops an empty `colgroup` and replaces the placeholder colspan with the real column count of the table | `ruby scripts/test-html-table-spans.rb` |
| Gloss columns self-test | The lint below, on fixtures | `ruby scripts/test-lint-gloss-columns.rb` |
| Gloss columns | Each gloss line has a column for every Lojban word, and structural words such as `cu` and terminators have suitable glosses (see [markup-tags.md](markup-tags.md#interlinear-gloss)) | `ruby scripts/lint-gloss-columns.rb chapters/*.xml` |
| Index types self-test | The lint below, on fixtures | `ruby scripts/test-lint-index-types.rb` |
| Index types | Every hand-written `indexterm` has the type `general` or `lojban-word`, the only two indexes that the build makes | `ruby scripts/lint-index-types.rb chapters/*.xml` |
| Branding values | `.env` values with `&`, `'`, `=` and quotes reach the title page unchanged and as well-formed XML | `ruby scripts/test-merge-branding.rb` |
| Partial builds | With `-t` and `-s`, every cross-reference to an omitted target is replaced, so a single chapter passes validation | `ruby scripts/test-partial-references.rb` |
| Glossary | If the generator, `scripts/util.rb`, or the pronunciation recordings change, the glossary cache changes. Spellings with the same ID share one entry | `ruby scripts/test-generate-glossary.rb` |
| Word spellings self-test | The lint below, on fixtures | `ruby scripts/test-lint-word-spellings.rb` |
| Word spellings | Lojban text has no CGV sequence (a consonant, a glide, and a vowel). Every word with a comma between two vowels appears in `scripts/reviewed-comma-words.json`. It does not check commas next to consonants. It reads only Lojban elements such as `jbo`, `valsi`, and `jbophrase`. It skips text marked `valid="false"` or `valid="maybe"`. It also skips the quoted text of `zoi` and `la'o`. | `ruby scripts/lint-word-spellings.rb chapters/*.xml` |
| jbophrase frames | A frame such as `lu ... li'u` links each of its words to the glossary, and the glossary collects those words | `ruby scripts/test-jbophrase-frames.rb` |

This job checks that Nokogiri is version 1.18.8, the version that the Dockerfile installs.
Check your version with `ruby -rnokogiri -e 'puts Nokogiri::VERSION'`.

Set `offline` to `no` to skip `sw.js`.
Any other value of `offline` writes `sw.js`.
`cll_build` passes its environment through to `make`.
It does not accept make variables as arguments.
The pages branch will set `offline=no` for comparison builds.
It will use this command:

```sh
offline=no ./cll_build -n -T xhtml_nochunks
```

## typst-smoke

This job installs the pinned Typst compiler and runs the converter tests with it:

```sh
bash scripts/install_typst.sh build/tools
TYPST="$PWD/build/tools/typst" ruby scripts/test_docbook_to_typst.rb
```

Without `TYPST`, the tests skip the compilation step.
See [typst-pdf.md](typst-pdf.md#tests).

## weasyprint-smoke

This job installs the pinned WeasyPrint and MathJax tools under `build/weasyprint-tools`, then tests the version label and the renderer:

```sh
./scripts/install-weasyprint.sh
python3 scripts/test-build-version.py
PYTHONDONTWRITEBYTECODE=1 build/weasyprint-tools/venv/bin/python scripts/test-weasyprint.py
```

The installer needs Python 3 with `venv` and Node.js 22 or later.
The renderer also needs Pango, HarfBuzz, and the fonts listed in [build-weasyprint.md](build-weasyprint.md#local-build).
`scripts/test-build-version.py` tests the version label that `scripts/build-version.sh` makes from `.env` and Git tags.

## context-converter

| Check | What it tests | Command |
| --- | --- | --- |
| Script syntax | The build scripts parse as Bash | `bash -n cll_build run_context_container.sh scripts/build_context.sh` |
| ConTeXt converter | `scripts/docbook_to_context.rb` on small books | `ruby scripts/test-docbook-to-context.rb` |
| ConTeXt assets | `scripts/context_assets.py`, which prepares images for the ConTeXt PDF | `python3 scripts/test-context-assets.py` |

See [build-context.md](build-context.md#diagnostics-and-tests).

## Parser probes

The `parser-probes` job fetches ilmentufa, the JavaScript camxes parser, at a pinned commit.
To get the same checkout:

```sh
mkdir ../ilmentufa && cd ../ilmentufa
git init -q
git remote add origin https://github.com/lojban/ilmentufa
git fetch -q --depth 1 origin 778ea138f7d150121ca722db7536ce3b123943ac
git checkout -q FETCH_HEAD
cd -
```

If the workflow changes the pin, use the commit in `.github/workflows/checks.yml`.

| Check | What it tests | Command |
| --- | --- | --- |
| Comma syllables | camxes splits each word in `scripts/reviewed-comma-words.json` into syllables at its commas | `ILMENTUFA_DIR=../ilmentufa node scripts/check-comma-syllables.js` |
| Probe runner | `tests/run-probes.js` reports parser failures correctly | `node tests/test-run-probes.js` |
| Audio loading | `assets/scripts/sance-next.js`, which plays pronunciation audio in the HTML book, handles loading failures | `node tests/test-audio-loading.js` |
| Offline worker | The service worker stores the listed files, ignores audio and other unknown requests, and drops only its own old caches. The test checks the filled worker script with `node --check` | `node tests/test-offline-worker.js` |
| Offline registration | `assets/scripts/offline.js` registers `sw.js` for a page in the book folder, and skips comparison pages, `file:` URLs, and data saver | `node tests/test-offline-register.js` |
| Prince index | The Prince scripts that check and format the index | `node tests/test-prince-index-guard.js`, `node tests/test-prince-index-prep.js`, and `node tests/test-prince-index.js` |
| Magic-word probes | The parser accepts or rejects each probe in `tests/fixtures/magic-word-probes.tsv` as expected | `ILMENTUFA_DIR=../ilmentufa node tests/run-probes.js` |

[tests/README.md](../tests/README.md) describes the probe table and its exit codes.

## Example validation

The `example-validation` job is report-only.
Its failures do not fail the workflow.
It extracts every Lojban example line and parses it with camxes:

```sh
python3 scripts/extract-examples.py chapters/*.xml > examples.tsv
ILMENTUFA_DIR=../ilmentufa node scripts/validate-examples.js examples.tsv
```

The workflow saves the report as the `example-report` artifact.
The report also lists lines that are invalid on purpose.
Check the result for any example that you changed.

## Other tests

These tests do not run in the `checks` workflow:

- `python3 scripts/test-context-indexes.py build/cll-context.pdf` checks the printed indexes of a finished ConTeXt PDF. It needs PyMuPDF.
- `python3 scripts/test-html-mathjax.py FILE` also compares a downloaded MathJax script with the integrity hash. See the [README](../README.md#mathematics-in-the-html-book).

### Offline reading in a browser

`tests/browser-offline.mjs` is a manual test.
It needs a build of both HTML forms.
It also needs the `playwright-core` package and the Chromium and Firefox browsers.
Install them outside the repository:

```sh
npm install --prefix /tmp/cll-playwright playwright-core@1.64.1
node /tmp/cll-playwright/node_modules/playwright-core/cli.js install chromium firefox
```

Run the test from the repository root.
When `playwright-core` is on the normal module path, Node loads it.
When Node cannot find the package, set `PLAYWRIGHT_CORE` to its directory.

```sh
./cll_build -n -T xhtml_sections
./cll_build -n -T xhtml_nochunks
PLAYWRIGHT_CORE=/tmp/cll-playwright/node_modules/playwright-core node tests/browser-offline.mjs chromium
PLAYWRIGHT_CORE=/tmp/cll-playwright/node_modules/playwright-core node tests/browser-offline.mjs firefox
```

The default folders are `build/xhtml_section_chunks` and `build/xhtml_no_chunks`.
Set `CLL_SECTION` and `CLL_SINGLE` to use other folders.
`CLL_PORT` selects the local port.
The default port is 18905.
The script keeps its temporary files in the system temporary directory.
Set `CLL_SCRATCH` to use another directory.
The script creates that directory.
The second argument can be a browser executable.

The script serves the build on the local port. It checks all of the following:

1. A comparison page loads `offline.js`, registers no worker, and requests no `sw.js`.
2. One visit to a section page registers one worker. Its scope is that book folder.
3. The cache entry count equals the precache list in `sw.js`.
4. The installation requests no audio file, no Noto font, no `dtd/` file, and no PDF-only file.
5. With the network off, a page that was never opened loads, with its fonts and a chapter picture.
6. With the network off, the folder URL, a query string, and a fragment load.
7. With the network off, a link opens the next page.
8. With the network off, the largest page loads.
9. With the network off, the other HTML form and the version landing page do not load.
10. During the offline steps, the server log has no request, apart from a Firefox update request for `sw.js`.
11. On a controlled page, the server log has no `GET` for the page or for `final.css`. A `HEAD` request returns 200. A `Range` request returns 206.
12. A visit to the one-page form creates a second cache. The first cache stays.
13. After a visit to a page with Chinese text, the Noto font is in the cache and loads offline.
14. After one page changes and the generator runs, a reload installs a new cache. The next reload shows the new page.
15. A `sw.js` whose build hash does not match the page fails to install. The old worker still serves the book offline. After the generator runs, the next visit completes the installation.
16. No page reports a script error.

### Offline reading of a draft release

The first release that contains the service worker needs this test on its draft, after the Pages deployment finishes and before publication.
Use current Chrome, Firefox, and Safari. Include one phone.

1. Open one section page of the draft. Wait until the `html` element has `data-offline="ready"`, or wait one minute.
2. Turn the network off. Open five pages that you did not open before, through links and through the table of contents. Each page loads with its fonts and pictures.
3. Reload one of those pages. It loads.
4. Open a page of version 1.3.7 with the network off. It fails to load.
5. Turn the network on. Play one audio example. It plays.
6. Open a comparison page. The developer tools show no service worker for that page.
7. Repeat steps 1 to 3 for the one-page form.
8. The origin holds one cache for each form that you opened. Each cache name contains that version's path.

Every step must succeed in each browser. The same steps are part of the release review in [releasing.md](releasing.md#review-and-publish).

To check one chapter in a real build, run `./cll_build -t chapters/NN.xml`, or use the container as described in the [README](../README.md#build-on-your-computer).
