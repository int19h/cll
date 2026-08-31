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
- **Every PR gets a codex review** (GPT-5.6-Sol): `codex exec -m gpt-5.6-sol -c model_reasoning_effort='"xhigh"' -C <repo> - < prompt` (see AGENTS.md for the reviewer contract). Iterate to consensus; per the maintainer's mandate Claude decides when consensus is reached and has the final word if convergence fails, but any unresolved disagreement must be recorded in the PR for the maintainer's attention.
- **Review sessions are resumable (maintainer decision 2026-08-30): round 1 of each PR runs in a fresh codex session (adversarial independence); follow-up rounds resume that PR's session** — `codex exec resume <session-id> -m … -c … - < prompt`, run from the repo directory (the `resume` subcommand does not accept `-C`; the id is printed as `session id:` in the run output; sessions live under `~/.codex/sessions`). A resumed reviewer retains its own findings and can check that what it asked for was actually delivered. Caveats: its picture of the working tree is stale — every resume prompt must name the exact new HEAD and direct re-reading of the changed passages; and the `research/pr*-review-N.md` report files remain the durable consensus record regardless of session reuse.
- **Infra/scaffolding PRs** (CI, fixtures, artifacts, tooling): Claude merges after codex review.
- **Book-text PRs** (anything touching `chapters/`): iterate with codex, then leave OPEN for the maintainer. **Never self-merge text.**
- The codex CLI can hit usage limits; if an invocation fails with a quota error, retry after the stated reset time.

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
- **Release notes are the delta against our own previous release** — not against CLL 1.1 or the first edition. The first release (1.3.2) is the exception: its predecessor is upstream's UnCLL `geklojban-1.2.16`, frozen as `baseline/uncll-1.2.16`. Never credit this edition with something UnCLL already did (dotside and the classical hyphen rules are the traps). Don't rehash the change list either: the book's a03 appendix catalogues changes from the *first edition*, and the site ships a visual diff of each version against the UnCLL 1.2.16 baseline (`<version>/diff_from_uncll/`); notes summarize what a reader gains and link to both.

## Coordination (IRC)

All agent sessions on this machine (Claude PM sessions across projects, Codex workers, the owner) coordinate over a local Ergo IRC server at `127.0.0.1:6667`. **Read `~/git/agent-ops/docs/protocol.md` before first use** — it defines identity, channels, message prefixes, waiting, and durability rules. Tooling lives in `~/git/agent-ops/bin/`.

- Your role account is **`pm-cll`** (provisioned; credentials under `~/.local/state/agent-irc/pm-cll/`). Global Claude hooks already inject unread messages at turn boundaries — the role is resolved from the git top-level directory basename, so this works without setup from the canonical `~/git/cll` checkout (other checkouts such as `~/git/cll-review` resolve to unprovisioned roles and the hook silently skips them). To wait actively for a reply, run `~/git/agent-ops/bin/irc-checkmail pm-cll --wait` as a background task.
- Send: `~/git/agent-ops/bin/irc-send pm-cll '#cll' 'STATUS: ...'`.
- Channels: **`#cll`** is the project board (registered). Epic channels are `#cll-<epic>`, workitem channels `#cll-<epic>-<item>` (segments are GitHub issue numbers); register channels at creation (`CS REGISTER`) or they lose identity when emptied.
- Worker dispatch: Codex worker roles are `codex-cll-<item>` via `bin/irc-role create`. Dispatch each worker with all three `-c mcp_servers.irc.env.*` overrides (`IRCV3_MCP_CONFIG_DIR`, `IRCV3_MCP_STATE_DIR`, `IRCV3_MCP_SECRET_BACKEND` → `~/.local/state/agent-irc/<role>/…`, per `~/git/agent-ops/README.md`) and name the role and exact channel in the prompt — a prompt alone cannot switch the MCP identity.
- Messages are terse pointers with a machine-scannable prefix (`STATUS:` / `DONE:` / `ASK:` / `ANSWER:` / `ASSUMPTION:` / `HANDOFF:` / `CLAIM:` / `RELEASE:`). Anything durable (the "why") belongs in commits/PRs/issues, never only in IRC.
- Cross-project concerns that affect the whole machine (disk space, long resource-hungry runs): channels are pub/sub with no global broadcast, so a note on `#cll` reaches only roles joined there. Announce on `#cll` for the record AND on the affected project's board (e.g. `#jbotci`) so its sessions actually see it; `pm-jbotci` and the owner are reachable the same way.
- CLL specifics: codex reviews are one-shot (`codex exec`, report files in `research/`), not IRC workers — dispatch the worker protocol only for genuinely long-running workitems. Containerized book builds (podman; ~15 min for an HTML-only target, ~1h for the full build with PDF) and review fan-outs are the project's main local load; `CLAIM:`/`RELEASE:` anything beyond one concurrent build or three concurrent reviews. Pages deploys run on GitHub CI and cost nothing locally. Review prompts must direct any combined-tree/build scratch to `~/build/cll-review-scratch/` with cleanup.

## Shared machine resources (disk)

This machine is shared by many concurrent agent sessions, and `/tmp` is a **32G RAM-backed tmpfs shared by all of them**. On 2026-07-17, CLL review scratch (~25G of per-chapter checkouts and branch build trees) filled it completely, which killed ssh and most in-flight Claude sessions machine-wide. Rules:

- Multi-GB scratch (chapter checkouts, build trees, fan-out worktrees) goes under `~/build/<name>` on the container disk — NOT `/tmp` (RAM-backed) and NOT `~/git` (near-full macOS-backed share). `/tmp` is fine for small files only.
- Delete superseded scratch as soon as a round completes; never let old rounds accumulate alongside the new one.
- Before any fan-out that creates many checkouts/build dirs, check `df -h /tmp ~/build` and keep several GB of headroom on each.
- Announce unusually large temporary usage with a `CLAIM:` on `#cll` (and `RELEASE:` when freed); if it could squeeze another project's sessions, post the same `CLAIM:` on that project's board too (see the pub/sub note above).
