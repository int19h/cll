# CLAUDE.md — CLL modernization project

This repo is a fork of the Complete Lojban Language (CLL) being updated to describe **current Lojban**: the documented post-CLL developments at every authority level — LLG-ratified, BPFK-approved, checkpointed, de-facto, and unsettled — with their statuses preserved, never flattened. For many readers CLL is their *first* book on Lojban; the updated edition is intended to become the default reference (and the one used by jbotci).

## Ground truth

- Book source: `chapters/*.xml` (DocBook 5), one file per chapter + `a01.xml` (chrestomathy appendix). `chapters/21.xml` is the EBNF grammar.
- Working/integration branch: **`main`** — the fork's own line of development, and the repo default. All PRs target it. `geklojban-development` tracks upstream `lojban/cll` unchanged (never commit there); `baseline/uncll-1.2.16` freezes upstream's content plus the build fixes and serves as the Pages diff baseline; `docbook-prince` is upstream's default (CLL 1.1 line).
- `research/` is **local-only** (excluded via `.git/info/exclude`): the full research corpus — `REPORT.md`, `CHANGES.md` (change catalog with per-item authority status), `cll-impact.md` + `impact/chNN.md` (passage-level chapter impact maps), `notes/`, `sources/` (wiki exports), the codex consensus record, `wikipage` (helper to read the local wiki mirror at `~/git/lojban-wiki`). The GitHub issues are self-contained copies of the work items (chapter issues embed their impact tables).
- Related local checkouts: `~/git/jbotci` (companion toolchain; READ-ONLY for code, use its tools freely), `~/git/ilmentufa` (camxes reference parsers), `~/git/cll.v0` (abandoned prior attempt: reuse build/DocBook fixes only, NEVER its wording).

## Authority model (memorize; full detail in research/CHANGES.md §0)

Official Lojban is **frozen**: the LLG is effectively non-functional (last meeting on record: 2022; its minutes still pending approval; no later activity found). Everything BPFK deferred remains deferred absent an institutional revival; the language now evolves decentrally, chiefly via dictionary submissions (jbovlaste is read-only; **lensisku**.lojban.org is its de facto successor editing platform/app, with no authorization act on record). Status levels used throughout the project:

