<?xml version="1.0" encoding="UTF-8"?>
<!--
  Comparison colours shared by scripts/docbook-diff.xsl and
  scripts/docbook-diff-html5.xsl. The text is the former htmldiff
  palette, with print styles.
-->
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns="http://www.w3.org/1999/xhtml" version="1.0">

  <xsl:template name="cll.diff.styles">
    <xsl:text>
span.added, span.deleted, span.changed { border-radius: 2px; }
span.added   { background-color: #97f295; text-decoration: none; }
span.deleted { background-color: #ffb6ba; text-decoration: line-through; }
/* A change is two adjacent spans, and the shaper can join a letter from
   each into one glyph. Linux Libertine's liga feature does this for t+t
   (so "correct" + "turn" draws as "correc" + "urn"), and also for f+i,
   f+l, f+f, f+t, T+h and the other f+letter pairs. hlig (c+t, s+t) and
   dlig (c+h, c+k, t+z) do the same when a Lojban span turns them on, and
   frac can join a split fraction. The book's lang=zlm rule sets
   font-feature-settings, which overrides font-variant-ligatures, so the
   counters have to be important and have to reach the inner span. The
   non-joiner at each edge stops a join with the unmarked letter beside
   the change. Text outside these spans keeps the book's ligatures. */
span.added, span.deleted,
span.added *, span.deleted * {
  font-variant-ligatures: none !important;
  font-variant-numeric: normal !important;
  font-feature-settings: "liga" 0, "clig" 0, "dlig" 0, "hlig" 0, "calt" 0, "frac" 0 !important;
}
span.added::before, span.added::after,
span.deleted::before, span.deleted::after { content: "\200c"; }
div.added    { background-color: #e5fbe4; border-left: 4px solid #97f295;
               padding-left: 0.5em; margin-left: -0.75em; }
div.deleted  { background-color: #ffeef0; border-left: 4px solid #ffb6ba;
               padding-left: 0.5em; margin-left: -0.75em;
               text-decoration: line-through; }
div.changed  { background-color: #eef3fd; border-left: 4px solid #8aa9e6;
               padding-left: 0.5em; margin-left: -0.75em; font-style: italic; }
span.changed { background-color: #eef3fd; }
div.added span.added { background-color: transparent; }
div.deleted span.deleted { background-color: transparent; }
/* Changed-section numbers in the table of contents. Amber, not pale
   yellow: red-green colour-blind readers see the added green as pale
   yellow, so amber stays distinct. */
span.diff-toc-changed { background-color: #ffd84d; color: #000;
                        border-radius: 2px; padding: 0 0.2em; }
span.diff-toc-added { background-color: #97f295;
                      border-radius: 2px; padding: 0 0.2em; }
span.diff-toc-deleted { background-color: #ffb6ba; text-decoration: line-through;
                        border-radius: 2px; padding: 0 0.2em; }
/* A fully added or deleted table row reads as one unit: one background
   with a single left bar on the first cell. The per-cell bars inside
   such a row are dropped (deleted rows keep their strikethrough). */
tr.diff-row-added td { background-color: #e5fbe4; }
tr.diff-row-added td:first-child { border-left: 4px solid #97f295; }
tr.diff-row-added div.added { border-left: none; margin-left: 0; padding-left: 0;
                              background-color: transparent; }
tr.diff-row-deleted td { background-color: #ffeef0; }
tr.diff-row-deleted td:first-child { border-left: 4px solid #ffb6ba; }
tr.diff-row-deleted div.deleted { border-left: none; margin-left: 0; padding-left: 0;
                                  background-color: transparent; }
.diff-banner { font-family: system-ui, sans-serif; font-size: 0.95rem;
               line-height: 1.45; background: #f7f7f7; border: 1px solid #ccc;
               border-radius: 4px; padding: 0.6em 0.9em; margin: 0.5em 0 1.5em; }
.diff-banner .added, .diff-banner .deleted, .diff-banner .changed { padding: 0 0.25em; }
.diffmark { font-family: monospace; font-size: 0.85em; font-weight: bold;
            color: #555; text-decoration: none; }
@media print {
  div.added, div.deleted, div.changed { margin-left: 0; }
  span.added, span.deleted, div.added, div.deleted, div.changed {
    -webkit-print-color-adjust: exact; print-color-adjust: exact; }
}
</xsl:text>
  </xsl:template>

</xsl:stylesheet>
