# Status markup: marking rule authority in the DocBook sources

Per editorial decision 11 (issue #1) and the design in issue #47, every rule or
claim whose authority differs from the first edition's baseline carries
**abstract, semantic** status markup in the DocBook source. Renderers decide
presentation (margin marks in print, badges in HTML, native widgets in jbotci
cukta); nothing presentational is baked into the XML.

## Status levels

The authority taxonomy (research/CHANGES.md §0, mirrored in CLAUDE.md):

| token | meaning |
|---|---|
| `llg-ratified` | ratified by an LLG vote (only xorlo) |
| `bpfk-approved` | adopted by a recorded BPFK vote, not LLG-ratified |
| `checkpointed` | fixed by an era-1 BPFK checkpoint; frozen snapshot authoritative |
| `de-facto` | never voted; working-document and/or implemented (state the evidence class in prose) |
| `proposed` | a concrete proposal without adoption |
| `unsettled` | genuinely open; sources or parsers disagree |
| `editorial` | a convention this edition adopts where official texts are silent |
| `historical` | describes an abolished first-edition rule |

## Block form (the normal case)

A paragraph-sized status note uses `role="status-note"` plus a machine-readable
`condition` attribute (a DocBook 5 common attribute, so no schema change):

```xml
<para role="status-note" condition="status:checkpointed;date:2005-02-11">
  (A status note: … prose stating the same facts for the human reader …)
</para>
```

`condition` microsyntax: semicolon-separated `key:value` pairs.

- `status:<token>` — required; exactly one; token from the table above.
- `date:YYYY[-MM[-DD]]` — optional; the date of the governing act.
- `body:<slug>` — optional; `llg`, `bpfk`, `community` (defaults follow from the status).
- `src:<slug>` — optional; a pointer key into the sources catalog (for the
  generatable "Changes from the first edition" appendix).

The prose remains the primary, self-sufficient record; `condition` is a
machine-readable summary of it. A `status-note` **without** `condition` is
legal during the transition and renders with a generic mark; the lint reports
it as a warning so coverage can be burned down.

## Inline form

For a single clause inside otherwise-standard prose:

```xml
<phrase role="status-mark" condition="status:de-facto">accepted by current parsers</phrase>
```

Use sparingly; prefer the block form.

## Rendering

- **Print (Prince)/HTML**: docbook-xsl propagates `para/@role` to `p/@class`,
  so `p.status-note` styles the note; `assets/css/master.css` gives it a
  margin mark (◆) and an inset border. Level-specific glyphs require the XSL
  to propagate `condition` (future work; tracked in #47).
- **jbotci cukta**: consumes the XML directly; keys off `@role` and parses
  `@condition` with the microsyntax above. Unknown keys must be ignored.
- **EPUB**: falls back to the same class-based styling.

## Appendix generation

The "Changes from the first edition" appendix is assembled from (a) every
`status-note`/`status-mark` with its chapter/section anchor and `condition`
payload, plus (b) hand-written summary prose. `scripts/lint-status-markup.py
--list` emits the extraction as TSV.

## Lint

`scripts/lint-status-markup.py chapters/*.xml` (CI-enforced):

- **error**: malformed `condition` on a status element (bad microsyntax,
  unknown status token, bad date, duplicate keys);
- **error**: `condition` containing `status:` on an element whose role is not
  `status-note`/`status-mark`;
- **warning** (report-only): a `status-note` without `condition`.
