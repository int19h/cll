# The ratified gadri text (xorlo) — provenance artifact

This directory holds the **exact text of the official description of the Lojban
gadri system** ("xorlo") as ratified by the Logical Language Group membership,
reconstructed here because no single copy of it exists in the cited wiki, its
mirror, or the project's research corpus: the vote adopted a specific wiki
revision *plus corrections*, one of which was never applied to the live wiki
page.

## Files

- `gadri-ratified-2020.wiki` — **the ratified text** (MediaWiki markup):
  revision 123823 with the voted unicorn-example correction applied
  (sha256 `21b1534f160786e5d57603218f4e112fcbf138355e1f13abfc76a67fd782af3c`).
- `revid-123823.wiki` — the unmodified wiki revision the vote was taken on,
  for diffability (sha256
  `2354f630bb859fa94b6d92f75771dfc9d0e59e7afe0f1092f680e67ab2f57f0b`).

The two files differ in exactly one line (the unicorn example, see below).

## Provenance

1. **BPFK gadri checkpoint, 2004-12-25** — the proposal (authored chiefly by
   Jorge Llambías, "xorxes"; hence the community name *xorlo*) was approved
   11–0 by the baupla fuzykamni. (That 2004 text differs from the text here in
   at least the «PA broda» rule — see note below.)
2. **LLG Annual Meeting 2007** — the membership adopted xorlo into the
   *zasni gafyfantymanri* (interim baseline): xorlo usage preferred,
   CLL-conformant usage "not incorrect".
3. **LLG Annual Meeting "2019" (Oct 2019 – May 2020), vote closed
   2020-04-18** — the membership voted (4 for, 1 against, 1 abstain) to make
   the MediaWiki version of *BPFK Section: gadri* the official description of
   the gadri material. The page's revision at the time of the vote — and its
   last revision ever since — was **oldid 123823** (2020-04-03T23:03:45Z):
   <https://mw.lojban.org/index.php?title=BPFK_Section:_gadri&oldid=123823>
4. The motion (put by Sylvain "la ilmen" Déjardin; see the
   [2019 meeting transcript](https://mw.lojban.org/papri/LLG_2019_Annual_Meeting_Transcript))
   expressly included **two corrections** to whichever version won:
   - the typo «mokla» → «moklu» — *already present in revision 123823*
     (the fix landed on the page before the vote closed; the line reads
     «lo moklu trixe»), so it required no change here;
   - the unicorn example's final clause
     «… gi lo pa jirna cu cpana lo mebri be ce'u»
     → «… gi lo mebri be ri cu se cpana lo pa jirna»
     (each «ce'u» would otherwise introduce a fresh variable, which is
     nonsense there) — **never applied to the live page**; applied in
     `gadri-ratified-2020.wiki`.

Source for the revision text: a mirror of mw.lojban.org fetched 2026-06-08
(per its snapshot manifest), whose archived revision of the page is 123823 —
i.e. the page had not changed between 2020-04-03 and the mirror fetch. The
sha256 above identifies the exact bytes independently of any mirror.

## Notes

- This artifact is the citation target for all gadri/xorlo material in the
  book. Future edits to the wiki page (should any occur) have **no** official
  standing: the vote adopted this text, not the page as a moving target.
- Historical delta worth knowing: the 2004-checkpointed text had
  «PA broda» = «PA lo broda» and allowed omitting «lo» before a lone outer
  quantifier; a 2011 page edit changed the former to «PA broda» = «PA da poi
  broda» and dropped the latter. The 2020 vote ratified the *current* text,
  i.e. the 2011 rule.
