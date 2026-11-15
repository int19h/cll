# Building natively (outside the container)

The supported build environment is the container (`Dockerfile` and `run_container.sh`).
When you can, use the container.
This note lists the native prerequisites for `./cll_build`.
Use a native build for a quick single-chapter test, or to debug one build step.
The list is the tools that `scripts/Makefile` and its helper scripts invoke.
The Dockerfile is the ground truth for the container toolset.

`cll_build` exits with a nonzero status after `make` reports a failure.
A missing tool in a recipe is one such failure. Examples are `regenerator` and `prince`.
`cll_build` prints `BUILD FAILED`. It then skips the comparison with `official/`.
`cll_build` also exits with a nonzero status after `scripts/diff_official` fails.
It prints a warning that names the comparison status.
Use `-n` to skip the comparison.
The XHTML post-processing scripts stop after a tool fails.
They keep the original page. They do not write an empty file in its place.

## Shared by every target

The merged `cll.xml` is a prerequisite of the XHTML, PDF, and EPUB targets.
The build uses these tools:

- `bash`, `make`, `wget`, and `unzip`. On the first run, the build downloads and unpacks the DocBook XSL stylesheets.
- `xmlto` and `xmllint`. `xmlto` pulls in `xsltproc`. On Debian and Ubuntu, `xmllint` is in `libxml2-utils`, and that package is installed with `xmlto`. The postprocessing scripts call `xmllint` directly.
- `regenerator` from npm (`npm install -g regenerator`). The build uses it for the ES5 transform of `assets/scripts/sance-next.js` while it assembles `cll.xml`.
- Ruby 3.2 or later and Bundler 4.
  `Gemfile.lock` pins Nokogiri 1.18.8, Optimist 3.2.0, and htmlentities 4.3.4.
  The Nokogiri gem is precompiled for x86_64 Linux and for aarch64 Linux.
  Run `gem install bundler && bundle install`.

## Per-target extras

The optional ConTeXt PDF has a [separate build guide](build-context.md).
It runs beside the Prince pipeline and writes `build/cll-context.pdf`.

- **XHTML**: the Nu Html Checker (`scripts/install-vnu.sh`, Java).
- **PDF**: `prince` (PrinceXML). Download a package for your platform from princexml.com. For the same fonts as the container, also install the DejaVu and Linux Libertine packages (`fonts-dejavu` and `fonts-linuxlibertine`). The stylesheet loads its special-purpose faces from the repository's own `assets/`.
- **EPUB**: `zip` (the package is assembled by `scripts/build_epub.sh`).
  The installer needs `curl` and `unzip`.
  The check needs a Java runtime (`default-jre-headless` or `default-jre`).
  The ePub target runs EPUBCheck 5.4.0.
  The container image includes that release.
  If the image jar is absent, a native build calls `scripts/install-epubcheck.sh`.
  When the target is `all` or `epub`, `cll_build` installs that checker before the toolchain record.
  If the stamp matches the pin, the installer keeps the existing copy.
  See [build-pins.md](build-pins.md).

A single-chapter test build that exercises most of the toolchain:

```
./cll_build -t chapters/05.xml
```

Targets whose tools are present can be built individually via
`-T <target>` (see `./cll_build -h` for the list).
