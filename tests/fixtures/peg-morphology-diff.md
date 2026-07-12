# PEG morphology: wiki page vs ilmentufa camxes.peg

Rule-level comparison (normalized: '-'→'_', whitespace collapsed), joined on rule name.

- Wiki page: BPFK Section: PEG Morphology Algorithm (mirror snapshot 2025-12; page last edited 2025-01).
- ilmentufa: camxes.peg @ 778ea138f7d150121ca722db7536ce3b123943ac (morphology section).

Rules present in both with differing bodies:

```
RULE: brivla
  wiki:  gismu / fuhivla / lujvo
  ilmen: !cmavo initial_rafsi* brivla_core

RULE: cmavo
  wiki:  !cmene !CVCy_lujvo cmavo_form &post_word
  ilmen: !cmevla !CVCy_lujvo cmavo_form &post_word

RULE: final_syllable
  wiki:  onset !y !stressed nucleus !cmene &post_word
  ilmen: onset !y !stressed nucleus !cmevla &post_word

RULE: jbocme
  wiki:  &zifcme (any_syllable / digit)* &pause
  ilmen: &zifcme (any_syllable / digit)+ &pause

RULE: lojban_word
  wiki:  cmene / cmavo / brivla
  ilmen: CMEVLA / CMAVO / BRIVLA

RULE: stress
  wiki:  consonant* h? y? syllable pause
  ilmen: (consonant / glide)* h? y? syllable pause

RULE: stressed_fuhivla_rafsi
  wiki:  fuhivla_head stressed_syllable !h onset y
  ilmen: fuhivla_head stressed_syllable consonantal_syllable* !h onset y

RULE: y
  wiki:  comma* [yY]
  ilmen: comma* [yY] !(!y nucleus)

```

Assessment (from the CLL-update research, consensus-reviewed): naming (cmene→cmevla), a jbocme bugfix (`*`→`+`), glide-aware `stress`, consonantal syllables allowed in `stressed_fuhivla_rafsi`, a `y` lookahead fix, and a brivla-rule refactor — substantively the same morphology. Both incorporate the CGV ban (`onset <- h / glide / initial`) and dotside.
