# CLL project guidance

This repository updates the Complete Lojban Language (CLL) to describe current Lojban. It covers documented developments since the first edition. It preserves the authority of each rule and the status of each proposal. Many readers use CLL as their first book on Lojban. This edition aims to serve as the default reference, including for jbotci.

Use the role and scope assigned for the current task. State uncertainty explicitly. Support claims with evidence. Do not reopen resolved decisions without new evidence or an instruction to reconsider them.

## Repository

The book uses DocBook 5 XML, with one file per chapter. DocBook provides markup for books and their content. The source files are in `chapters/`. Appendix `a01.xml` contains the chrestomathy, a collection of reading passages. Appendix `a03.xml` describes changes from the first edition.

Chapter 21 contains the formal grammar for word forms and syntax. PEG means parsing expression grammar. EBNF means extended Backus–Naur form. The chapter prints the PEG grammar for word forms beside the EBNF grammar for syntax. The PEG grammars for syntax stay online.

Target pull requests at `main`, the fork's development branch. Keep each issue's changes in a separate branch and pull request. Link the issue in the pull request description. Use the issue to establish the task's scope.

Do not commit to `geklojban-development`, which tracks upstream `lojban/cll`. Preserve `baseline/uncll-1.2.16`, the fixed baseline for comparisons with unCLL. That baseline contains upstream content and build fixes. Upstream's default branch, `docbook-prince`, contains the CLL 1.1 line.

## Sources and authority

Use resolved editorial decisions to determine how this edition treats a subject. Use primary sources to establish historical facts. A primary source directly records a decision, proposal, or event. Use the relevant issue to determine the scope of a change.

Prefer final decisions over older drafts and intermediate notes. Use frozen historical snapshots for rules fixed at a particular date. Do not substitute a live wiki page for an adopted snapshot. Treat parser output as evidence of implementation. Do not use it to override a rule's authority or meaning.

The Logical Language Group (LLG) is Lojban's official organization. The BPFK is the language-definition committee. Official Lojban remains frozen under this edition's authority model. Deferred proposals remain deferred unless an official body adopts them. Community use and dictionary entries do not constitute official adoption.

A checkpoint fixes a committee definition at a date.

Existential import requires the relevant class to have members.

Preserve these distinctions:

- LLG-RATIFIED means approval through an LLG vote. Only xorlo has this status among the post-CLL changes covered here. Xorlo is the reform of Lojban articles. Its history includes the 2004 checkpoint, 2007 interim adoption, and 2020 ratification.

  The ratified text is wiki revision 123823 plus two corrections. The corrections concern a `moklu` typo and the unicorn example. See issue #7 for the exact adopted text.
- BPFK-APPROVED means approval through a recorded BPFK vote. Dotside received approval on August 8, 2015. Dotside is the pause rule for Lojban name words. Tight binding of a tag to its following predicate received approval on March 15, 2016. Both decisions used the reauthorization charter.

  CGV means a consonant, glide, and vowel sequence. The CGV ban received approval on December 27, 2014, during the charter transition. That vote predates the reauthorization charter. That ban also has evidence of implementation.
- CHECKPOINTED means fixed by an early BPFK checkpoint. The authoritative texts are frozen snapshots from 2004–2005. Gadri are Lojban articles. BAI contains modal tags. The snapshots cover Letterals, Aspect, gadri, Magic Words, and six BAI sections.

  The Aspect checkpoint includes the reversal of ZAhO meanings when used as modal tags. The committee explicitly deferred `si`, `sa`, and `su`. Distance markers were outside the BAI checkpoint.
- DE-FACTO means supported by practice or implementation without official adoption. State the kind of evidence. Morphology describes how word forms are built. PEG morphology has both a working document and implementation. This includes combining forms from borrowed words. `VA`, `ZI`, `VEhA`, and `ZEhA` regularization also has a working document and implementation.

  The tested parsers implement `si` and `su` erasure. Camxes is the principal compatibility target across the surveyed tools.
- PROPOSED means a concrete proposal without adoption. The e-series attitude markers belong here. Dictionary entries reflect the proposed senses, but they do not grant official status. This edition selects the directive account on editorial grounds. The BPFK drafted and discussed that account but never completed or adopted it.
- UNSETTLED means that sources or implementations disagree without a final resolution. Subjects include `ro` existential import, `sa`, `na` scope, the comma, `lo'e`, `le'e`, `jei`, and `lo'i` of nothing. An editorial choice does not settle a dispute for the language as a whole.

