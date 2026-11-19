# Status markup: marking where a rule comes from in the DocBook sources

Per editorial decision 11 (issue #1) and the design in issue #47, every rule or
claim that comes from somewhere other than the first edition's baseline carries
**abstract, semantic** status markup in the DocBook source. Renderers decide
presentation (margin marks in print, badges in HTML, native widgets in jbotci
cukta); nothing presentational is baked into the XML.

## Status labels

Six **status labels** defined in [AGENTS.md](../AGENTS.md), plus two **note kinds** specific
to this edition's apparatus. The `token` is the machine-readable value in
`status:<token>` and does not change when the displayed label changes. A label
records where a rule comes from. A vote changes a rule's label, not its
standing.

| token | label | kind | meaning |
|---|---|---|---|
| `llg-ratified` | Ratified by the LLG | status | adopted by an LLG vote (only xorlo) |
| `bpfk-approved` | Approved by the BPFK | status | adopted by a recorded BPFK vote |
| `checkpointed` | BPFK checkpoint | status | fixed in a BPFK checkpoint text; frozen snapshot authoritative |
| `de-facto` | Established usage | status | the language as speakers and the parsers use it, with no vote; working-document and/or implemented (state the evidence class in prose) |
| `proposed` | Proposal | status | a written proposal that usage has not taken up |
| `unsettled` | Open question | status | sources, parsers, or speakers disagree |
| `editorial` | This edition's choice | note kind | a convention this edition chooses where official texts are silent |
| `historical` | First-edition rule | note kind | a rule the first edition taught |

`status:` states the note's **primary disposition**: where the rule *as this
edition teaches it* comes from. Many notes are composite (a first-edition rule, a
replacement in established usage, and a choice of this edition in one paragraph); the primary
is the source of what the reader is being told to use, and the optional
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

The `condition` attribute is reserved for status notes (and status marks) in
this book: never use it for DocBook effectivity profiling, and never set
DocBook's `profile.condition` parameter (or any other `profile.*` parameter)
in the build's stylesheets or scripts — profiling keys off `condition` and
would drop status notes from the output. `scripts/test-status-rendering.py`
enforces this.

- **All DocBook-XSL outputs** (HTML, ePub, and the Prince and WeasyPrint PDF
  inputs): `xml/docbook2html_config_common.xsl` is the one source of truth.
  It turns each `condition` into a `status-note status-<token>` class (for
  example `status-de-facto`), `data-status`, `data-also`, `data-date` and
  `data-body` attributes (the body uses the defaults in the table above when
  `body:` is absent), and a real-text label from its one token-to-label
  table: `<span class="status-label">Established usage</span>` at the start
  of the note, with the date appended where one exists (for example
  "Approved by the BPFK, 2015-08-08") and the also-strands as a short second
  line (`<span class="status-also">also: First-edition rule</span>`). An
  explicit `body:` that the primary label does not already name joins the
  label text too (for example "Proposal, BPFK" for `status:proposed;body:bpfk`,
  distinct from "Approved by the BPFK"), because a print reader cannot see
  `data-body` or the tooltip; a defaulted body stays in those two places
  only. The templates match `@role` by token membership, so extra role
  tokens keep the label and survive as extra classes. Because
  the label is text, it reaches screen readers, ePub readers and copied text
  with no CSS. A `status-note` without `condition` (the transitional bare
  form) renders with the generic class and no label.
- **Inline marks** get the lighter form: the same classes and data
  attributes, a short real-text label in a superscript `status-label-inline`
  span after the clause (for example "[Established usage]"), carrying the
  same visible body and date suffixes as the block label, and a `title`
  tooltip with the label, date, body and also-strands. A full badge inline
  would break the sentence the mark annotates.
- **HTML**: the label is a small filled badge, linked to the legend list
  (`xml:id="status-legend"` in the changes appendix, `chapters/a03.xml`);
  the link's `title` tooltip gives the label, date, body and also-strands.
  Each status has a dark badge colour with white text (contrast 6.54:1 or
  better), but colour is never the only signal: the text, the margin-glyph
  shape and (for three statuses) the border style all differ.
- **Print (Prince and WeasyPrint)**: the label stands in small caps at the
  start of the note, with a margin mark whose shape differs by status —
  ★ llg-ratified, ● bpfk-approved, ■ checkpointed, ◆ de-facto, △ proposed,
  ? unsettled, ▲ editorial, ◇ historical, all in the book's Biolinum/DejaVu
  fonts — never by colour alone, so a black-and-white printing still tells
  the statuses apart. Proposed also gets a dashed rule, unsettled a dotted
  rule, and historical a double rule. The print rules keep the label, the
  also-line and the start of the prose on one page (`break-inside: avoid`
  on the note, `break-after: avoid` on the label and also-line, checked by
  `scripts/test-status-pagination.py`); a note taller than a page may still
  break after its first lines.
- **EPUB**: the label text with light styling only (bold small caps in a
  thin border). Reading systems report screen media, so the filled web
  badge would apply there too; a `body.epub` rule in `master.css` (the
  class `scripts/epub_pages.rb` puts on packaged pages) restores the light
  form in the packaged ePub, whose reading systems differ in the CSS they
  apply.
- **Typst and ConTeXt** (experimental formats, not release formats): the
  converters (`scripts/docbook_to_typst.rb` and
  `scripts/docbook_to_context.rb`) read `@condition` from the DocBook
  sources and render the same real-text label as the print PDFs (label,
  explicit body, date and also-strands) with the same per-status margin
  glyph, in black and white. The label stays with the start of the note
  (a sticky label block in Typst, `\testpage` in ConTeXt). The token
  table lives once in `scripts/status_labels.rb`, checked against the
  XSL table, the CSS glyphs and this file by
  `scripts/test-status-rendering.py`.
- **Screen readers**: the CSS margin glyphs are decorative. Every glyph
  rule keeps its visible `content` declaration and adds an identical one
  with an empty alternative text (`content: "◆" / "";`), so readers that
  understand alternative text skip the glyph while the real-text label
  stays readable; older engines use the plain fallback. The glyphs add
  no XSL output, so the legend link templates are untouched.
- **jbotci cukta**: consumes the XML directly; keys off `@role` and parses
  `@condition` with the microsyntax above. Unknown keys must be ignored.

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
`span.status-mark` (inline; dotted underline plus a superscript glyph).
The XSL propagates `condition` to per-status classes, data attributes and
the text label described in [Rendering](#rendering) above.
