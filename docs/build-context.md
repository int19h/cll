# Building the ConTeXt PDF

The opt-in `pdf_context` target builds `build/cll-context.pdf`.
The existing `pdf` target still uses Prince and builds `build/cll.pdf`.
The default `all` target and the release pipeline retain their existing behavior.

## Container build

Run the full book build from your checkout:

```sh
./run_context_container.sh
```

Run a chapter build with the existing testing mode:

```sh
./run_context_container.sh -t chapters/18.xml
```

The testing mode uses placeholder glossary definitions and adjusts cross-references, as the Prince chapter build does.
Chapter numbering follows the selected input order.

The wrapper uses Podman when available, or Docker otherwise.
Set `CONTAINER_BIN` to select another executable.
It builds `Dockerfile.context`, which contains no Prince installation.
Each invocation uses an unnamed disposable container and the image ID stored in its own build directory.
It does not stop existing containers or overwrite a shared image tag.

Use `-a DIRECTORY` to copy the result to another directory.
The copied file is also named `cll-context.pdf`.

## Isolated output

Each worktree needs its own build directory.
For a new worktree without an existing `build` path, create the link before starting a build:

```sh
mkdir -p /build/cll/my-context-build
ln -s /build/cll/my-context-build build
```

The container wrapper mounts both the checkout and the resolved build directory at their original absolute paths.
This preserves the link inside the container.
ConTeXt writes its temporary files and font cache under `build/context/`.
Use a separate build directory for concurrent runs with different chapter selections.

## Native build

Install ConTeXt LMTX from the [official installer](https://www.pragma-ade.nl/install.htm).
Install the shared Ruby gems and `regenerator` described in [the native build guide](build-native.md).
Install Python 3 and Pillow for image preparation.
The Debian and Ubuntu package for Pillow is `python3-pil`.

Run the new target:

```sh
./cll_build -n -T pdf_context
./cll_build -n -t -T pdf_context chapters/18.xml
```

The `-n` flag skips the existing HTML comparison workflow.
If `context` is outside `PATH`, set `CONTEXT_BIN` to its executable path.
The script finds `mtxrun` beside that executable.
Set `MTXRUN_BIN` if the executables use different directories.

This target does not download or invoke the DocBook XHTML stylesheets.
It reuses the existing merged XML and the normalized DocBook from `xml_preprocess.rb`.
That intermediate file retains its historical name, `cll_processed_xhtml.xml`.
The new converter produces ConTeXt directly from that XML.

## Layout and features

The layout lives in `assets/context/cll-layout.tex`.
It uses the bundled Linux Libertine text fonts, Libertinus Math, and the bundled Crisa and CJK fonts.
It preserves the 159 × 240 mm page size and the existing heading and body sizes.
It includes running headers, double-sided pages, chapter openings, a contents list, PDF bookmarks, links, and page references.
It generates the glossary and both indexes from the source markup.
The indexes use ConTeXt registers, which collect and combine page references.

The converter maps fractions, powers, and square roots to native mathematics.
It preserves the interlinear word and gloss columns from the shared preprocessing stage.
It converts GIF images to PNG because the PDF backend requires a supported image format.
The staged PNG files use 96 pixels per inch, with the existing 200-pixel height limit.
The source images remain unchanged.

Line breaks, page breaks, table widths, and total page counts differ from Prince.
The layout aims to preserve the book's style rather than its exact pagination.
It does not enable a special PDF/X profile, printing marks, or sheet imposition.

## Diagnostics and tests

The converter rejects unknown elements and unsupported MathML structures.
`build/context/conversion.json` records element counts, referenced images, and references outside the selected input.
`build/context/renderer.log` records the ConTeXt run.
`build/context/engine-version.txt` records the engine version.
A failed conversion or engine run returns a nonzero exit status and leaves the previous published output intact.

Run the converter tests:

```sh
ruby scripts/test-docbook-to-context.rb
python3 scripts/test-context-assets.py
```

The container installs the current LMTX distribution from upstream.
Upstream updates can change layout, even when the source XML stays the same.
Preserve the built container image and its ID when freezing an output for comparison.
The version log alone does not pin the complete distribution.