Do not teach an unsettled point as settled. Label de facto material and unadopted proposals. Preserve the 2007 promise that pre-xorlo CLL usage is "not incorrect." Describe changes without branding that older usage as an error.

## Editorial decisions

Issue #1 records the resolved editorial decisions. Apply those decisions unless the current task explicitly changes them. Keep the edition's teaching choices separate from official language decisions.

Apply the following decisions:

1. Describe mainstream current Lojban with explicit status labels.
2. Teach CLL's `na` rule with a status note. A prenex is a clause prefix containing terms or operators. `na` equals `naku` at the head of the prenex. Distinguish `na pu` from `pu na`.
3. Teach `ro` with existential import. Present that requirement as projective, meaning that it survives negation. Include a status note about the non-importing alternative. See int19h/jbotci#279 for the consistency argument.
4. Treat the comma as a writing convention with no sound value.
5. Describe the intent of `sa` erasure. Mark its semantics as unsettled. State relevant differences between parsers. Do not prescribe unusual, unsupported behavior.
6. Favor modern examples when choosing between `le` and `lo`. Use fully modern examples in chapters 2 and 6. Elsewhere, retain `le` when the example specifically teaches it. Do not replace every `le` mechanically.
7. Keep the PEG grammar for word forms in chapter 21 beside the EBNF grammar. Keep the PEG grammars for syntax online. See issue #118 for this placement decision.
8. Teach classical hyphen placement as the norm. Note the broader forms that parsers accept. Acknowledge the 2019 veto.
9. Preserve the chrestomathy. Update its texts to modern rules or label them as pre-BPFK. Include at least one substantial, fully modern text.
10. Preserve chapter 21's cross-references to the EBNF grammar. Generate them from the grammar anchors during the build.
11. Represent rule status through semantic DocBook markup. Semantic markup records meaning rather than appearance. Let renderers produce margin marks or other presentation. See issue #47 for the design. Keep the sources usable by jbotci's direct DocBook renderer.
12. Put experimental features in the dialects chapter. These include the `zo'oi` family, `su'oi`/`ro'oi`, and the variants called CBM and ce-ki-tau. Keep them out of the main reference chapters. Introduce `zi'evla` in chapter 4 as this edition's term for free-form borrowings. The term means "free words."

## Book prose and examples

Assume that the reader knows no Lojban. Define each technical term at first use. Explain the relevant committee history before referring to it. Remove wording that requires knowledge of an earlier CLL edition.

Match CLL's voice: instructional, driven by examples, and lightly wry. Preserve meaning during stylistic rewrites. Do not add claims. Preserve every qualification and distinction. Keep unclear or ambiguous wording out of the book.

Use "group (traditionally called mass)" for `gunma`. Use `cmevla` for the word class of names. Choose example articles according to the editorial decisions above.

Give each changed rule a status marker. Include the change in the "Changes from the first edition" appendix. Do not claim community preferences or usage frequency without evidence that supports the exact claim.

Make sure that every Lojban example agrees with the relevant grammar and meaning. Use parser, morphology, semantics, and dictionary tools as appropriate. Investigate suspicious examples with a parser. Make sure that each gloss matches the example's meaning. Label intentionally invalid examples.

An interlinear gloss translates words beneath the example. Use that structure in DocBook examples. Preserve the IDs of examples whose content survives.

## Review and validation

Read the changed files at the exact commit under review. Do not trust your remembered picture of the tree. If the source changes, review the new commit before relying on the previous verdict.

Make sure that earlier fixes address the reported problems. Do not repeat settled review points without new evidence. Explain findings with concrete evidence and a file location or example identifier. Write explanations that readers can understand without access to the conversation.

Make sure that the change addresses every item in the issue's scope. Record evidence for items that require examination. Explain any deferred item. Flag unrelated changes.

Make sure that XML is valid. Preserve surviving example IDs, anchors, and index entries. Use the established ID forms, including `cNsM` and `cNeXdY`. Keep presentation out of semantic markup.

