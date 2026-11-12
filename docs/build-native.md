# Building natively (outside the container)

The supported build environment is the container (`Dockerfile`,
`run_container.sh`); use it when you can. This note lists native
prerequisites for running `./cll_build` directly, for cases where the
container is impractical (quick single-chapter tests, debugging a
build step). It is an inventory of what `scripts/Makefile` and its
helper scripts actually invoke; the Dockerfile is the ground truth for
the container toolset.

`cll_build` exits with a nonzero status after `make` reports a failure.
A missing tool in a recipe is one such failure. Examples are `regenerator` and `prince`.
`cll_build` prints `BUILD FAILED`. It then skips the comparison with `official/`.
`cll_build` also exits with a nonzero status after `scripts/diff_official` fails.
It prints a warning that names the comparison status.
Use `-n` to skip the comparison.
The XHTML post-processing scripts stop after a tool fails.
They keep the original page. They do not write an empty file in its place.

## Shared by every target

Building the merged `cll.xml` — a prerequisite of the XHTML, PDF, and
EPUB targets alike — uses:

- `bash`, `make`, `wget`, `unzip` (the DocBook XSL stylesheets are
  downloaded and unpacked automatically on first run);
- `xmlto` (which pulls in `xsltproc`) and `xmllint` (Debian/Ubuntu:
  `libxml2-utils`, installed transitively with `xmlto`; listed here
  because the postprocessing scripts call it directly);
- `regenerator` from npm (`npm install -g regenerator`), used for the
  ES5 transform of `assets/scripts/sance-next.js` while assembling
  `cll.xml`;
- Ruby 3.2 or later and Bundler 4.
  `Gemfile.lock` pins Nokogiri 1.18.8, Optimist 3.2.0, and htmlentities 4.3.4.
  The Nokogiri gem is precompiled for x86_64 Linux and for aarch64 Linux.
  Run `gem install bundler && bundle install`.

## Per-target extras

The optional ConTeXt PDF has a [separate build guide](build-context.md).
It runs beside the Prince pipeline and writes `build/cll-context.pdf`.

- **XHTML (no-chunks path)**: `tidy` (wrapped by `scripts/tidy`).
- **PDF**: `prince` (PrinceXML; download a package for your platform
  from princexml.com). For output parity with the container also
  install the DejaVu and Linux Libertine system font packages
  (`fonts-dejavu`, `fonts-linuxlibertine`); the stylesheet loads its
  special-purpose faces from the repository's own `assets/`.
- **EPUB**: `zip` (the EPUB is assembled by `scripts/build_epub.sh`)
  and a Java runtime (`default-jre`) for the bundled epubcheck.

A single-chapter test build that exercises most of the toolchain:

```
./cll_build -t chapters/05.xml
```

Targets whose tools are present can be built individually via
`-T <target>` (see `./cll_build -h` for the list).
