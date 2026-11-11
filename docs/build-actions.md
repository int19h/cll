# Build a branch on GitHub

The **Build selected formats** workflow builds the branch that you select.
It does not publish a release or change release files.
The workflow file must exist on the repository's default branch before GitHub shows the manual run button.
On a fork, enable Actions first.

1. Open the repository's **Actions** tab.
2. Select **Build selected formats**, then **Run workflow**.
3. Select your branch and the formats that you need.
4. Select **Run workflow** and wait for the build to finish.
5. Open the run page and download the files under **Artifacts**.

Select at least one format. Each format has a separate artifact named `cll-<format>`.
GitHub wraps each artifact in a ZIP file.
The run summary lists the artifacts and links to the run page.

The `html` artifact contains `xhtml_section_chunks/`, `xhtml_no_chunks/`, a landing page, and `cll-<version>-html.tar.gz`.
Extract the ZIP file and open `index.html` to read the book.
The version in the archive name includes the source commit for a development build.
The other artifacts contain only their selected file:

| Input | File |
| --- | --- |
| `epub` | `cll.epub` |
| `pdf` | `cll.pdf` (Prince) |
| `pdf-weasyprint` | `cll-weasyprint.pdf` |
| `pdf-typst` | `cll-typst.pdf` |
| `pdf-context` | `cll-context.pdf` |

Typst and ConTeXt remain experimental PDF backends. See their build guides for limitations.
The workflow uses the native installation steps from the release-site workflow on `pages`.
It installs Prince 16.2 only for `pdf`, and Java only for EPUB validation.
WeasyPrint and Typst use the branch's pinned installers. ConTeXt uses the branch's container launcher.
Native system packages can change with the runner image. See [build-pins.md](build-pins.md) for container dependency pins.

## HTML preview

The `preview` checkbox defaults to selected. It requires `html`.
Without `html`, the workflow skips the preview and explains why in the summary.
The downloadable HTML artifact remains available when the workflow skips deployment.

A Pages deployment replaces the repository's entire Pages site.
The workflow reads the repository's live `pages` branch before it permits a preview.
If that branch contains `pages/versions.tsv`, the workflow skips the preview to protect the published book site.
This guard protects `int19h/cll` before the deployment job requests approval from the `github-pages` environment.
A failed branch lookup stops the job and blocks deployment.

Repository administrators can set the Actions repository variable `BUILD_PAGES_PREVIEW`:

| Value | Behavior |
| --- | --- |
| Unset or `auto` | Skip when `pages` contains `pages/versions.tsv`. Allow otherwise. |
| `deny` | Always skip preview deployment. |
| `allow` | Override detection and permit replacement of the Pages site. |

Use `allow` only after establishing that the site can be replaced.
Invalid values fail the guard.
The variable never selects the `preview` or `html` inputs for you.

For an allowed preview, select **GitHub Actions** as the Pages publishing source in repository settings.
The workflow uses the `github-pages` environment and its approval rules.
The deployment job serializes previews so that two preview deployments cannot run together.
After deployment, its summary links to the preview.
The workflow does not create a repository or change Pages settings.
