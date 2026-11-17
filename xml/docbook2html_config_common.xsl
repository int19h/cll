<?xml version='1.0'?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:fo="http://www.w3.org/1999/XSL/Format"
  xmlns:docbook="http://docbook.org/ns/docbook"
  xmlns="http://www.w3.org/1999/xhtml"
  exclude-result-prefixes="fo docbook"
  version="1.0">

  <xsl:param name="use.id.as.filename" select="'1'"/>
  <xsl:template match="releaseinfo/phrase[@role='release-version']">
    <span xmlns="http://www.w3.org/1999/xhtml" class="release-version"><xsl:apply-templates/></span>
  </xsl:template>
  <xsl:template match="releaseinfo/phrase[@role='release-date']">
    <span xmlns="http://www.w3.org/1999/xhtml" class="release-date"><xsl:apply-templates/></span>
  </xsl:template>
  <xsl:template match="releaseinfo/phrase[@role='release-separator']">
    <span xmlns="http://www.w3.org/1999/xhtml" class="release-separator"><xsl:apply-templates/></span>
  </xsl:template>
  <xsl:template match="orgname[@role='publication-notice']">
    <span xmlns="http://www.w3.org/1999/xhtml" class="orgname publication-notice"><xsl:apply-templates/></span>
  </xsl:template>
  <!-- Keep the publication disclaimer on a separate line in every HTML output. -->
  <xsl:template match="phrase[@role='publication-disclaimer']">
    <br xmlns="http://www.w3.org/1999/xhtml"/>
    <span xmlns="http://www.w3.org/1999/xhtml" class="publication-disclaimer"><xsl:apply-templates/></span>
  </xsl:template>
  <xsl:param name="html.stylesheet" select="'final.css'"/>
  <!-- Keep the public file names. The xhtml5 base defaults to .xhtml. -->
  <xsl:param name="html.ext">.html</xsl:param>
  <!-- The book has its own stylesheet. Do not write or link docbook.css. -->
  <xsl:param name="docbook.css.source"></xsl:param>
  <xsl:param name="docbook.css.link" select="0"/>

  <!-- lang and xml:lang together. The cleanup sed no longer adds them. -->
  <xsl:template name="root.attributes">
    <xsl:attribute name="lang">en</xsl:attribute>
    <xsl:attribute name="xml:lang">en</xsl:attribute>
  </xsl:template>

  <xsl:template match="*" mode="html.lang.attribute">
    <xsl:variable name="value">
      <xsl:choose>
        <xsl:when test="@xml:lang"><xsl:value-of select="@xml:lang"/></xsl:when>
        <xsl:otherwise><xsl:value-of select="@lang"/></xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:if test="$value != ''">
      <xsl:attribute name="lang"><xsl:value-of select="$value"/></xsl:attribute>
      <xsl:attribute name="xml:lang"><xsl:value-of select="$value"/></xsl:attribute>
    </xsl:if>
  </xsl:template>
  <xsl:param name="index.on.type" select="1"/>
  <xsl:param name="index.on.role" select="1"/>
  <xsl:param name="index.links.to.section" select="0"/>
  <xsl:param name="emphasis.propagates.style" select="1"/>
  
  <xsl:param name="xref.with.number.and.title" select="0"/>
  <xsl:param name="generate.consistent.ids" select="1"/>
  <xsl:param name="autolink.index.see" select="0"/>

  <xsl:param name="section.autolabel" select="1"></xsl:param>
  <xsl:param name="section.autolabel.max.depth">8</xsl:param>
  <xsl:param name="section.label.includes.component.label" select="1"></xsl:param>

  <!-- Allow non-trivial classes on examples -->
  <xsl:template match="example[@role]" mode="class.value">
    <xsl:value-of select="concat(@role,' example')"/>
  </xsl:template>

  <!-- default is at
       http://docbook.sourceforge.net/release/xsl/1.76.1/doc/html/generate.toc.html
       -->
  <xsl:param name="generate.toc">
    book      toc,title,figure,equation
    chapter   title
    section   title
  </xsl:param>

  <!-- Override generated text; see
       http://www.sagehill.net/docbookxsl/CustomGentext.html for an intro to what's happening here.

      The file we're modifying lives at /usr/share/sgml/docbook/xsl-ns-stylesheets-*/common/en.xml
  -->
  <xsl:param name="local.l10n.xml" select="document('')"/>

  <l:i18n xmlns:l="http://docbook.sourceforge.net/xmlns/l10n/1.0">
    <l:l10n language="en">
      <l:context name="index">
        <!-- In indexes do "foo: 1, 7" for "see foo on pages 1 and
             7", instead of the default which is a comma (??)
             -->
        <l:template name="term-separator" text=": "/>
      </l:context>
    </l:l10n>
  </l:i18n>

  <!-- Index cross-references. DocBook XSL writes "(see X)" and
       "(see also X)" as bare text in an index dt. Wrap them in a span
       with a class, so that scripts/prince_shave_index.js can tell a
       cross-reference entry from an empty one and keep it. The text is
       the same as the DocBook XSL 1.78.1 templates in
       xhtml5/autoidx.xsl write. -->
  <!-- The folding table of the DocBook XSL 1.78.1 index sort (its
       &lowercase; and &uppercase; entities), copied so that see-also
       entries keep their order. -->
  <xsl:variable name="cll.index.lowercase" select="'Aa&#192;&#224;&#193;&#225;&#194;&#226;&#195;&#227;&#196;&#228;&#197;&#229;&#256;&#257;&#258;&#259;&#260;&#261;&#461;&#462;&#478;&#479;&#480;&#481;&#506;&#507;&#512;&#513;&#514;&#515;&#550;&#551;&#7680;&#7681;&#7834;&#7840;&#7841;&#7842;&#7843;&#7844;&#7845;&#7846;&#7847;&#7848;&#7849;&#7850;&#7851;&#7852;&#7853;&#7854;&#7855;&#7856;&#7857;&#7858;&#7859;&#7860;&#7861;&#7862;&#7863;Bb&#384;&#385;&#595;&#386;&#387;&#7682;&#7683;&#7684;&#7685;&#7686;&#7687;Cc&#199;&#231;&#262;&#263;&#264;&#265;&#266;&#267;&#268;&#269;&#391;&#392;&#597;&#7688;&#7689;Dd&#270;&#271;&#272;&#273;&#394;&#599;&#395;&#396;&#453;&#498;&#545;&#598;&#7690;&#7691;&#7692;&#7693;&#7694;&#7695;&#7696;&#7697;&#7698;&#7699;Ee&#200;&#232;&#201;&#233;&#202;&#234;&#203;&#235;&#274;&#275;&#276;&#277;&#278;&#279;&#280;&#281;&#282;&#283;&#516;&#517;&#518;&#519;&#552;&#553;&#7700;&#7701;&#7702;&#7703;&#7704;&#7705;&#7706;&#7707;&#7708;&#7709;&#7864;&#7865;&#7866;&#7867;&#7868;&#7869;&#7870;&#7871;&#7872;&#7873;&#7874;&#7875;&#7876;&#7877;&#7878;&#7879;Ff&#401;&#402;&#7710;&#7711;Gg&#284;&#285;&#286;&#287;&#288;&#289;&#290;&#291;&#403;&#608;&#484;&#485;&#486;&#487;&#500;&#501;&#7712;&#7713;Hh&#292;&#293;&#294;&#295;&#542;&#543;&#614;&#7714;&#7715;&#7716;&#7717;&#7718;&#7719;&#7720;&#7721;&#7722;&#7723;&#7830;Ii&#204;&#236;&#205;&#237;&#206;&#238;&#207;&#239;&#296;&#297;&#298;&#299;&#300;&#301;&#302;&#303;&#304;&#407;&#616;&#463;&#464;&#520;&#521;&#522;&#523;&#7724;&#7725;&#7726;&#7727;&#7880;&#7881;&#7882;&#7883;Jj&#308;&#309;&#496;&#669;Kk&#310;&#311;&#408;&#409;&#488;&#489;&#7728;&#7729;&#7730;&#7731;&#7732;&#7733;Ll&#313;&#314;&#315;&#316;&#317;&#318;&#319;&#320;&#321;&#322;&#410;&#456;&#564;&#619;&#620;&#621;&#7734;&#7735;&#7736;&#7737;&#7738;&#7739;&#7740;&#7741;Mm&#625;&#7742;&#7743;&#7744;&#7745;&#7746;&#7747;Nn&#209;&#241;&#323;&#324;&#325;&#326;&#327;&#328;&#413;&#626;&#414;&#544;&#459;&#504;&#505;&#565;&#627;&#7748;&#7749;&#7750;&#7751;&#7752;&#7753;&#7754;&#7755;Oo&#210;&#242;&#211;&#243;&#212;&#244;&#213;&#245;&#214;&#246;&#216;&#248;&#332;&#333;&#334;&#335;&#336;&#337;&#415;&#416;&#417;&#465;&#466;&#490;&#491;&#492;&#493;&#510;&#511;&#524;&#525;&#526;&#527;&#554;&#555;&#556;&#557;&#558;&#559;&#560;&#561;&#7756;&#7757;&#7758;&#7759;&#7760;&#7761;&#7762;&#7763;&#7884;&#7885;&#7886;&#7887;&#7888;&#7889;&#7890;&#7891;&#7892;&#7893;&#7894;&#7895;&#7896;&#7897;&#7898;&#7899;&#7900;&#7901;&#7902;&#7903;&#7904;&#7905;&#7906;&#7907;Pp&#420;&#421;&#7764;&#7765;&#7766;&#7767;Qq&#672;Rr&#340;&#341;&#342;&#343;&#344;&#345;&#528;&#529;&#530;&#531;&#636;&#637;&#638;&#7768;&#7769;&#7770;&#7771;&#7772;&#7773;&#7774;&#7775;Ss&#346;&#347;&#348;&#349;&#350;&#351;&#352;&#353;&#536;&#537;&#642;&#7776;&#7777;&#7778;&#7779;&#7780;&#7781;&#7782;&#7783;&#7784;&#7785;Tt&#354;&#355;&#356;&#357;&#358;&#359;&#427;&#428;&#429;&#430;&#648;&#538;&#539;&#566;&#7786;&#7787;&#7788;&#7789;&#7790;&#7791;&#7792;&#7793;&#7831;Uu&#217;&#249;&#218;&#250;&#219;&#251;&#220;&#252;&#360;&#361;&#362;&#363;&#364;&#365;&#366;&#367;&#368;&#369;&#370;&#371;&#431;&#432;&#467;&#468;&#469;&#470;&#471;&#472;&#473;&#474;&#475;&#476;&#532;&#533;&#534;&#535;&#7794;&#7795;&#7796;&#7797;&#7798;&#7799;&#7800;&#7801;&#7802;&#7803;&#7908;&#7909;&#7910;&#7911;&#7912;&#7913;&#7914;&#7915;&#7916;&#7917;&#7918;&#7919;&#7920;&#7921;Vv&#434;&#651;&#7804;&#7805;&#7806;&#7807;Ww&#372;&#373;&#7808;&#7809;&#7810;&#7811;&#7812;&#7813;&#7814;&#7815;&#7816;&#7817;&#7832;Xx&#7818;&#7819;&#7820;&#7821;Yy&#221;&#253;&#255;&#376;&#374;&#375;&#435;&#436;&#562;&#563;&#7822;&#7823;&#7833;&#7922;&#7923;&#7924;&#7925;&#7926;&#7927;&#7928;&#7929;Zz&#377;&#378;&#379;&#380;&#381;&#382;&#437;&#438;&#548;&#549;&#656;&#657;&#7824;&#7825;&#7826;&#7827;&#7828;&#7829;&#7829;'"/>
  <xsl:variable name="cll.index.uppercase" select="'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBCCCCCCCCCCCCCCCCCDDDDDDDDDDDDDDDDDDDDDDDDEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEFFFFFFGGGGGGGGGGGGGGGGGGGGHHHHHHHHHHHHHHHHHHHHIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIJJJJJJKKKKKKKKKKKKKKLLLLLLLLLLLLLLLLLLLLLLLLLLMMMMMMMMMNNNNNNNNNNNNNNNNNNNNNNNNNNNOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOPPPPPPPPQQQRRRRRRRRRRRRRRRRRRRRRRRSSSSSSSSSSSSSSSSSSSSSSSTTTTTTTTTTTTTTTTTTTTTTTTTUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUVVVVVVVVWWWWWWWWWWWWWWWXXXXXXYYYYYYYYYYYYYYYYYYYYYYYZZZZZZZZZZZZZZZZZZZZZ'"/>

  <xsl:template match="indexterm" mode="index-see">
    <xsl:text> </xsl:text>
    <span class="index-see">
      <xsl:text>(</xsl:text>
      <xsl:call-template name="gentext">
        <xsl:with-param name="key" select="'see'"/>
      </xsl:call-template>
      <xsl:text> </xsl:text>
      <xsl:value-of select="see"/>
      <xsl:text>)</xsl:text>
    </span>
  </xsl:template>

  <xsl:template match="indexterm" mode="index-seealso">
    <xsl:for-each select="seealso">
      <xsl:sort select="translate(., $cll.index.lowercase, $cll.index.uppercase)"/>
      <dt>
        <span class="index-seealso">
          <xsl:text>(</xsl:text>
          <xsl:call-template name="gentext">
            <xsl:with-param name="key" select="'seealso'"/>
          </xsl:call-template>
          <xsl:text> </xsl:text>
          <xsl:value-of select="."/>
          <xsl:text>)</xsl:text>
        </span>
      </dt>
      <xsl:if test="$div.element = 'section'">
        <dd></dd>
      </xsl:if>
    </xsl:for-each>
  </xsl:template>

  <!-- An empty colgroup is a placeholder. HTML treats it as one column,
       because span defaults to 1, and the rows are wider than that.
       Drop it. A colgroup that has columns or attributes stays. -->
  <xsl:template match="colgroup[not(*) and not(@*)]" mode="htmlTable"/>

  <!-- colspan="0" means "the rest of the row" in the book, and DocBook's
       HTML table stylesheets do not honor it. Write 12321, a value no
       real table uses. "100%" does not work in Prince. The shared HTML
       cleanup (scripts/html_table_spans.rb) replaces 12321 with the
       table's column count before any output is written.

       Starter code stolen from /usr/share/sgml/docbook/xsl-ns-stylesheets/xhtml/htmltbl.xsl
  -->
  <xsl:template match="@colspan" mode="htmlTableAtt">
    <xsl:if test="number(.) != 1">
      <xsl:choose>
        <xsl:when test="number(.) = 0">
          <xsl:attribute name="{local-name(.)}">
            <xsl:text>12321</xsl:text>
          </xsl:attribute>
        </xsl:when>
        <xsl:otherwise>
          <xsl:attribute name="{local-name(.)}">
            <xsl:value-of select="."/>
          </xsl:attribute>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:if>
  </xsl:template>

  <xsl:template match="itemizedlist[@role='bullets']" mode="class.value">
    <xsl:value-of select="'bullets'"/>
  </xsl:template>

  <!-- Status notes and marks (docs/status-markup.md, issue #47).
       This is the one source of truth for turning a status element's
       @condition into rendering data: a status-<token> class, data-*
       attributes, and a real-text label from the token table below.
       Never set DocBook's profile.condition parameter anywhere in the
       build: profiling keys off @condition and would drop these notes. -->

  <!-- One field of the condition microsyntax (key:value;key:value).
       Strip all XML whitespace, as the lint does: a tab written as a
       character reference survives attribute normalization. -->
  <xsl:template name="cll.status.field">
    <xsl:param name="condition" select="''"/>
    <xsl:param name="key" select="''"/>
    <xsl:variable name="padded"
      select="concat(';', translate($condition, ' &#9;&#10;&#13;', ''), ';')"/>
    <xsl:variable name="needle" select="concat(';', $key, ':')"/>
    <xsl:if test="contains($padded, $needle)">
      <xsl:value-of
        select="substring-before(substring-after($padded, $needle), ';')"/>
    </xsl:if>
  </xsl:template>

  <!-- The one token-to-label table. Keep it in step with AGENTS.md and
       docs/status-markup.md. -->
  <xsl:template name="cll.status.label">
    <xsl:param name="token" select="''"/>
    <xsl:choose>
      <xsl:when test="$token = 'llg-ratified'">Ratified by the LLG</xsl:when>
      <xsl:when test="$token = 'bpfk-approved'">Approved by the BPFK</xsl:when>
      <xsl:when test="$token = 'checkpointed'">BPFK checkpoint</xsl:when>
      <xsl:when test="$token = 'de-facto'">Established usage</xsl:when>
      <xsl:when test="$token = 'proposed'">Proposal</xsl:when>
      <xsl:when test="$token = 'unsettled'">Open question</xsl:when>
      <xsl:when test="$token = 'editorial'">This edition's choice</xsl:when>
      <xsl:when test="$token = 'historical'">First-edition rule</xsl:when>
      <xsl:otherwise><xsl:value-of select="$token"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Default body per status, as in docs/status-markup.md. -->
  <xsl:template name="cll.status.body.default">
    <xsl:param name="token" select="''"/>
    <xsl:choose>
      <xsl:when test="$token = 'llg-ratified'">llg</xsl:when>
      <xsl:when test="$token = 'bpfk-approved' or $token = 'checkpointed'">bpfk</xsl:when>
      <xsl:when test="$token = 'de-facto' or $token = 'proposed' or $token = 'unsettled'">community</xsl:when>
      <xsl:otherwise></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="cll.status.body.label">
    <xsl:param name="body" select="''"/>
    <xsl:choose>
      <xsl:when test="$body = 'llg'">LLG</xsl:when>
      <xsl:when test="$body = 'bpfk'">BPFK</xsl:when>
      <xsl:when test="$body = 'community'">Community</xsl:when>
      <xsl:otherwise><xsl:value-of select="$body"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- The body a primary label already names, if any: "Ratified by
       the LLG", "Approved by the BPFK" and "BPFK checkpoint" name
       theirs; the other labels name none. -->
  <xsl:template name="cll.status.body.named">
    <xsl:param name="token" select="''"/>
    <xsl:choose>
      <xsl:when test="$token = 'llg-ratified'">llg</xsl:when>
      <xsl:when test="$token = 'bpfk-approved' or $token = 'checkpointed'">bpfk</xsl:when>
      <xsl:otherwise></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- ", Body" as visible label text for an explicit body: that the
       primary label does not already name (for example "Proposal,
       BPFK" for status:proposed;body:bpfk, distinct from "Approved
       by the BPFK"). A print reader cannot see the data-body
       attribute or the tooltip, so an explicit body: belongs in the
       label text itself. A defaulted body stays in data-body and
       the tooltip only. -->
  <xsl:template name="cll.status.body.visible">
    <xsl:param name="token" select="''"/>
    <xsl:param name="body.explicit" select="''"/>
    <xsl:variable name="named">
      <xsl:call-template name="cll.status.body.named">
        <xsl:with-param name="token" select="$token"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:if test="$body.explicit != '' and $body.explicit != $named">
      <xsl:text>, </xsl:text>
      <xsl:call-template name="cll.status.body.label">
        <xsl:with-param name="body" select="$body.explicit"/>
      </xsl:call-template>
    </xsl:if>
  </xsl:template>

  <!-- "Label[, date] [&#183; Body] [; also: ...]" for title tooltips. -->
  <xsl:template name="cll.status.title">
    <xsl:param name="label" select="''"/>
    <xsl:param name="date" select="''"/>
    <xsl:param name="body" select="''"/>
    <xsl:param name="also" select="''"/>
    <xsl:value-of select="$label"/>
    <xsl:if test="$date != ''">, <xsl:value-of select="$date"/></xsl:if>
    <xsl:if test="$body != ''">
      <xsl:text> &#183; </xsl:text>
      <xsl:call-template name="cll.status.body.label">
        <xsl:with-param name="body" select="$body"/>
      </xsl:call-template>
    </xsl:if>
    <xsl:if test="$also != ''">
      <xsl:text>; also: </xsl:text>
      <xsl:value-of select="$also"/>
    </xsl:if>
  </xsl:template>

  <!-- Comma-separated also-tokens as comma-separated labels. -->
  <xsl:template name="cll.status.also.labels">
    <xsl:param name="rest" select="''"/>
    <xsl:choose>
      <xsl:when test="contains($rest, ',')">
        <xsl:call-template name="cll.status.label">
          <xsl:with-param name="token" select="substring-before($rest, ',')"/>
        </xsl:call-template>
        <xsl:text>, </xsl:text>
        <xsl:call-template name="cll.status.also.labels">
          <xsl:with-param name="rest" select="substring-after($rest, ',')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="cll.status.label">
          <xsl:with-param name="token" select="$rest"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Link to the legend list (xml:id="status-legend") in the changes
       appendix, resolved for chunked and unchunked outputs alike by
       href.target on the list itself (appendix file plus fragment in
       chunked output, bare fragment in one page). In a partial build
       without that appendix, fall back to the bare fragment. The stock
       stylesheets strip the DocBook namespace before these templates
       run and turn @xml:id into @id (common/stripns.xsl), so accept
       both spellings here and for the ids copied below. -->
  <xsl:template name="cll.status.legend.href">
    <xsl:variable name="legend"
      select="//*[@xml:id = 'status-legend' or @id = 'status-legend']"/>
    <xsl:choose>
      <xsl:when test="$legend">
        <xsl:call-template name="href.target">
          <xsl:with-param name="object" select="$legend[1]"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>#status-legend</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Match the semantic role by token membership, not exact
       equality: role is a whitespace-separated list (the lint
       treats it so), and extra tokens survive as extra classes. -->
  <xsl:template match="para[contains(concat(' ', normalize-space(@role), ' '), ' status-note ')]">
    <xsl:variable name="token">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'status'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="also">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'also'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="date">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'date'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="body.explicit">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'body'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="body">
      <xsl:choose>
        <xsl:when test="$body.explicit != ''">
          <xsl:value-of select="$body.explicit"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:call-template name="cll.status.body.default">
            <xsl:with-param name="token" select="$token"/>
          </xsl:call-template>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="label">
      <xsl:call-template name="cll.status.label">
        <xsl:with-param name="token" select="$token"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="also.labels">
      <xsl:if test="$also != ''">
        <xsl:call-template name="cll.status.also.labels">
          <xsl:with-param name="rest" select="$also"/>
        </xsl:call-template>
      </xsl:if>
    </xsl:variable>
    <xsl:variable name="title">
      <xsl:call-template name="cll.status.title">
        <xsl:with-param name="label" select="$label"/>
        <xsl:with-param name="date" select="$date"/>
        <xsl:with-param name="body" select="$body"/>
        <xsl:with-param name="also" select="$also.labels"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="body.visible">
      <xsl:call-template name="cll.status.body.visible">
        <xsl:with-param name="token" select="$token"/>
        <xsl:with-param name="body.explicit" select="$body.explicit"/>
      </xsl:call-template>
    </xsl:variable>
    <p xmlns="http://www.w3.org/1999/xhtml">
      <xsl:attribute name="class">
        <xsl:value-of select="normalize-space(@role)"/>
        <xsl:if test="$token != ''">
          <xsl:value-of select="concat(' status-', $token)"/>
        </xsl:if>
      </xsl:attribute>
      <xsl:if test="@xml:id or @id">
        <xsl:attribute name="id"><xsl:value-of select="(@xml:id|@id)[1]"/></xsl:attribute>
      </xsl:if>
      <xsl:apply-templates select="." mode="html.lang.attribute"/>
      <xsl:if test="$token != ''">
        <xsl:attribute name="data-status"><xsl:value-of select="$token"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="$also != ''">
        <xsl:attribute name="data-also"><xsl:value-of select="$also"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="$date != ''">
        <xsl:attribute name="data-date"><xsl:value-of select="$date"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="$body != ''">
        <xsl:attribute name="data-body"><xsl:value-of select="$body"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="$token != ''">
        <span xmlns="http://www.w3.org/1999/xhtml" class="status-label"><a xmlns="http://www.w3.org/1999/xhtml" class="status-legend-link"><xsl:attribute name="href"><xsl:call-template name="cll.status.legend.href"/></xsl:attribute><xsl:attribute name="title"><xsl:value-of select="$title"/></xsl:attribute><xsl:value-of select="$label"/><xsl:value-of select="$body.visible"/><xsl:if test="$date != ''">, <xsl:value-of select="$date"/></xsl:if></a></span>
        <xsl:text> </xsl:text>
        <xsl:if test="$also != ''">
          <span xmlns="http://www.w3.org/1999/xhtml" class="status-also">also: <xsl:value-of select="$also.labels"/></span>
          <!-- A separator for text without CSS, where the also-line
               is no block box and would fuse with the first word of
               the prose; after a block box the space collapses. -->
          <xsl:text> </xsl:text>
        </xsl:if>
      </xsl:if>
      <xsl:apply-templates/>
    </p>
  </xsl:template>

  <!-- Inline marks get the lighter form: the clause keeps its place in
       the sentence, a short real-text label follows it as a superscript,
       and the title tooltip carries the date, body and also-strands.
       A full badge inline would break the sentence it annotates.
       An explicit body: that the label does not name joins the
       short label text, as in the block form. -->
  <xsl:template match="phrase[contains(concat(' ', normalize-space(@role), ' '), ' status-mark ')]">
    <xsl:variable name="token">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'status'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="also">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'also'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="date">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'date'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="body.explicit">
      <xsl:call-template name="cll.status.field">
        <xsl:with-param name="condition" select="@condition"/>
        <xsl:with-param name="key" select="'body'"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="body">
      <xsl:choose>
        <xsl:when test="$body.explicit != ''">
          <xsl:value-of select="$body.explicit"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:call-template name="cll.status.body.default">
            <xsl:with-param name="token" select="$token"/>
          </xsl:call-template>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>
    <xsl:variable name="label">
      <xsl:call-template name="cll.status.label">
        <xsl:with-param name="token" select="$token"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="also.labels">
      <xsl:if test="$also != ''">
        <xsl:call-template name="cll.status.also.labels">
          <xsl:with-param name="rest" select="$also"/>
        </xsl:call-template>
      </xsl:if>
    </xsl:variable>
    <xsl:variable name="title">
      <xsl:call-template name="cll.status.title">
        <xsl:with-param name="label" select="$label"/>
        <xsl:with-param name="date" select="$date"/>
        <xsl:with-param name="body" select="$body"/>
        <xsl:with-param name="also" select="$also.labels"/>
      </xsl:call-template>
    </xsl:variable>
    <xsl:variable name="body.visible">
      <xsl:call-template name="cll.status.body.visible">
        <xsl:with-param name="token" select="$token"/>
        <xsl:with-param name="body.explicit" select="$body.explicit"/>
      </xsl:call-template>
    </xsl:variable>
    <span xmlns="http://www.w3.org/1999/xhtml">
      <xsl:attribute name="class">
        <xsl:value-of select="normalize-space(@role)"/>
        <xsl:if test="$token != ''">
          <xsl:value-of select="concat(' status-', $token)"/>
        </xsl:if>
      </xsl:attribute>
      <xsl:if test="@xml:id or @id">
        <xsl:attribute name="id"><xsl:value-of select="(@xml:id|@id)[1]"/></xsl:attribute>
      </xsl:if>
      <xsl:apply-templates select="." mode="html.lang.attribute"/>
      <xsl:if test="$token != ''">
        <xsl:attribute name="data-status"><xsl:value-of select="$token"/></xsl:attribute>
        <xsl:attribute name="title"><xsl:value-of select="$title"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="$also != ''">
        <xsl:attribute name="data-also"><xsl:value-of select="$also"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="$date != ''">
        <xsl:attribute name="data-date"><xsl:value-of select="$date"/></xsl:attribute>
      </xsl:if>
      <xsl:if test="$body != ''">
        <xsl:attribute name="data-body"><xsl:value-of select="$body"/></xsl:attribute>
      </xsl:if>
      <xsl:apply-templates/>
      <xsl:if test="$token != ''">
        <span xmlns="http://www.w3.org/1999/xhtml" class="status-label-inline"> [<xsl:value-of select="$label"/><xsl:value-of select="$body.visible"/><xsl:if test="$date != ''">, <xsl:value-of select="$date"/></xsl:if>]</span>
      </xsl:if>
    </span>
  </xsl:template>

  <!-- ==================================================================== -->

  <!-- Special navigation links -->
  <xsl:template name="toc-link">
    <xsl:variable name="home" select="/*[1]"/>

    <div class="toc-link">
      <a accesskey="h">
        <xsl:attribute name="href">
          <xsl:call-template name="href.target">
            <xsl:with-param name="object" select="$home"/>
          </xsl:call-template>
        </xsl:attribute>
        <xsl:call-template name="gentext">
          <xsl:with-param name="key">TableofContents</xsl:with-param>
        </xsl:call-template>
      </a>
    </div>
  </xsl:template>

  <xsl:template name="back-to-info-link">
    <div class="back-to-info-link">
      <a accesskey="b" href="http://www.lojban.org/cll">Book Info Page</a>
    </div>
  </xsl:template>

  <!-- Every HTML config imports this file, so the outline levels apply
       to chunked HTML, the single page, PDF, and ePub. -->
  <xsl:include href="docbook2html_config_headings.xsl"/>

</xsl:stylesheet>
