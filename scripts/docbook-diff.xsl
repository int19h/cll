<?xml version="1.0" encoding="UTF-8"?>
<!--
  Driver stylesheet for the DocBook-level visual diff (issue #127).

  scripts/build-site.sh copies this file into the annotated tree as
  xml/docbook2html_diff.xsl and builds xhtml_nochunks with it in place of
  xhtml/docbook.xsl. A version whose Makefile names xhtml5/docbook.xsl
  uses scripts/docbook-diff-html5.xsl instead. This driver renders
  DocBook revisionflag through the stock xhtml/changebars.xsl, with two
  changes:

  * block.or.inline.revision knows the inline elements that the book's
    custom markup becomes (foreignphrase, subscript, mathphrase...), so a
    flagged Lojban word stays inside its paragraph instead of breaking it
    with a div;
  * the colours come from docbook-diff-style.xsl (those of the former
    htmldiff pages), with print styles, instead of changebars.xsl's
    inline style. The xhtml5 driver includes the same template.
-->
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns="http://www.w3.org/1999/xhtml" version="1.0">

  <xsl:import href="docbook-xsl-1.78.1/xhtml/changebars.xsl"/>
  <xsl:include href="docbook-diff-style.xsl"/>

  <xsl:template name="system.head.content">
    <xsl:param name="node" select="."/>
    <style type="text/css">
      <xsl:call-template name="cll.diff.styles"/>
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
