# The Contemporary Lojban Language

This repository holds the source of *The Contemporary Lojban Language*, an updated edition of *The Complete Lojban Language* (CLL) by John Woldemar Cowan.
The edition describes Lojban as it is used today, and it marks the authority of each rule that changed after the first edition.
The repository is a fork of [lojban/cll](https://github.com/lojban/cll), which holds CLL 1.1.

Read the book at <https://int19h.github.io/cll/>.
Report errors and suggest changes in the [issues](https://github.com/int19h/cll/issues).

## Repository layout

| Path | Contents |
| --- | --- |
| `chapters/` | The book in DocBook 5 XML, one file per chapter. `a01.xml` is the chrestomathy (reading passages), and `a03.xml` lists the changes from the first edition. |
| `assets/` | Stylesheets, fonts, pictures, and the scripts of the HTML book |
| `xml/` | DocBook XSL settings for HTML, ePub, and the print HTML that Prince and WeasyPrint render |
| `dtd/` | The DocBook, MathML, and XHTML DTDs |
| `scripts/` | The build, the converters, the lints, and their tests |
| `tests/` | Parser probes and test fixtures |
| `typst/` | The Typst page layout, `book.typ` |
| `epub/` | ePub templates and the bundled epubcheck |
| `dictionary/` | `all_words.xml`, the jbovlaste dictionary export that the glossary uses. If this file is missing or empty, the build downloads a new export. |
| `official/` | Published builds of CLL 1.1 and of the upstream 1.2 versions, which the local comparison step uses. `official/gadri/` keeps the ratified text of the article reform. |
| `orig/` | Files from the first edition, and the SVG source of the chapter 2 diagram |
| `coverage/` | Small test books for the coverage mode of `cll_build` (`-c`). They predate the current asset layout, and no check runs them. |
| `docs/` | Contributor guides |

The `pages` branch holds the workflow that publishes the book site.

## Build on your computer

### Get the source

Fork the repository on GitHub with the **Fork** button, then clone your fork:

```sh
git clone https://github.com/YOUR-NAME/cll.git
cd cll
```

### Container build

The main build runs in a container.
You need Bash and either Podman or Docker.
With Podman, the launcher uses `--userns=keep-id`.
With Docker, it runs as your user and group.
Build output stays owned by your user.

The script runs the command in `CONTAINER_BIN`.
If that variable is not set, it uses `podman`, or `docker` if Podman is not installed.
If `info` fails for the selected command, the script stops.

To build all formats, run:

```sh
./run_container.sh
```

The script builds the image `lojban/cll_build` from `Dockerfile`.
It then runs `./cll_build` inside a container named `cll_build`, with your checkout mounted, and passes its own arguments to `cll_build`.
Before it starts, it stops and removes any container with that name, so run only one such build at a time on a machine.
It enables interactive input and terminal output only when standard input is a terminal.
It also runs from scripts and CI.
If `build/` is a symlink, the launcher mounts its destination too.

### Build options

| Option | Effect |
| --- | --- |
| `-t` | Fast test build. The build changes cross-references so that the selected files build on their own, and it skips most of the glossary work. |
| `-s` | Like `-t`, but with the full glossary |
| `-T TARGET` | Build one target instead of `all` |
| `-a DIRECTORY` | Copy the results to `DIRECTORY` as well. The launcher creates the directory if needed and resolves it to an absolute path before mounting it. Relative paths start from the current directory. |
| `-n` | Skip the comparison with `official/` |
| `-h` | Print the usage, including the list of targets. `./cll_build -h` prints it without a container. |

To build one or more chapters, give their files after `-t` or `-s`:

```sh
./run_container.sh -t -n chapters/05.xml
./run_container.sh -t -n chapters/05.xml chapters/06.xml
```

The `-n` option skips the comparison with the copies in `official/`, which would compare these chapters with the whole book.

`-t` without chapter files builds the whole book faster than a full build:

```sh
./run_container.sh -t
```

To build only one format, choose a target:

```sh
./run_container.sh -t -n -T pdf
```

The default target, `all`, builds the three HTML versions, the Prince PDF, and the ePub.

| Target | Output |
| --- | --- |
| `xhtml_chapters` | `build/xhtml_chapter_chunks/`, one HTML page per chapter |
| `xhtml_sections` | `build/xhtml_section_chunks/`, one HTML page per section |
| `xhtml_nochunks` | `build/xhtml_no_chunks/`, the whole book on one page |
| `pdf` | `build/cll.pdf`, made by Prince |
| `epub` (or `mobi`) | `build/cll.epub` |
| `clean`, `realclean` | Remove build output |

Open `index.html` in an HTML folder to read that version.
With `-a`, the HTML folders are copied as `cll-xhtml_chapter_chunks/`, `cll-xhtml_section_chunks/`, and `cll-xhtml_no_chunks/`, beside `cll.pdf` and `cll.epub`.
The ePub step with `-a` also tries to copy `cll.mobi`, which the build does not make.
So `-a` with the default target fails at the ePub step.
Use `-a` together with `-T` and an HTML or PDF target, for example:

```sh
./run_container.sh -n -T pdf -a output
```

Issue [#176](https://github.com/int19h/cll/issues/176) tracks this problem.

After a successful build, `cll_build` compares the single-page HTML with the copies in `official/`.
It writes the visual comparisons to `build/diff_from_official/` and `build/diff_from_previous/`.
This step needs `build/xhtml_no_chunks/`.
To build another target alone, add `-n`.

### Other PDF engines

Prince makes the default PDF.
Three other engines each have their own launcher, image, and guide:

| Engine | Command | Output | Guide |
| --- | --- | --- | --- |
| WeasyPrint | `./run_weasyprint_container.sh` | `build/cll-weasyprint.pdf` | [docs/build-weasyprint.md](docs/build-weasyprint.md) |
| Typst | `./run_typst_container.sh` | `build/cll-typst.pdf` | [docs/typst-pdf.md](docs/typst-pdf.md) |
| ConTeXt | `./run_context_container.sh` | `build/cll-context.pdf` | [docs/build-context.md](docs/build-context.md) |

Each launcher accepts `-t` and `-s` with chapter files, as `run_container.sh` does.
The Typst and ConTeXt launchers also accept `-a DIRECTORY`.
They create the directory if needed and resolve it to an absolute path before mounting it.
The Typst launcher resolves relative paths from the checkout; ConTeXt uses the current directory.
These three launchers pass `--userns=keep-id` only to Podman.
With Docker, they run the container as your user and group instead.
The "Build selected formats" workflow runs the ConTeXt launcher with Docker.
The Typst and ConTeXt PDFs are still experimental.

### Native build and pins

To run `./cll_build` without a container, install its tools yourself.
[docs/build-native.md](docs/build-native.md) lists them.
The container images use fixed versions of their inputs, described in [docs/build-pins.md](docs/build-pins.md).

## Build on GitHub

You can build the book on GitHub Actions without a local checkout.
For example, you can edit chapters in GitHub's web editor in your fork and then build them there.

1. Fork the repository. Leave **Copy the main branch only** selected.
2. In your fork, open a file in `chapters/`, select **Edit**, and commit your change to a new branch.
3. Open **Actions** and enable workflows for the fork.
4. Select **Build selected formats**, then **Run workflow**.
5. Choose your branch and the formats that you need, then select **Run workflow**.
6. When the run ends, download the results under **Artifacts** on the run page.

You can select any combination of `html`, `epub`, `pdf` (Prince), `pdf-weasyprint`, `pdf-typst`, and `pdf-context`.
`html` is selected by default.
Each format becomes a separate artifact named `cll-<format>`, which GitHub serves as a ZIP file and keeps for 14 days.
The `html` artifact contains the section-per-page and single-page versions, with an `index.html` that links to both.
If one format fails, the workflow still uploads the others, and the run fails at the end.

The `preview` option is also selected by default.
It publishes the HTML build to your fork's GitHub Pages site, so you can read it online.
It needs the `html` format and some one-time settings in your fork.
If Pages is not set up in your fork, the workflow skips the preview and still uploads the artifacts.
To get only the artifacts, clear `preview`.

The branch must contain the workflow, so update an older branch from `main` first.
[docs/build-actions.md](docs/build-actions.md) gives the fork settings for previews, including the Pages environment rule that lets your branch deploy.
It also describes the contents of each artifact and the checks that keep a preview from replacing a published book site.

## Before you open a pull request

Open pull requests against `main`, with one branch and one pull request for each issue.
The `checks` workflow runs on every pull request.
[docs/checks.md](docs/checks.md) lists every check, what it tests, and how to run it locally.
Most checks need only Python 3, Ruby with Nokogiri, and Node.js, and none of them builds the book.

These guides describe the rules for the book's content and markup:

- [AGENTS.md](AGENTS.md) gives the editorial rules: sources, authority levels, the edition's decisions, and the style of the book's prose.
- [docs/status-markup.md](docs/status-markup.md) describes the markup that records the status of a rule.
- [docs/docbook-basics.md](docs/docbook-basics.md) explains the DocBook markup of a chapter for contributors who have not used DocBook.
- [docs/markup-tags.md](docs/markup-tags.md) describes the custom DocBook elements for Lojban material.
- [docs/anchors.md](docs/anchors.md) explains the anchors that keep old links working.

## Mathematics in the HTML book

HTML mathematics uses MathJax 3.2.2 from jsDelivr.
The shared HTML stylesheet fixes the version and its SHA-384 integrity hash.
Browsers need a network connection to load that script and its fonts.
The script finds its versioned font and component paths from its own URL.
The HTML archive does not include MathJax.
The separate WeasyPrint backend uses its own local dependencies.

To make sure that the downloaded script matches the integrity hash in the HTML, run:

```sh
curl -fL https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-mml-chtml.js -o /tmp/cll-mathjax.js
python3 scripts/test-html-mathjax.py /tmp/cll-mathjax.js
```

## Releases

[docs/releasing.md](docs/releasing.md) describes how to release an edition.
Each release is on the [releases page](https://github.com/int19h/cll/releases).
[CHANGELOG.md](CHANGELOG.md) records the upstream history up to CLL 1.1.

## Acknowledgements

The book gives its credits in section 1.5, "Acknowledgements and credits".
Read that section in the [published book](https://int19h.github.io/cll/), or in `chapters/01.xml` at the anchor `c1s5`.
AI models wrote this edition's new and changed text under the direction of its editor, and other AI models reviewed it.

## License

Section 1.8 of the book, "Boring legalities" (`chapters/01.xml`), gives the license of the book's text.
That license is the Logical Language Group's 1997 notice.
It permits verbatim copies, and it permits modified versions and translations under the conditions that it states.
Chapter 21 is in the public domain, except its PEG grammar section, which reproduces rules from the camxes parser under the MIT license.
The [LICENSE](LICENSE) file puts the rest of this repository under the same license as the book.
Material copied from elsewhere, such as the DocBook DTD files, keeps its own license.
