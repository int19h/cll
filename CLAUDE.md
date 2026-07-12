# CLAUDE.md — CLL modernization project

This repo is a fork of the Complete Lojban Language (CLL) being updated to describe **current Lojban** — the language as it exists after all post-1997 BPFK/LLG changes (xorlo, PEG morphology, magic words, and the rest). For many readers CLL is their *first* book on Lojban; the updated edition is intended to become the default reference (and the one used by jbotci). Do not half-ass anything.

## Ground truth

- Book source: `chapters/*.xml` (DocBook 5), one file per chapter + `a01.xml` (chrestomathy appendix). `chapters/21.xml` is the EBNF grammar.
- Working/integration branch: **`geklojban-development`** (300+ commits ahead of `docbook-prince`). All PRs target it.
- `research/` is **local-only** (excluded via `.git/info/exclude`): the full research corpus — `REPORT.md`, `CHANGES.md` (change catalog with per-item authority status), `cll-impact.md` + `impact/chNN.md` (passage-level chapter impact maps), `notes/`, `sources/` (wiki exports), the codex consensus record, `wikipage` (helper to read the local wiki mirror at `~/git/lojban-wiki`). GitHub issues #1–#47 are self-contained copies of the work items.
- Related local checkouts: `~/git/jbotci` (companion toolchain; READ-ONLY for code, use its tools freely), `~/git/ilmentufa` (camxes reference parsers), `~/git/cll.v0` (abandoned prior attempt: reuse build/DocBook fixes only, NEVER its wording).

## Authority model (memorize; full detail in research/CHANGES.md §0)

Official Lojban is **frozen**: the LLG is defunct (last meeting on record: 2022; minutes still pending approval). Everything BPFK deferred stays deferred; the language now evolves decentrally (dictionary submissions — jbovlaste is read-only, lensisku.lojban.org is the de facto dictionary). Status levels used throughout the project:

- **LLG-RATIFIED** — only xorlo (2004 checkpoint → 2007 interim-baseline adoption → 2020 vote on gadri page revid 123823 + two corrections; the exactly-ratified text is `official/` artifact, see issue #7).
- **BPFK-APPROVED** — CGV ban (2014-12-27), dotside (2015-08-08), tag+selbri tight binding (2016-03-15).
- **CHECKPOINTED** (era-1 BPFK, 2004–05; the frozen "as of" wiki snapshots are authoritative, live pages have drifted) — Letterals, Aspect (incl. ZAhO-as-sumtcita reversal), gadri, Magic Words (SI/SA/SU explicitly deferred), BAI (exactly six BAI sections; Distance/VA-ZI was NOT checkpointed).
- **DE-FACTO** (always state evidence class: implemented / usage / working-document) — PEG morphology incl. fu'ivla rafsi, VA/ZI(+VEhA/ZEhA) regularization, SI/SU erasure semantics, e-series attitudinals, camxes as compatibility target.
- **UNSETTLED** — SA semantics (parsers diverge), NA scope, comma, lo'e/le'e, jei, lo'i-of-nothing.

The ZG (2007) promise stands: pre-xorlo CLL usage is "not incorrect" — describe changes, don't brand old usage as error.

## Editorial decisions (ALL RESOLVED — issue #1 closing comment; do not re-litigate)

1. Stance: **(b)** describe mainstream current Lojban with explicit status labels.
2. NA: teach CLL's rule (na ≡ naku at prenex head) + status note; «na pu» ≠ «pu na» (now distinguished).
3. ro: **importing, presented as projective** (survives negation) — per int19h/jbotci#279's consistency proof; status note on the non-importing alternative.
4. Comma: purely orthographic/non-phonemic.
5. SA: describe intent; mark unsettled; parser-behavior notes; no normative exotica.
6. le→lo: chapter-by-chapter judgment with modernizing bias (ch. 2 and 6 fully modern).
7. PEG morphology printed as an appendix; syntax grammars stay online.
8. Hyphens: classical placement rules as the norm + note on liberal parser acceptance (2019 veto acknowledged).
9. Chrestomathy preserved; texts updated to modern rules or explicitly labeled pre-BPFK; ≥1 good-sized fully modern text required.
10. Ch. 21 EBNF cross-reference restored (regenerated against EBNF anchors, build-time-generated).
11. Status marking: **margin marks** rendered from **abstract semantic DocBook markup** (design: issue #47); jbotci cukta renders DocBook directly — never bake in presentation.
12. Popular experimental features (zo'oi family, su'oi/ro'oi, CBM, ce-ki-tau) go in the NEW dialects chapter (epic #46), never in main reference chapters. zi'evla is standard terminology — introduce it properly (ch. 4).

## Workflow

- One branch + PR per issue; PR body references the issue; PRs target `geklojban-development`.
- **Every PR gets a codex review** (GPT-5.6-Sol): `codex exec -m gpt-5.6-sol -c model_reasoning_effort='"xhigh"' -C <repo> - < prompt` (see AGENTS.md for the reviewer contract). Iterate to consensus; Claude has the final word on disagreements.
- **Infra/scaffolding PRs** (CI, fixtures, artifacts, tooling): Claude merges after codex review.
- **Book-text PRs** (anything touching `chapters/`): iterate with codex, then leave OPEN for the maintainer. **Never self-merge text.**
- Codex usage quota exhausts occasionally (~hourly reset); schedule around it.

## Writing rules (book text)

- Readers know nothing: introduce every term (gadri, xorlo, cmevla, zi'evla, distributive/collective, constant vs quantified term…) at first use. No casual references to BPFK-lore.
- Match CLL's voice: didactic, example-driven, lightly wry. Examples use interlinear-gloss DocBook structure; keep example IDs stable where content survives.
- Terminology: "group (traditionally called mass)" for gunma; cmevla for the word class; lo is the default article in examples per decision 6.
- Every changed rule carries a status marker (decision 11) and feeds the "Changes from the first edition" appendix.
- Verify every Lojban example: jbotci MCP tools (`gentufa` parse, `vlasei` morphology, `tersmu` semantics, `vlacku` dictionary) or `~/git/ilmentufa/run_camxes.js`. Intentionally-ill-formed examples must be annotated as such (CI allowlist).
- Per-chapter guidance lives in the chapter's GitHub issue (impact table with section anchors, quotes, and REWRITE/ADJUST/VERIFY/ADD/NOTE actions).

## Build

Full book build is containerized (`Dockerfile`, `run_container.sh`; Prince for PDF) and slow (~1h). Single-chapter test: `./cll_build -t chapters/NN.xml`. Native-Ubuntu setup notes: `~/git/cll.v0/README-UBUNTU.md`. XML validity: `xmllint` against `dtd/`.
