<?xml version="1.0" encoding="UTF-8"?>
<!--
  Driver stylesheet for the DocBook-level visual diff (issue #127).

  scripts/build-site.sh copies this file into the annotated tree as
  xml/docbook2html_diff.xsl and builds xhtml_nochunks with it in place of
  xhtml/docbook.xsl. It renders DocBook revisionflag through the stock
  xhtml/changebars.xsl, with two changes:

  * block.or.inline.revision knows the inline elements that the book's
    custom markup becomes (foreignphrase, subscript, mathphrase...), so a
    flagged Lojban word stays inside its paragraph instead of breaking it
    with a div;
  * the colours come from our own CSS (those of the former htmldiff pages),
    with print styles, instead of changebars.xsl's inline style.
-->
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns="http://www.w3.org/1999/xhtml" version="1.0">

  <xsl:import href="docbook-xsl-1.78.1/xhtml/changebars.xsl"/>

  <xsl:template name="system.head.content">
    <xsl:param name="node" select="."/>
    <style type="text/css">
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
    </style>
  </xsl:template>

  <xsl:template name="block.or.inline.revision">
    <xsl:param name="revisionflag" select="@revisionflag"/>
    <xsl:variable name="n" select="local-name(.)"/>
    <xsl:choose>
      <xsl:when test="$n = 'phrase' or $n = 'ulink' or $n = 'link' or $n = 'olink'
                      or $n = 'inlinemediaobject' or $n = 'filename' or $n = 'literal'
                      or $n = 'member' or $n = 'term' or $n = 'guilabel'
                      or $n = 'glossterm' or $n = 'sgmltag' or $n = 'tag'
                      or $n = 'quote' or $n = 'emphasis' or $n = 'command'
                      or $n = 'xref' or $n = 'foreignphrase' or $n = 'subscript'
                      or $n = 'superscript' or $n = 'inlineequation'
                      or $n = 'citetitle' or $n = 'mathphrase' or $n = 'firstterm'
                      or $n = 'wordasword' or $n = 'acronym' or $n = 'abbrev'
                      or $n = 'code' or $n = 'replaceable' or $n = 'uri'">
        <span class="{$revisionflag}">
          <xsl:apply-imports/>
        </span>
      </xsl:when>
      <xsl:when test="$n = 'listitem' or $n = 'entry' or $n = 'title'">
        <xsl:apply-imports/>
      </xsl:when>
      <xsl:otherwise>
        <!-- para, sections, lists, examples, tables (including the
             informaltables of the interlinear glosses), blockquote,
             informalequation, programlisting, ... -->
        <div class="{$revisionflag}">
          <xsl:apply-imports/>
        </div>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

</xsl:stylesheet>
