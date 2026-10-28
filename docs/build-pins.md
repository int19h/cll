# Build dependency pins

`Dockerfile`, `Dockerfile.weasyprint`, and `Dockerfile.context` use the same Ubuntu 24.04 image digest.
A digest identifies image contents.
The digest selects images for multiple processor types.
The local build tests cover ARM64.

All APT installations use the signed Ubuntu snapshot at `20261027T000000Z`.
A snapshot preserves the package archive at a date and time.
This fixes direct packages and their dependencies, including system fonts and layout libraries.
The sources exclude other archives and stop on an index download error.
APT still requires valid archive signatures and package hashes.
The sources disable the metadata expiration limit because the snapshot is historical.

Fresh Ubuntu images lack the certificates that HTTPS requires.
Each Dockerfile first downloads the dated curl certificate bundle `cacert-2026-10-20.pem`.
The build requires its SHA-256 hash before APT uses it.
APT then installs the snapshot's `ca-certificates` package.
The Prince packages also require architecture-specific SHA-256 hashes before installation.

The [Ubuntu snapshot service](https://snapshot.ubuntu.com/) states that it intends to retain at least two years of snapshots.
Keep the built image when preserving a release beyond that period.
These pins fix the recorded inputs while their hosts retain them.
A missing input stops the build.
The build does not substitute a newer version.

## ConTeXt distribution

`scripts/install-context.sh` uses two archives from official ConTeXt repositories.
`contextgarden/context` at `5751e39641a5acae5ce3eb579386394a1ed5da07` supplies ConTeXt and the LuaMetaTeX source.
`contextgarden/context-distribution-fonts` at `3b96e7c03fd4d68e5339e580ab87bdd9721c24f2` supplies the distribution fonts.

The script requires each archive's SHA-256 hash before extraction.
It compiles LuaMetaTeX with the snapshot's C compiler and CMake.
It requires ConTeXt version `2026.10.25 20:06` before and after compilation.
No changing upstream installer or additional distribution download runs.
The installation selects the source tree's standalone configuration through a `texmfcnf.lua` link.

For a local rebuild, `CLL_CONTEXT_ARCHIVES` can select a mounted archive directory through a Docker build argument.
That directory must contain `context-source.tar.gz` and `context-fonts.tar.gz`.
The installer requires the same hashes for cached files.
The default build downloads both files and removes them after installation.

## Build records

The toolchain is the set of programs used to build the book.
`cll_build` records it under `build/toolchain/` before the book build.
The records contain the following files when the relevant tools exist:

- `system-packages.tsv` lists installed package versions and architectures.
- `ubuntu.sources` records the package archive selection.
- `tools.txt` lists program and Ruby gem versions.
- `python-packages.txt` lists Python packages when `CLL_WEASYPRINT_PYTHON` selects the WeasyPrint environment.
- `fonts.tsv` lists fonts known to Fontconfig.
- `book-fonts.sha256` records hashes of the book's bundled fonts.
- `context-sources.txt` records ConTeXt commits, archive hashes, and the required version.

Native builds use the same record step.
They do not gain the container's dependency pins.
The selected engine also retains its own existing logs.

## Update the pins

Update dependencies in a separate reviewed change:

1. Select a new Ubuntu image digest for the supported architectures.
2. Select a matching Ubuntu archive timestamp in all three Dockerfiles.
3. If the HTTPS bootstrap bundle changes, update its dated URL and hash in all three Dockerfiles.
4. If Prince changes, update its versioned URLs and both architecture hashes.
5. If ConTeXt changes, select fixed source and font commits in `scripts/install-context.sh`.
6. Record the archive hashes and required ConTeXt version in that script.
7. Update the dependency pin tests and this document.
8. Build all three images locally.
9. Build the complete book with each selected engine.
10. Review the resulting PDFs and toolchain records.

Run the inexpensive guards with Python 3:

```sh
python3 scripts/test-build-pins.py
```

The guards reject changing image references, missing snapshot selection, and the old ConTeXt installer.
A fixture also supplies an incorrect archive and makes sure that installation stops before extraction.
Another fixture requires the standalone configuration during engine startup.
A full local build tests package availability, compilation, and rendering.
