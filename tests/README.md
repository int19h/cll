# tests/ — research fixtures and probes

Reproducible artifacts backing the CLL-update research claims (issue #11).

- `fixtures/magic-word-probes.tsv` — parser probe table for magic-word,
  erasure, and tag-binding behavior, with expected accept/reject per parser
  and provenance notes. Divergences between the community spec and parsers,
  and between parsers, are marked in-line — they are findings, not bugs in
  this table. Note: the two tag-binding rows assert *acceptance only*; they
  do not prove parse shape (tree-level assertions are future work under the
  example-validation CI, issue #8).
- `fixtures/xml-prince-postprocess.xhtml` — input for the Prince
  postprocessor smoke test (`scripts/test-xml-prince-postprocess.py`), which
  runs `scripts/xml_prince_postprocess.rb` and checks all five of its
  transformations. The shapes are copied from real build output, except the
  `<book>`-rooted document element: that branch of the script no longer fires
  on the release path (see issue #112), and the fixture pins it as written.
  The literal U+00A0 between "Chapter" and "21" is required — the script's
  regex contains that character.
- `fixtures/peg-morphology-diff.md` — rule-level diff between the BPFK wiki
  PEG morphology page and ilmentufa's camxes.peg. Generated file; regenerate
  with `python3 tests/gen-peg-diff.py > tests/fixtures/peg-morphology-diff.md`
  (inputs pinned inside the file header).
- `run-probes.js` — runs the probe table against ilmentufa (required; the
  checkout must be at the pinned commit or the runner exits 2 — set
  `ALLOW_UNPINNED_ILMENTUFA=1` to override with a warning) and optionally a
  jbotci binary (invoked as `$JBOTCI_BIN gentufa <text>`). Usage:

      ILMENTUFA_DIR=~/git/ilmentufa node tests/run-probes.js
      # optional: JBOTCI_BIN=~/git/jbotci/target/release/jbotci

  Exit codes: 0 = all ilmentufa expectations match; 1 = at least one
  ilmentufa mismatch; 2 = configuration/invocation failure (bad paths, wrong
  pin, empty parser output, malformed fixture). jbotci columns: `-` rows are
  skipped entirely; rows with `A`/`R` are checked when `JBOTCI_BIN` is set,
  and mismatches are printed as INFO lines without affecting the exit code.
  A CI workflow running the ilmentufa half is tracked as issue #8.
