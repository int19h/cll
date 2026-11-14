<?xml version="1.0" encoding="UTF-8"?>
<!--
  Comparison driver for a version whose HTML build uses the xhtml5 base
  (issue #209). scripts/build-site.sh copies this file into the annotated
  tree as xml/docbook2html_diff.xsl when that version's scripts/Makefile
  names xhtml5/docbook.xsl. Older versions keep scripts/docbook-diff.xsl.

  xhtml5/docbook.xsl does not import xhtml/changebars.xsl, so this file
  repeats the revisionflag hook. The match template has to live here:
  xsl:apply-imports in block.or.inline.revision uses the imports of the
  stylesheet that holds the matched template. The colours are the shared
  template in docbook-diff-style.xsl. block.or.inline.revision matches
  the xhtml driver.
-->
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns="http://www.w3.org/1999/xhtml" version="1.0">

  <xsl:import href="docbook-xsl-1.78.1/xhtml5/docbook.xsl"/>
  <xsl:include href="docbook-diff-style.xsl"/>

  <xsl:param name="show.revisionflag" select="'1'"/>

  <xsl:template match="*[@revisionflag]">
    <xsl:call-template name="block.or.inline.revision"/>
  </xsl:template>

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