Review tooling changes for correctness and reproducibility. Read existing test results before repeating expensive builds. Run focused tests when they resolve a concern. Use a full build when the final change can affect the book as a whole.

State unresolved disagreements and blockers. Do not treat a launched, interrupted, or empty review as approval. Make sure that a review finishes before relying on its result. Merge only when the current task authorizes it.

## Facts that need care

Preserve the following distinctions:

- Magic Words received a checkpoint in 2005. The frozen quotation definitions include the left-to-right conflict rule. `si`, `sa`, and `su` did not receive that checkpoint. Later unified magic-word rules are a community synthesis.

  BU forms letterals, symbols used as Lojban letters. The later synthesis conflicts with the frozen BU definition in some cases. The frozen text forbids `ba'e bu`, while the later synthesis and camxes allow it. Trace each rule to its source. Do not call the later synthesis checkpointed.
- Distance markers `VA`, `ZI`, `VEhA`, and `ZEhA` were outside the 2005 BAI checkpoint.
- The ratified article definitions equate `PA broda` with `PA da poi broda`. Do not substitute `PA lo broda`.
- The 2020 article ratification covers wiki revision 123823 and the two named corrections. A live wiki page is not the ratified text.
- CLL 16.8 gives `ro` existential import. Present that import as projective under this edition's editorial decision. Jbotci's bare universal output is an implementation gap. It is not evidence that `ro` lacks import.
- Jbovlaste is read-only. Lensisku is its de facto successor. Neither dictionary's content has official status merely because it appears there.

## Builds

The full book build uses `Dockerfile` and `run_container.sh`. Prince produces the PDF. Use `./cll_build -t chapters/NN.xml` for a single chapter. Make sure that XML agrees with the definitions in `dtd/` through `xmllint`.

## Releases

The `.env` file defines the edition's branding. `TITLE` gives the title, and `VERSION` gives the version. Optional `SUBTITL` gives the subtitle. `scripts/merge.sh` puts these values on the title page. An empty `SUBTITL` produces no subtitle element.

Keep `main` at `colojban-<last release>+dev`. Before creating an `edition/X.Y.Z` branch, make sure that all branding values describe the intended release. Set that branch's `VERSION` to the release version. Do not retain an upstream title or a stale subtitle.

A release uses tag `vX.Y.Z` at the exact published commit on `edition/X.Y.Z`. The `pages` branch lists it in `pages/versions.tsv`. Each release contains `cll.pdf`, `cll.epub`, and `cll-X.Y.Z-html.tar.gz`. The archive contains the complete HTML site for that version.

Follow this release order:

1. Create the release as a draft with its notes.
2. Add the version entry to `pages/versions.tsv` on `pages`.
3. Wait for the deployment to attach the three book files to the draft.
4. Make sure that the draft contains the correct files and notes.
5. Publish the release when the current task authorizes publication.

Do not change a published release's book files. The site serves those files directly from its release assets. Only comparison pages and the landing page use current tooling. If a published release lacks a required book file, stop the deployment.

Do not move an `edition/X.Y.Z` branch after publication. The deployment uses that branch to compute comparisons. Moving it makes the comparisons disagree with the published book. Publish a new version for a correction.

Keep build caches in the draft release `site-build-cache`. Do not publish that release. The workflow input `force_rebuild` bypasses the cache.

Compare release notes with this fork's previous release. The first release, 1.3.2, instead compares with upstream `geklojban-1.2.16`, frozen as `baseline/uncll-1.2.16`. Do not claim changes that unCLL already made. Dotside and classical hyphen rules are examples of that risk.

The changes appendix compares with the first edition. Release notes summarize what readers gain from the current release. Link the relevant visual comparisons instead of repeating the appendix.

The site provides these comparisons:

- `diff_from_official/` compares with official CLL 1.1. Its source is tag `v1.1-2016-08-26-html`, commit `6c0556c7`, which matches the build published by lojban.org.
- `diff_from_uncll/` compares with the unCLL 1.2.16 baseline.
- `diff_from_previous/` compares with this fork's previous release. The site builds versions from oldest to newest. The oldest release uses the unCLL comparison here.

The comparison pages show the whole book with changes marked in place. The deployment computes those changes from DocBook sources. Keep each comparison consistent with the exact published text.
