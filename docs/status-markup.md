# Status markup: marking rule authority in the DocBook sources

Per editorial decision 11 (issue #1) and the design in issue #47, every rule or
claim whose authority differs from the first edition's baseline carries
**abstract, semantic** status markup in the DocBook source. Renderers decide
presentation (margin marks in print, badges in HTML, native widgets in jbotci
cukta); nothing presentational is baked into the XML.

## Status levels

Six **authority levels** (the taxonomy of research/CHANGES.md §0, mirrored in
CLAUDE.md) plus two **note kinds** specific to this edition's apparatus:

| token | kind | meaning |
|---|---|---|
| `llg-ratified` | authority | ratified by an LLG vote (only xorlo) |
| `bpfk-approved` | authority | adopted by a recorded BPFK vote, not LLG-ratified |
| `checkpointed` | authority | fixed by an era-1 BPFK checkpoint; frozen snapshot authoritative |
| `de-facto` | authority | never voted; working-document and/or implemented (state the evidence class in prose) |
| `proposed` | authority | a concrete proposal without adoption |
| `unsettled` | authority | genuinely open; sources or parsers disagree |
| `editorial` | note kind | a convention this edition adopts where official texts are silent |
| `historical` | note kind | describes an abolished first-edition rule |

`status:` states the note's **primary disposition**: the standing of the rule
*as this edition teaches it*. Many notes are composite (a historical rule, a
de-facto replacement, and an editorial choice in one paragraph); the primary
is the standing of what the reader is being told to use, and the optional
`also:` key (comma-separated tokens from the same table) records the other
strands machine-readably. The prose remains the full record; `also:` never
substitutes for it.

## Block form (the normal case)

A paragraph-sized status note uses `role="status-note"` plus a machine-readable
`condition` attribute (a DocBook 5 common attribute, so no schema change):

```xml
<para role="status-note" condition="status:checkpointed;date:2005-02-11">
  (A status note: … prose stating the same facts for the human reader …)
</para>
```

`condition` microsyntax: semicolon-separated `key:value` pairs. Empty
components (`;;`) and empty values are errors.

- `status:<token>` — required; exactly one; the primary disposition.
- `also:<token>[,<token>...]` — optional; additional strands of a composite note.
- `date:YYYY[-MM[-DD]]` — optional; the date of the governing act. Must be a
  real calendar date (month 01–12, valid day).
- `body:<slug>` — optional; `llg`, `bpfk`, or `community`. Defaults by status:
  `llg-ratified` → `llg`; `bpfk-approved` and `checkpointed` → `bpfk`;
  `de-facto`, `proposed`, `unsettled` → `community`; `editorial` and
  `historical` → none (the body is this edition itself; give `body:` only if
  an external body is genuinely involved).
- `src:<slug>` — optional; a pointer key into the sources catalog (for the
  generatable "Changes from the first edition" appendix). Slug grammar:
  lowercase `[a-z0-9-]`, starting with an alphanumeric.

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
`status-note`/`status-mark` with its nearest ancestor `xml:id` and `condition`
payload, plus (b) hand-written summary prose. `scripts/lint-status-markup.py
--list chapters/*.xml` emits the extraction as TSV on stdout — header line
`file	element	anchor	status	also	date	body	src` (schema v1), one row per
conditioned status element, `anchor` being the nearest ancestor element
carrying an `xml:id`. All diagnostics go to stderr; transitional bare notes
produce warnings, not rows.

## Lint

`scripts/lint-status-markup.py chapters/*.xml` (CI-enforced):

- **error**: malformed `condition` on a status element (bad microsyntax,
  unknown status/also token, non-calendar date, bad or empty slug, empty
  components, duplicate keys);
- **error**: a `condition` with a `status` key (whitespace around the key is
  normalized, exactly as the microsyntax parser would accept it) on ANY
  element whose role is not `status-note`/`status-mark` (all elements are
  checked — `condition` is a DocBook common attribute; other keys such as
  `xstatus:` are not ours and pass through);
- **error**: a status role on the wrong or an unsupported carrier — the
  semantic pairs are exactly `para`/`status-note` and `phrase`/`status-mark`
  (the renderers style only these two class combinations), and an element
  cannot carry both roles;
- **error**: a `status-mark` without `condition` (only `status-note` has the
  transitional bare form);
- **warning** (report-only): a `status-note` without `condition`.

The lint is XML-aware and namespace-aware (expat): comments and CDATA cannot
fool it, start-tags may span lines, both quote styles are recognized,
prefixed DocBook-namespace carriers (e.g. `db:para`) are recognized,
foreign-namespace elements are never carriers, and any XML-Name entity
reference is tolerated in fragments.
`scripts/test-lint-status-markup.py` carries the regression suite and runs in
CI beside the lint.

Rendering note: the class-based renderers style `p.status-note` (block; the
selector defeats the print pipeline's first-line indent) and
`span.status-mark` (inline; dotted underline plus a superscript ◇). The
`condition` attribute is not yet propagated to HTML classes; per-level glyphs
remain future work (issue #47 stays open to track renderer refinement and
the profiling-attribute reservation: `condition` is used for status only —
do not overload it for DocBook effectivity profiling in this book).
