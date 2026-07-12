# Building natively (outside the container)

The supported build environment is the container (`Dockerfile`,
`run_container.sh`); use it when you can. This note lists native
prerequisites for running `./cll_build` directly, for cases where the
container is impractical (quick single-chapter tests, debugging a
build step). It is an inventory of what `scripts/Makefile` and its
helper scripts actually invoke; the Dockerfile is the ground truth for
the container toolset.

`cll_build` propagates failures *reported by make*: if a make recipe
fails (including a missing tool invoked directly by a recipe, such as
`regenerator` or `prince`), the wrapper exits nonzero and prints
`BUILD FAILED`, and the post-build diff against `official/` is
skipped. Individual helper scripts may still mask their own internal
failures; hardening them is tracked separately.

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
- `ruby` and the gems pinned in `Gemfile.lock`. The locked Nokogiri
  builds a native extension, so Bundler needs a compiler and the
  library headers: on Debian/Ubuntu install `ruby-full build-essential
  libxml2-dev libxslt1-dev zlib1g-dev`, then
  `gem install bundler && bundle install`.

## Per-target extras

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
