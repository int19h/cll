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
