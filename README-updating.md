# Releasing this edition

This guide describes releases from the `int19h/cll` fork.
[AGENTS.md](AGENTS.md#releases) defines the release rules.
The format selection and prerelease rules require PRs #157 and #158 before use.
A prerelease is a version before its final release.

A release needs separate authorization to publish.
Do not publish a release until the current task authorizes publication.
Use separate worktrees for the edition branch and the `pages` branch.

## Prepare the edition

Start from the reviewed commit on `main`.
Make sure that the relevant tests and a full local build pass.
Read the generated book in every format selected for the release.

Before creating an edition branch, make sure that `.env` describes the intended release.
`TITLE` names the book, and `VERSION` names the edition.
Optional `SUBTITL` supplies a subtitle.
An empty `SUBTITL` produces no subtitle element.
Make sure that the title and subtitle contain no stale upstream branding.

Create `edition/<version>` at the intended release commit.
Set its `.env` value for `VERSION` to `colojban-<version>`.
Commit that change on the edition branch.
Keep `main` at `colojban-<last release>+dev`.
The last release includes prereleases.
After `1.3.6-rc1`, use `colojban-1.3.6-rc1+dev` on `main`.

For example, `1.3.6-rc1` uses branch `edition/1.3.6-rc1` and tag `v1.3.6-rc1`.
The final `1.3.6` release uses its own `edition/1.3.6` branch and `v1.3.6` tag.
Never reuse a prerelease branch for the final release.
The first release in the 1.3.6 series is `1.3.6-rc1`.

## Write the release notes

Compare the edition with this fork's previous final release.
Skip prereleases when choosing that release.
For the first fork release, 1.3.2, use `baseline/uncll-1.2.16` instead.
That branch freezes upstream `geklojban-1.2.16`.

Describe what readers gain from this release.
Do not claim changes that unCLL already contains, such as dotside or classical hyphen rules.
The changes appendix compares with the first edition and serves a different purpose.
Link the visual comparisons instead of repeating the appendix.

The site provides three comparisons:

- `diff_from_official/` compares with official CLL 1.1, tag `v1.1-2016-08-26-html`, commit `6c0556c7`.
- `diff_from_uncll/` compares with `baseline/uncll-1.2.16`.
- `diff_from_previous/` compares with the previous final release and skips prereleases.

The oldest release uses the unCLL comparison for `diff_from_previous/`.
The site computes these comparisons from DocBook sources at the edition commits.
Each comparison must agree with the exact published book.

## Create the draft

Push only the intended edition branch and its tag to `origin`.
Make sure that `v<version>` points to the exact edition commit.
Create a draft release at that tag with the reviewed notes.
For a release candidate, mark the GitHub release as a prerelease too.

In the separate `pages` worktree, add a row to `pages/versions.tsv`.
The first column contains the version, and the second contains `edition/<version>`.
The optional third column contains formats separated by commas.
An empty or missing third column selects `html,epub,pdf`.

The formats select these files:

- `html` selects `cll-<version>-html.tar.gz`, the online book, and its comparison pages.
- `epub` selects `cll.epub`.
- `pdf` selects Prince's `cll.pdf`.
- `pdf-weasyprint` selects `cll-weasyprint.pdf`.
- `pdf-typst` selects `cll-typst.pdf`.
- `pdf-context` selects `cll-context.pdf`.

Any combination works.
Comparison pages require `html` because they use the online book's assets.
Use `html,epub,pdf,pdf-weasyprint` for both `1.3.6-rc1` and the final `1.3.6` release.
Typst and ConTeXt need more work before publication.

This example row contains tab characters between columns:

```text
1.3.6-rc1	edition/1.3.6-rc1	html,epub,pdf,pdf-weasyprint
```

Commit the version entry on `pages`.
Push that branch only when the current task authorizes a deployment.
The push starts the Pages deployment, which attaches the selected files to the draft.
Wait until the deployment finishes.

## Review and publish

Make sure that the draft contains exactly the files selected by its format column.
Make sure that the HTML archive contains the complete site for that version.
Read the attached books and the release notes.
Make sure that the tag, edition branch, branding, and comparisons agree.

While a Pages deployment runs, do not publish a release.
The pipeline reads the draft state before each group of release changes.
That read does not lock the release.
After the deployment finishes, publish only with explicit authorization for publication.

The site builds prereleases but omits them from the top-level landing page.
Readers reach prereleases through their GitHub release links.
`/latest/` selects the newest final release.
If no final release exists, the site provides no `/latest/` redirect.

## Preserve published releases

Do not replace or change a published release's book files.
The site serves those files directly from the release assets.
Only comparison pages and the landing page use current tooling.
If a published release contains missing or extra files, stop the deployment.

Keep its format column unchanged after publication.
Do not move its edition branch or tag.
The deployment uses the edition branch to compute comparisons.
Publish a new version for a correction.

Keep build caches in the draft release `site-build-cache`.
Do not publish that release.
The workflow input `force_rebuild` bypasses the cache.
It does not permit changes to published book files.

## Historical upstream tools

`scripts/update_official` maintains the old `official/` output and creates upstream date-based tags.
`scripts/tar_official` packages that output for the historical lojban.org publication process.
These scripts remain available for work on historical upstream outputs.
This fork publishes through edition branches, version tags, draft releases, and the Pages deployment described above.
