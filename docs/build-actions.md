# Build a branch on GitHub

The **Build selected formats** workflow builds the branch that you select.
It does not publish a release or change release files.
The workflow must exist on the repository's default branch before GitHub shows the manual run button.
The selected branch must also contain this workflow and its scripts.
Update an older feature branch from `main` first.
Older branches, edition branches, and tags without those files cannot use this workflow.

1. On a fork, open **Actions** and enable workflows.
2. Select **Build selected formats**, then **Run workflow**.
3. Select your branch and the formats that you need.
4. Select **Run workflow** and wait for the build to finish.
5. Open the run page and download the files under **Artifacts**.

Select at least one format. Each format has a separate artifact named `cll-<format>`.
GitHub wraps each artifact in a ZIP file. Artifacts expire after 14 days.
The run summary lists successful artifacts and failed formats, with a link to the run page.
If a format fails, the workflow still builds and uploads the other selected formats.
The job fails at the end if any selected format failed. A failed build does not deploy a preview.

The `html` artifact contains `xhtml_section_chunks/`, `xhtml_no_chunks/`, and a landing page.
It contains no separate tar archive. The preview uses these same files.
Extract the ZIP file and open `index.html` to read the book.
The landing page identifies the version and full source commit.
Its links name `index.html` explicitly, so they also work from a downloaded copy.
The other artifacts contain only their selected file:

| Input | File |
| --- | --- |
| `epub` | `cll.epub` |
| `pdf` | `cll.pdf` (Prince) |
| `pdf-weasyprint` | `cll-weasyprint.pdf` |
| `pdf-typst` | `cll-typst.pdf` |
| `pdf-context` | `cll-context.pdf` |

HTML takes about 31 minutes. All six formats together take about 83 minutes.
These are measured examples, not time guarantees. The build job has a 150-minute limit.
The deployment job has a 10-minute limit once it starts. Environment approval can add a wait before it starts.

Typst and ConTeXt remain experimental PDF backends. See their build guides for limitations.
The workflow copies the setup block from the release-site workflow on `pages`.
It installs Prince 16.2 only for `pdf`, and checks the package against the Dockerfile's SHA-256 hash.
It installs Java only for EPUB validation.
WeasyPrint and Typst use the branch's pinned installers. ConTeXt uses the branch's container launcher.
Native system packages can change with the runner image. See [build-pins.md](build-pins.md) for container dependency pins.

## Set up a preview in a fork

The `preview` checkbox defaults to selected. It requires `html`.
Without `html`, the workflow skips the preview and explains why in the summary.
Artifacts remain available when the workflow skips deployment.

1. When creating the fork, leave **Copy the main branch only** selected. This is GitHub's default.
2. Open **Actions** and enable workflows in the fork.
3. Open **Settings > Pages**. Set **Build and deployment > Source** to **GitHub Actions**.
4. Open **Settings > Environments > github-pages**.
5. Under **Deployment branches and tags**, allow the branch that you want to preview.
6. Run the workflow on that branch with `html` and `preview` selected.

The Pages environment normally permits only the default branch at first.
Add your feature branch, or choose a rule that permits your preview branches.
Keep any required reviewer rules that your repository needs.
The workflow does not inspect these branch rules: the API requires additional Actions read permission.
See GitHub's [environment API permissions](https://docs.github.com/en/rest/deployments/environments#get-an-environment).
A branch that the environment rejects cannot deploy, even if the preview guard permits it.

If your fork copied all branches, its copied `pages` branch also blocks previews.
If the fork publishes no release site, delete that copied `pages` branch in the fork before requesting a preview.
Do not delete the `pages` branch of a repository that publishes the book site.

## Preview protection

A Pages deployment replaces the repository's entire Pages site.
Before building, the workflow uses its job token to read the live repository and Pages configuration.
It skips the preview if Pages is disabled or its source is not GitHub Actions.
The readiness lookup uses `pages: read`, the [documented permission](https://docs.github.com/en/rest/pages/pages#get-a-github-pages-site).
It also reads the live `pages` branch and checks that branch's exact commit for `pages/versions.tsv`.
If the marker exists, the workflow always skips preview deployment to protect the published book site.
This guard protects `int19h/cll` before the deployment job requests environment approval.

The deployment job repeats these checks after environment approval, immediately before `deploy-pages`.
That check runs inline with the job token. It does not check out or run branch code.
A new release marker, disabled Pages site, or changed Pages source stops the preview at this late check.

Repository administrators can set the Actions repository variable `BUILD_PAGES_PREVIEW` to `deny` to disable previews.
Unset or `auto` uses the checks above. These are the only accepted values.
There is no override for a release manifest or a failed lookup.
An invalid value or failed lookup stops the job with an error. Clear `preview` to build artifacts without running the guard.
Authenticated API requests support private repositories too.

Preview deployments serialize with other previews in the `book-pages-preview` concurrency group.
They do not share the release workflow's `pages` group, whose cancellation policy can cancel a pending release deployment.
A small race remains between the late API check and the deployment request.
For example, a release site can be configured in that interval.
Do not establish or publish a release site while a preview deploy is pending or running.
Set `BUILD_PAGES_PREVIEW=deny`, and cancel pending previews, before establishing the release site.

After a successful deployment, its summary links to the preview.
The workflow does not create a repository or change Pages settings.
