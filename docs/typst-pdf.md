# Typst PDF

The optional Typst target builds `build/cll-typst.pdf` alongside the existing Prince output, `build/cll.pdf`.
The `pdf` target and the default `all` target still use Prince.
HTML, EPUB, and release publication retain their existing paths.

Typst uses the shared merged and preprocessed DocBook XML.
The converter maps that XML directly to native Typst elements.
It does not use XHTML, DocBook XSL, Prince, JavaScript, or packages from Typst Universe.

## Container build

From the checkout, run:

```sh
./run_typst_container.sh
```

For a chapter excerpt, run:

```sh
./run_typst_container.sh -t chapters/18.xml
```

The launcher uses the `typst` stage in `Dockerfile`.
That stage installs Typst 0.15.1 without installing Prince.
The installer checks the SHA-256 hash of the release archive for Linux x86_64 or aarch64.

The launcher supports `-a DIRECTORY` to copy `cll-typst.pdf` to another directory.
It forwards chapter selection and the existing `-s` and `-t` modes to `cll_build`.
The legacy HTML comparison does not run for the Typst target.

## Concurrent worktrees

Give each worktree its own physical build directory before the first build:

```sh
mkdir -p /build/cll/my-typst-build
ln -s /build/cll/my-typst-build build
./run_typst_container.sh
```

The launcher mounts the checkout and the physical build directory at their original absolute paths inside the container.
This preserves both absolute and relative symlinks.
Its image tag includes a hash of the checkout path.
Each invocation receives a fresh container ID and removes that container on exit.
The launcher does not stop or remove other containers.

Use one build process per worktree.
Concurrent builds in the same worktree share intermediate files, even when their final PDF names differ.

## Local build

The local route needs the existing merge dependencies: Ruby, Nokogiri, Optimist, HTMLEntities, regenerator, and the XML tools.
It also needs Typst 0.15.1.
To install the pinned executable inside the build directory, run:

```sh
./scripts/install_typst.sh build/tools
TYPST="$PWD/build/tools/typst" ./cll_build -n -T pdf_typst
```

If Typst 0.15.1 is on `PATH`, run:

```sh
./cll_build -n -T pdf_typst
```

The `typst` target is an alias for `pdf_typst`.
The converter rejects missing cross-reference targets in a full book.
For excerpts built with `-s` or `-t`, it reports references outside the excerpt and prints their identifiers without broken links.
The shared merge step retains its existing chapter-numbering behavior for excerpts.

## Layout and files

The template preserves the 159 × 240 mm pages, margins, Linux Libertine text, heading styles, examples, illustrations, and status marks.
It uses native tables for word-by-word glosses and native mathematics for the source MathML subset.
The glossary and both indexes use two columns.
Indexes combine duplicate page references and consecutive page ranges.
Cross-references include clickable page numbers.
The PDF includes bookmarks for chapter, section, and bridgehead headings.

The compiler loads the bundled fonts and its embedded fonts with system-font discovery disabled.
Mathematics uses New Computer Modern Math, which the pinned compiler embeds.
The line breaks, page breaks, and total page count can differ from Prince.

The new files have these roles:

| File | Purpose |
| --- | --- |
| `scripts/docbook_to_typst.rb` | Convert the preprocessed XML and resolve identifiers, numbering, and index terms |
| `typst/book.typ` | Define the book layout and render references and indexes |
| `scripts/build_pdf_typst.sh` | Stage assets, run conversion and compilation, and publish the successful PDF locally |
| `scripts/install_typst.sh` | Install the pinned compiler with an archive hash check |
| `run_typst_container.sh` | Build and run the isolated Typst container |

Generated Typst source, staged assets, compiler version, and logs remain in `build/typst/`.
A failed compilation leaves the previous successful `build/cll-typst.pdf` intact.
Unsupported XML elements or mathematical structures cause an error instead of silent content loss.
The converter targets the current CLL vocabulary, rather than all possible DocBook constructs.
For example, it rejects table row spans and CALS tables until they receive explicit support.

## Tests

Run the converter tests with Ruby:

```sh
ruby scripts/test_docbook_to_typst.rb
```

To include native compilation, set `TYPST`:

```sh
TYPST="$PWD/build/tools/typst" ruby scripts/test_docbook_to_typst.rb
```

The tests cover literal text, entities, identifier uniqueness, reference labels, native math, column spans, indexes, and unsupported input.
The compilation test includes a table of contents and linked heading aliases to detect duplicated anchors.
For a layout change, also build the full book and inspect its examples, mathematical formulas, glossary, and indexes.