- **LLG-RATIFIED** — only xorlo (2004 checkpoint → 2007 interim-baseline adoption → 2020 vote on gadri page revid 123823 + two corrections; the exactly-ratified text is `official/` artifact, see issue #7).
- **BPFK-APPROVED** — dotside (2015-08-08) and tag+selbri tight binding (2016-03-15) under the reauthorization charter; the CGV ban (2014-12-27) is a 2014–15 transition vote (charter basis predates reauthorization) + DE-FACTO(implemented).
- **CHECKPOINTED** (era-1 BPFK, 2004–05; the frozen "as of" wiki snapshots are authoritative, live pages have drifted) — Letterals, Aspect (incl. ZAhO-as-sumtcita reversal), gadri, Magic Words (SI/SA/SU explicitly deferred), BAI (exactly six BAI sections; Distance/VA-ZI was NOT checkpointed).
- **DE-FACTO** (always state the evidence class) — PEG morphology incl. fu'ivla rafsi: working-document + implemented; VA/ZI(+VEhA/ZEhA) regularization: working-document + implemented; SI/SU erasure semantics: implemented in the tested parsers; camxes grammar: principal compatibility target across surveyed tooling.
- **PROPOSED / UNSETTLED** — e-series attitudinals (proposed, lexicographically adopted; teaching the modern senses is an editorial selection conditional on the open usage check); ro existential import (community-disputed; the *editorial* rule is resolved: importing-projective, see decision 3); SA semantics (parsers diverge); NA scope; comma; lo'e/le'e; jei; lo'i-of-nothing.

The ZG (2007) promise stands: pre-xorlo CLL usage is "not incorrect" — describe changes, don't brand old usage as error.

## Editorial decisions (ALL RESOLVED — issue #1 closing comment; do not re-litigate)

1. Stance: **(b)** describe mainstream current Lojban with explicit status labels.
2. NA: teach CLL's rule (na ≡ naku at prenex head) + status note; «na pu» ≠ «pu na» (now distinguished).
3. ro: **importing, presented as projective** (survives negation) — per int19h/jbotci#279's consistency proof; status note on the non-importing alternative.
4. Comma: purely orthographic/non-phonemic.
5. SA: describe intent; mark unsettled; parser-behavior notes; no normative exotica.
6. le→lo examples: chapter-by-chapter judgment with a modernizing bias — ch. 2 and 6 fully modern; elsewhere modernize unless an example specifically illustrates «le», which then keeps it.
7. PEG morphology printed as an appendix; syntax grammars stay online.
8. Hyphens: classical placement rules as the norm + note on liberal parser acceptance (2019 veto acknowledged).
9. Chrestomathy preserved; texts updated to modern rules or explicitly labeled pre-BPFK; ≥1 good-sized fully modern text required.
10. Ch. 21 EBNF cross-reference restored (regenerated against EBNF anchors, build-time-generated).
11. Status marking: **margin marks** rendered from **abstract semantic DocBook markup** (design: issue #47); jbotci cukta renders DocBook directly — never bake in presentation.
12. Popular experimental features (zo'oi family, su'oi/ro'oi, CBM, ce-ki-tau) go in the NEW dialects chapter (epic #46), never in main reference chapters. zi'evla is widely used community terminology (adopted by this edition) — introduce it properly (ch. 4).

## Workflow

- One branch + PR per issue; PR body references the issue; PRs target `main`.
- **Every PR gets an adversarial Codex review** (GPT-5.6-Sol; see AGENTS.md for the reviewer contract) in Herdr Collab project `cll`. Launch round 1 as a fresh visible agent session with `herdr-collab --project cll agent spawn ...`, assign the exact base/head and report path with durable `herdr-collab --project cll send ...`, and use the initial/direct prompt only to tell the reviewer to read that message. Iterate to consensus; per the maintainer's mandate Claude decides when consensus is reached and has the final word if convergence fails, but any unresolved disagreement must be recorded in the PR for the maintainer's attention.
- **Review sessions are resumable (maintainer decision 2026-08-30): round 1 of each PR is fresh for adversarial independence; follow-up rounds resume that PR's Herdr Collab session.** Send a durable `herdr-collab --project cll reply MESSAGE_ID ...` naming the exact successor HEAD and new report path, use `herdr-collab --project cll agent resume SESSION` if the native session is not live, then use `herdr-collab --project cll agent prompt --to SESSION ...` as a transient wake-up. A resumed reviewer retains its own findings, but its picture of the tree may be stale: every round must direct it to reread the changed passages at the named HEAD. Compact only immediately before an anticipated long pause while native context is likely cached, after persisting the handoff; then verify with `herdr-collab --project cll session show "$HERDR_COLLAB_SESSION" --live`. If a later cache-expired dialog offers continuation choices, continue the full existing native conversation by default and do not compact then. Durable reports and mail are recovery only when native context is unavailable. The `research/pr*-review-N.md` report files remain the durable consensus record regardless of session reuse.
- **Infra/scaffolding PRs** (CI, fixtures, artifacts, tooling): Claude merges after codex review.
- **Book-text PRs** (anything touching `chapters/`): iterate with codex, then leave OPEN for the maintainer. **Never self-merge text.**
- Native reviewer sessions can hit usage limits. Confirm the actual state with `herdr-collab --project cll session show SESSION --live`, preserve the blocker durably, and resume after the stated reset time rather than treating an empty or interrupted prompt as a review verdict.

## Writing rules (book text)

- Readers know nothing: introduce every term (gadri, xorlo, cmevla, zi'evla, distributive/collective, constant vs quantified term…) at first use. No casual references to BPFK-lore.
- Match CLL's voice: didactic, example-driven, lightly wry. Examples use interlinear-gloss DocBook structure; keep example IDs stable where content survives.
- Terminology: "group (traditionally called mass)" for gunma; cmevla for the word class; example gadri per decision 6 (modernizing bias, not a mechanical le→lo swap).
- Every changed rule carries a status marker (decision 11) and feeds the "Changes from the first edition" appendix.
- Verify every Lojban example: jbotci MCP tools (`gentufa` parse, `vlasei` morphology, `tersmu` semantics, `vlacku` dictionary) or `~/git/ilmentufa/run_camxes.js`. Intentionally-ill-formed examples must be annotated as such (CI allowlist).
- Per-chapter guidance lives in the chapter's GitHub issue (impact table with section anchors, quotes, and REWRITE/ADJUST/VERIFY/ADD/NOTE actions).

## Build

Full book build is containerized (`Dockerfile`, `run_container.sh`; Prince for PDF) and slow (~1h). Single-chapter test: `./cll_build -t chapters/NN.xml`. Native-Ubuntu setup notes: `~/git/cll.v0/README-UBUNTU.md`. XML validity: `xmllint` against `dtd/`.

## Releases

- Branding lives in `.env` (`TITLE`, `VERSION`, optional `SUBTITL`, read by `scripts/merge.sh` into the book's title page; the subtitle element is emitted only when `SUBTITL` is non-empty — the UnCLL leftover «Chrestomathy included» was removed before 1.3.3). `main` carries `colojban-<last release>+dev`; **cutting an `edition/X.Y.Z` branch means verifying the whole `.env` block and setting `VERSION` there** — forgetting `TITLE` reverted the book to UnCLL's on 1.3.1 and 1.3.2, and the stale subtitle survived through 1.3.2.
- A release is a GitHub release tagged `vX.Y.Z` pointing at the `edition/X.Y.Z` tip (the exact published tree), plus a `pages/versions.tsv` entry.
- **Release notes are the delta against our own previous release** — not against CLL 1.1 or the first edition. The first release (1.3.2) is the exception: its predecessor is upstream's UnCLL `geklojban-1.2.16`, frozen as `baseline/uncll-1.2.16`. Never credit this edition with something UnCLL already did (dotside and the classical hyphen rules are the traps). Don't rehash the change list either: the book's a03 appendix catalogues changes from the *first edition*, and the site ships three visual diffs per version — vs the official CLL 1.1 (`diff_from_official/`, old side = the checked-in `official/cll_v1.1_xhtml-no-chunks` tree), vs the UnCLL 1.2.16 baseline (`diff_from_uncll/`), and vs the previous release (`diff_from_previous/`; the site builds versions oldest-first so each can diff against its predecessor, and the oldest mirrors the UnCLL diff); notes summarize what a reader gains and link to them.

## Coordination (Herdr Collab)

Use Herdr Collab project **`cll`** for every coordinated CLL session. Select it
explicitly with `herdr-collab --project cll ...` or
`HERDR_COLLAB_PROJECT=cll`. The cwd, repository basename, checkout, and
worktree never select a project or mailbox; use only the session named by
`HERDR_COLLAB_SESSION` or an explicit `--session`.

Herdr Collab provides durable identity and mail but does not enforce a PM
hierarchy. Choose participants, groups, and duties for the issue: a chapter PR
usually needs an editorial implementer and an independent Codex reviewer,
while a cross-chapter or tooling change may need research, implementation, and
specialist review sessions. Record the issue/PR, roster, review order, write
boundaries, and completion conditions in the task brief. GitHub issues remain
the durable public scope; Herdr Collab is the durable coordination thread.

- A session started through `herdr-collab --project cll agent spawn ...` is
  already registered and receives
  `HERDR_COLLAB_PROJECT` and `HERDR_COLLAB_SESSION`; do not join it again. A
  manually launched session uses
  `herdr-collab --project cll session join --agent-kind KIND HANDLE`
  exactly once and then retains that explicit handle. Check
  `herdr-collab --project cll session list --live` or
  `herdr-collab --project cll session show SESSION --live` when identity/
  liveness is uncertain; never derive it from the worktree.
- Use `herdr-collab --project cll send ...` for assignments, authority/source
  decisions, blockers, and questions
  requiring an answer, handoffs, exact-commit review requests, verdicts,
  resource claims/releases, and completion. Use
  `herdr-collab --project cll reply MESSAGE_ID ...` to preserve ancestry.
  Inspect a selected immutable message with
  `herdr-collab --project cll show MESSAGE_ID`; use
  `herdr-collab --project cll --json show MESSAGE_ID` for its complete record
  and follow referenced message IDs explicitly. Use
  `herdr-collab --project cll ack --disposition DISPOSITION MESSAGE_ID` when a
  read disposition is required. An acknowledgement is not agreement.
- `herdr-collab --project cll agent prompt --to SESSION ...` is transient
  wake-up/context, never the sole copy of a load-bearing instruction or answer.
  Check `herdr-collab --project cll status` and
  `herdr-collab --project cll inbox` after joining, before new work, around
  handoffs/review rounds, and before completion or
  `herdr-collab --project cll session retire SESSION`. Use
  `herdr-collab --project cll wait --timeout DURATION` only when work genuinely
  depends on later mail; do not busy-poll. Never edit collaboration state
  manually.
- Never auto-answer trust, permission, approval, or unrelated prompts on behalf
  of another session or the user. Surface them to the person or session with
  authority to decide.
- Reviewers write only their assigned `research/<item>-review-<round>.md` path.
  Implementers get a dedicated branch/worktree and explicit source boundary;
  do not let sessions edit the same worktree concurrently. Findings go back to
  the implementer, and every changed commit receives a new exact-head review.
- Compact only immediately before an anticipated long pause, while the native
  conversation and prompt cache are still likely available, and only after
  durably sending the issue/PR, branch/worktree, exact HEAD, report path,
  decisions and sources consulted, completed/pending checks, open findings,
  blockers, and relevant message IDs. After the requested compaction, verify
  with `herdr-collab --project cll session show "$HERDR_COLLAB_SESSION" --live`.
  If a later cache-expired
  dialog offers continuation choices, default to continuing the full existing
  native conversation and do not compact then. Durable issues, PRs, reports,
  and mail are recovery only if native context is actually unavailable, not a
  replacement for it.
- `@all` and named groups are project-local. Use CLL `@all` only for information
  relevant to every active CLL participant. If a disk/build warning affects
  another project, send a separate message under that project's explicit
  `--project` namespace; CLL `@all` does not reach it.

Containerized book builds (podman; ~15 minutes for an HTML-only target and ~1
hour for the full PDF build) and review fan-outs are the principal local load.
Send durable claim/release notices to the affected task group, or CLL `@all`
when every CLL session is affected, for anything beyond one concurrent build or
three concurrent reviews. Pages deployments run in GitHub CI and cost nothing
locally. Review prompts must put combined-tree/build scratch under
`~/build/cll-review-scratch/` and require cleanup. Read existing verification
evidence before rerunning work; arrange a full heavy build once on the final
candidate when the changes can affect it.

## Shared machine resources (disk)

This machine is shared by many concurrent agent sessions, and `/tmp` is a **32G RAM-backed tmpfs shared by all of them**. On 2026-07-17, CLL review scratch (~25G of per-chapter checkouts and branch build trees) filled it completely, which killed ssh and most in-flight Claude sessions machine-wide. Rules:

- Multi-GB scratch (chapter checkouts, build trees, fan-out worktrees) goes under `~/build/<name>` on the container disk — NOT `/tmp` (RAM-backed) and NOT `~/git` (near-full macOS-backed share). `/tmp` is fine for small files only.
- Delete superseded scratch as soon as a round completes; never let old rounds accumulate alongside the new one.
- Before any fan-out that creates many checkouts/build dirs, check `df -h /tmp ~/build` and keep several GB of headroom on each.
- Announce unusually large temporary usage with a durable claim message to the affected CLL group (and a release reply when freed). If it could squeeze another project's sessions, send the warning separately in every affected Herdr Collab project; `@all` is project-local.
