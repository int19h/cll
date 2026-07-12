# tests/ — research fixtures and probes

Reproducible artifacts backing the CLL-update research claims (issue #11).

- `fixtures/magic-word-probes.tsv` — parser probe table for magic-word,
  erasure, and tag-binding behavior, with expected accept/reject per parser
  and provenance notes. Divergences between the community spec and parsers,
  and between parsers, are marked in-line — they are findings, not bugs in
  this table.
- `fixtures/peg-morphology-diff.md` — rule-level diff between the BPFK wiki
  PEG morphology page and ilmentufa's camxes.peg morphology section, pinned.
- `run-probes.js` — runs the probe table against ilmentufa (required) and a
  jbotci CLI (optional), reports actual-vs-expected. Usage:

      ILMENTUFA_DIR=~/git/ilmentufa node tests/run-probes.js
      # optional: JBOTCI_BIN=/path/to/jbotci-gentufa-cli

  Exit code 1 iff any ilmentufa expectation mismatches (jbotci "-" rows are
  informational). CI runs the ilmentufa half (see workflow).
