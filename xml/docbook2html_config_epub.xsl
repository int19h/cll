<?xml version='1.0'?>

<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:fo="http://www.w3.org/1999/XSL/Format"
  xmlns:docbook="http://docbook.org/ns/docbook"
  xmlns:epub="http://www.idpf.org/2007/ops"
  xmlns:exsl="http://exslt.org/common"
  xmlns="http://www.w3.org/1999/xhtml"
  exclude-result-prefixes="fo docbook exsl"
  version="1.0">

  <xsl:import href="docbook2html_config_common.xsl"/>
  <!-- We only actually have 2 levels, but if we're going to chunk, let's chunk. -->
  <xsl:param name="chunk.section.depth" select="8"></xsl:param>

  <!-- The goal here is chunking with no navigation -->
  <xsl:param name="suppress.navigation" select="1"></xsl:param>

  <!-- xhtml5 already uses section for div.element. table.border.off
       still keeps the presentational border attribute off the tables. -->
  <xsl:param name="table.border.off" select="1"></xsl:param>

  <!-- The ePub navigation document (issue #208).
       The absolute path of the file to write. Empty: write nothing. -->
  <xsl:param name="cll.epub.nav.file" select="''"/>

  <!-- Write the pages as the stock stylesheets do, then the navigation document. -->
  <xsl:template match="*" mode="process.root">
    <xsl:apply-imports/>
    <xsl:if test="$cll.epub.nav.file != ''">
      <xsl:call-template name="cll.epub.nav"/>
    </xsl:if>
  </xsl:template>

  <xsl:template name="cll.epub.nav">
    <xsl:variable name="entries"
      select="part|preface|chapter|appendix|article|bibliography|glossary|index"/>
    <xsl:if test="not($entries)">
      <xsl:message terminate="yes">cll.epub.nav: the book has no entries for the navigation document.</xsl:message>
    </xsl:if>
    <xsl:call-template name="write.chunk">
      <xsl:with-param name="filename" select="$cll.epub.nav.file"/>
      <xsl:with-param name="method" select="'xml'"/>
      <xsl:with-param name="encoding" select="'UTF-8'"/>
      <xsl:with-param name="indent" select="'no'"/>
      <xsl:with-param name="omit-xml-declaration" select="'no'"/>
      <xsl:with-param name="doctype-public" select="''"/>
      <xsl:with-param name="doctype-system" select="''"/>
      <xsl:with-param name="content">
        <xsl:text disable-output-escaping="yes">&lt;!DOCTYPE html&gt;&#10;</xsl:text>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
          <xsl:text>&#10;</xsl:text>
          <head>
            <title>
              <xsl:apply-templates select="." mode="object.title.markup.textonly"/>
            </title>
            <link rel="stylesheet" type="text/css" href="{$html.stylesheet}"/>
            <meta charset="utf-8"/>
          </head>
          <xsl:text>&#10;</xsl:text>
          <body>
            <section class="frontmatter TableOfContents">
              <header>Table Of Contents</header>
              <xsl:text>&#10;</xsl:text>
              <nav id="toc" role="doc-toc" epub:type="toc">
                <ol>
                  <xsl:apply-templates select="$entries" mode="cll.epub.nav">
                    <xsl:with-param name="root" select="."/>
                  </xsl:apply-templates>
                  <xsl:text>&#10;</xsl:text>
                </ol>
              </nav>
            </section>
          </body>
          <xsl:text>&#10;</xsl:text>
        </html>
        <xsl:text>&#10;</xsl:text>
      </xsl:with-param>
    </xsl:call-template>
  </xsl:template>

  <!-- One entry. The selection and the nesting follow the stock table of
       contents (xhtml/autotoc.xsl: division.toc, subtoc and toc.line). -->
  <xsl:template match="*" mode="cll.epub.nav">
    <xsl:param name="root" select="/*"/>
    <xsl:param name="indent" select="'&#10;  '"/>
    <xsl:variable name="depth">
      <xsl:choose>
        <xsl:when test="self::section">
          <xsl:value-of select="count(ancestor::section) + 1"/>
        </xsl:when>
        <xsl:otherwise>0</xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="depth.from.context"
      select="count(ancestor::*) - count($root/ancestor::*)"/>
    <xsl:variable name="label">
      <xsl:apply-templates select="." mode="label.markup"/>
    </xsl:variable>
    <xsl:variable name="children"
      select="(self::part)/*[self::preface or self::chapter or self::appendix
                             or self::article or self::bibliography
                             or self::glossary or self::index]
              | (self::preface|self::chapter|self::appendix|self::article)
                  /*[self::section or self::bibliography or self::glossary or self::index]
              | (self::section)/section"/>
    <!-- The stock table of contents leaves out an index that has no
         content when generate.index is 0. -->
    <xsl:if test="not(self::index) or * or $generate.index != 0">
      <xsl:value-of select="$indent"/>
      <li xmlns="http://www.w3.org/1999/xhtml">
        <a>
          <xsl:attribute name="href">
            <xsl:call-template name="href.target">
              <xsl:with-param name="context" select="$root"/>
              <xsl:with-param name="toc-context" select="$root"/>
            </xsl:call-template>
          </xsl:attribute>
          <xsl:copy-of select="$label"/>
          <xsl:if test="$label != ''">
            <xsl:value-of select="$autotoc.label.separator"/>
          </xsl:if>
          <xsl:variable name="title">
            <xsl:apply-templates select="." mode="titleabbrev.markup"/>
          </xsl:variable>
          <xsl:apply-templates select="exsl:node-set($title)/node()" mode="cll.epub.nav.copy"/>
        </a>
        <xsl:if test="$children and (self::part or $toc.section.depth &gt; $depth)
                      and $toc.max.depth &gt; $depth.from.context">
          <ol>
            <xsl:apply-templates select="$children" mode="cll.epub.nav">
              <xsl:with-param name="root" select="$root"/>
              <xsl:with-param name="indent" select="concat($indent, '  ')"/>
            </xsl:apply-templates>
            <xsl:value-of select="$indent"/>
          </ol>
        </xsl:if>
      </li>
    </xsl:if>
  </xsl:template>

  <!-- Copy the title markup. Add lang beside xml:lang, as the XHTML 1.0
       serializer does for the pages. -->
  <xsl:template match="@*|node()" mode="cll.epub.nav.copy">
    <xsl:copy>
      <xsl:apply-templates select="@*" mode="cll.epub.nav.copy"/>
      <xsl:if test="@xml:lang and not(@lang)">
        <xsl:attribute name="lang">
          <xsl:value-of select="@xml:lang"/>
        </xsl:attribute>
      </xsl:if>
      <xsl:apply-templates select="node()" mode="cll.epub.nav.copy"/>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
