# WeasyPrint PDF build

This optional backend produces `build/cll-weasyprint.pdf` with WeasyPrint and MathJax.
The existing `pdf` target and default build still use Prince.
The title-page footer shows the edition, source commit, and build date.
A matching version tag at the current commit removes the commit suffix.
The footer uses small, gray, monospaced text at the center of the bottom margin.
The new target reuses the book's print XHTML transformation and base stylesheet.
The transformation files retain their existing Prince names because both backends use their formatting rules.

## Container build

Run the complete PDF build:

```sh
./run_weasyprint_container.sh
```

The launcher uses Podman or Docker.
It also accepts the existing `-t` and `-s` flags and chapter filenames.
The existing chapter-preview preprocessing does not resolve every cross-reference outside the selected chapters.
Chapters 1 and 18 both fail standalone XML validation because they reference omitted appendices.
Use the complete build when a selected chapter needs those references.
`CONTAINER_BIN` selects another installed executable.
The image contains the common DocBook tools, WeasyPrint, and MathJax.
It does not install or call Prince.
Each checkout gets a separate image tag, and each run gets an unnamed temporary container.
A lock prevents simultaneous builds from sharing the same output directory.

## External output

In a new worktree without an existing `build` directory, create a separate output directory and link:

```sh
mkdir -p /build/cll/my-weasyprint-build
ln -s /build/cll/my-weasyprint-build build
```

The launcher mounts the link destination inside the container.
Intermediate files, logs from the shared transformation, and final output use that directory.
Temporary files and font caches also use that directory during container builds.
Use a different destination for each worktree.
Do not use the legacy container launcher for this backend because it uses a shared container name.

## Local build

Install the common DocBook and Ruby tools listed in `Dockerfile.weasyprint`.
Install Python 3 with venv support, Node.js 22 or later, Pango, HarfBuzz, and the listed fonts.
Then install the backend dependencies:

```sh
./scripts/install-weasyprint.sh
./cll_build -n -T pdf_weasyprint
```

The installer places Python and Node dependencies under `build/weasyprint-tools`.
It uses the pinned Python requirements and npm lockfile.
`CLL_WEASYPRINT_PYTHON` and `CLL_MATHJAX_DIR` select existing installations.
The container sets both variables to its packaged dependencies.
Both container launchers read the version from Git on the host and pass `CLL_BUILD_VERSION` into the container.
For an exported source tree without Git metadata, set `CLL_BUILD_VERSION` to the complete source version before building.
The shared build refreshes the book when its version or build date changes.

Run the focused backend tests with the installed Python interpreter:

```sh
PYTHONDONTWRITEBYTECODE=1 build/weasyprint-tools/venv/bin/python scripts/test-weasyprint.py
```

## Rendering

MathJax converts MathML to static CommonHTML before WeasyPrint renders the document.
The build copies the mathematical fonts beside the generated HTML.
The renderer fetches only local files and embedded data.
The current mathematical font is New Computer Modern at the book's text size.
Mathematical layout remains distinct from semantic accessibility.

The backend replaces legacy table-span sentinels with actual column counts.
It also converts index references into sorted, linked page ranges.
The chrestomathy contains a hidden vocabulary list that supplies index metadata.
Its invisible index markers stay at that list's location, so their links reach the section instead of an invalid page zero.
These references identify the section opening, not each word's exact occurrence within the reading passages.
The renderer repeats pagination until the index references stop changing.
Missing index targets, missing assets, invalid mathematics, and nonconvergent pagination fail the build.
The PDF replaces the previous output only after successful rendering.

`build/weasyprint/cll-weasyprint.html` preserves the final rendering input.
`build/weasyprint/render-report.json` records page counts, pagination passes, mathematical expressions, and index targets.
`assets/css/weasyprint.css` contains the backend's layout overrides.
The main stylesheet still supplies fonts, page dimensions, and most formatting.

The output preserves the book's style, but line breaks and page breaks can differ from Prince.
The wide table in Example 10.74 clips at the page edge in both backends.
The backend does not claim pixel equality or a printer-specific PDF standard.
