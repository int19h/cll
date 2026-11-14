<?xml version='1.0'?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:fo="http://www.w3.org/1999/XSL/Format" xmlns:docbook="http://docbook.org/ns/docbook" xmlns="http://www.w3.org/1999/xhtml" exclude-result-prefixes="fo docbook" version="1.0">

  <xsl:template name="user.head.content">
    <script>
    MathJax = {
      tex: {
        inlineMath: [['$', '$']]
      }
    };
    </script>
    <script id="MathJax-script" async="async"
      src="https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-mml-chtml.js"
      integrity="sha384-Wuix6BuhrWbjDBs24bXrjf4ZQ5aFeFWBuKkFekO2t8xFU0iNaLQfp2K6/1Nxveei"
      crossorigin="anonymous"></script>
    <script defer="defer" src="assets/scripts/offline.js"></script>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
  </xsl:template>

  <!-- Outer Headers and footers -->
  <xsl:template name="user.header.navigation"></xsl:template>

  <xsl:template name="user.footer.navigation">
    <xsl:call-template name="toc-link" />
    <xsl:call-template name="back-to-info-link" />
  </xsl:template>

  <!-- Inner Headers and footers -->
  <xsl:template name="user.header.content">
    <xsl:call-template name="toc-link" />
    <xsl:call-template name="back-to-info-link" />
    <hr />
  </xsl:template>
  <xsl:template name="user.footer.content">
    <hr />
  </xsl:template>

  <!-- ==================================================================== -->

  <!-- header; just calls my.navigation -->
  <xsl:template name="header.navigation">
    <xsl:param name="prev" select="/.." />
    <xsl:param name="next" select="/.." />
    <xsl:param name="nav.context" />

    <xsl:variable name="home" select="/*[1]" />
    <xsl:variable name="up" select="parent::*" />

    <xsl:call-template name="my.navigation">
      <xsl:with-param name="prev" select="$prev" />
      <xsl:with-param name="next" select="$next" />
      <xsl:with-param name="nav.context" select="$nav.context" />
    </xsl:call-template>
  </xsl:template>

  <!-- footer; just calls my.navigation -->
  <!-- The xhtml5 chunk wrapper calls user.footer.navigation before
       footer.navigation. The old xhtml chunk wrapper called them in the
       other order, so the footer read: navigation, table of contents,
       book-info link. Keep that order. -->
  <xsl:template name="html5.footer.navigation">
    <xsl:param name="prev" select="/.." />
    <xsl:param name="next" select="/.." />
    <xsl:param name="nav.context" />

    <xsl:variable name="content">
      <footer>
        <xsl:call-template name="footer.navigation">
          <xsl:with-param name="prev" select="$prev" />
          <xsl:with-param name="next" select="$next" />
          <xsl:with-param name="nav.context" select="$nav.context" />
        </xsl:call-template>
        <xsl:call-template name="user.footer.navigation">
          <xsl:with-param name="prev" select="$prev" />
          <xsl:with-param name="next" select="$next" />
          <xsl:with-param name="nav.context" select="$nav.context" />
        </xsl:call-template>
      </footer>
    </xsl:variable>

    <xsl:call-template name="convert.styles">
      <xsl:with-param name="content" select="$content" />
    </xsl:call-template>
  </xsl:template>

  <xsl:template name="footer.navigation">
    <xsl:param name="prev" select="/.." />
    <xsl:param name="next" select="/.." />
    <xsl:param name="nav.context" />

    <xsl:variable name="home" select="/*[1]" />
    <xsl:variable name="up" select="parent::*" />
    <xsl:call-template name="my.navigation">
      <xsl:with-param name="prev" select="$prev" />
      <xsl:with-param name="next" select="$next" />
      <xsl:with-param name="nav.context" select="$nav.context" />
    </xsl:call-template>
  </xsl:template>

  <!-- Originally from /usr/share/sgml/docbook/xsl-ns-stylesheets-1.78.1/xhtml/chunk-common.xsl ; heavily modified -->
  <xsl:template name="my.navigation">
    <xsl:param name="prev" select="/.." />
    <xsl:param name="next" select="/.." />
    <xsl:param name="nav.context" />

    <xsl:variable name="up" select="parent::*" />

    <nav class="navheader">
      <div class="nav-title">
        <xsl:apply-templates select="$up" mode="object.title.markup" />
      </div>
      <div class="nav-links">
        <span class="nav-prev">
          <xsl:if test="$prev">
            <a accesskey="p">
              <xsl:attribute name="href">
                <xsl:call-template name="href.target">
                  <xsl:with-param name="object" select="$prev" />
                </xsl:call-template>
              </xsl:attribute>
              <xsl:call-template name="navig.content">
                <xsl:with-param name="direction" select="'prev'" />
              </xsl:call-template>
              <xsl:value-of select="$xref.label-title.separator" />
              <xsl:apply-templates select="$prev" mode="object.xref.markup" />
            </a>
          </xsl:if>
        </span>
        <xsl:text> </xsl:text>
        <span class="nav-next">
          <xsl:if test="$next">
            <a accesskey="n">
              <xsl:attribute name="href">
                <xsl:call-template name="href.target">
                  <xsl:with-param name="object" select="$next" />
                </xsl:call-template>
              </xsl:attribute>
              <xsl:call-template name="navig.content">
                <xsl:with-param name="direction" select="'next'" />
              </xsl:call-template>
              <xsl:value-of select="$xref.label-title.separator" />
              <xsl:apply-templates select="$next" mode="object.xref.markup" />
            </a>
          </xsl:if>
        </span>
      </div>
    </nav>
  </xsl:template>

  <!-- ==================================================================== -->

</xsl:stylesheet>
