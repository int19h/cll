#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'docbook_to_context'

class ContextBookTest < Minitest::Test
  def book(content)
    ContextBook.new(Nokogiri::XML("<book xmlns:xml='http://www.w3.org/XML/1998/namespace'>#{content}</book>") { |c| c.strict })
  end

  def test_title_metadata_uses_separate_notice_and_footer_labels
    output = book(<<~XML).to_tex
      <info><title>Test Book</title>
        <othercredit><orgname>revised by Test Authors</orgname></othercredit>
        <releaseinfo><phrase role="release-version">test-1.0+abc1234</phrase><phrase role="release-separator"> | </phrase><phrase role="release-date">2026-10-27</phrase></releaseinfo>
        <othercredit><orgname role="publication-notice">(not a Test Publisher publication)<phrase role="publication-disclaimer">Optional disclaimer.</phrase></orgname></othercredit>
      </info>
    XML
    assert_includes output, '\\setupfootertexts[{test-1.0+abc1234}][{2026-10-27}]'
    assert_includes output, '\\switchtobodyfont[12bp]\\tf (not a Test Publisher publication)\\crlf Optional disclaimer.'
    assert_includes output, 'revised by Test Authors\\par'
    assert_equal 1, output.scan('test-1.0+abc1234').length
    assert_equal 1, output.scan('(not a Test Publisher publication)').length
  end

  def test_numbering_and_references_preserve_source_identity
    input = book(<<~XML)
      <chapter xml:id="first"><title>First</title>
        <section xml:id="section"><title>Topic</title>
          <example xml:id="sample"><title><anchor xml:id="legacy"/></title><para>Text.</para></example>
          <para><xref linkend="legacy"/> and <xref linkend="sample"/>.</para>
        </section>
      </chapter>
      <chapter><title>Second</title><example><title/><para>Next.</para></example></chapter>
    XML
    output = input.to_tex
    assert_includes output, 'Example~1.1'
    assert_includes output, 'Example~2.1'
    assert_includes output, '\\goto{Example 1.1}'
    assert_includes output, '\\at['
    assert_empty input.report['missing_references']
  end

  def test_math_is_structural_and_rejects_unknown_operators
    input = book('<para><math><mfrac><mi>a</mi><msqrt><msup><mi>b</mi><mn>2</mn></msup></msqrt></mfrac></math></para>')
    assert_includes input.to_tex, '\\frac{a}{\\sqrt{{b}^{2}}}'
    assert_equal 1, input.report['math']
    assert_raises(RuntimeError) { book('<math><unsupported/></math>').to_tex }
  end

  def test_math_connectives_keep_punctuation_and_explicit_spacing
    variants = ['<mo>Iff </mo><mi>a</mi><mo>=</mo><mn>0</mn><mo>, then </mo><mi>x</mi>',
                '<mo>Iff</mo><mi>a</mi><mo>=</mo><mn>0</mn><mo>, then</mo><mi>x</mi>']
    variants.each do |content|
      output = book("<para><math><mrow>#{content}</mrow></math></para>").to_tex
      assert_includes output, '\\mathupright{Iff}\\quad a=0,\\quad \\mathupright{then}\\quad x'
      refute_includes output, '\\mathtext{Iff}'
    end
    output = book('<math><mi>a</mi><mo>iff</mo><mi>b</mi></math>').to_tex
    assert_includes output, 'a\\quad \\mathupright{iff}\\quad b'
  end

  def test_nested_tables_and_full_width_translation
    input = book(<<~XML)
      <informaltable><tr><td>
        <informaltable><tr class="jbo"><td>mi</td><td>klama</td></tr>
          <tr class="gloss"><td>I</td><td>go</td></tr>
          <tr><td colspan="0"><para>I go.</para></td></tr>
        </informaltable>
      </td></tr></informaltable>
    XML
    output = input.to_tex
    assert_includes output, '\\bTABLEnested[split=no]'
    assert_includes output, '\\bTD[nc=2,nr=1,rightframe=off]'
    assert_includes output, 'I go.'
    assert_includes output, '{\\it mi}'
    assert_includes output, '{\\bf I}'
  end

  def test_special_characters_cannot_become_tex_commands
    output = book('<para>\\input{bad} $x &amp; 50% #1 _ ^ ~ |</para>').to_tex
    refute_includes output, '\\input{bad}'
    assert_includes output, '\\letterbackslash{}input\\letterleftbrace{}bad\\letterrightbrace{}'
    assert_includes output, '\\letterpercent{}'
    assert_includes output, '\\letterampersand{}'
  end

  def test_list_item_indentation_does_not_depend_on_xml_whitespace
    compact = book('<orderedlist><listitem><para>First <emphasis>two words</emphasis>.</para></listitem></orderedlist>').to_tex
    formatted = book("<orderedlist>\n  <listitem>\n    <para>    First <emphasis>two words</emphasis>.</para>\n  </listitem>\n</orderedlist>").to_tex
    item = /\\startitem (.*?)\\stopitem/m
    assert_equal compact.match(item)[1], formatted.match(item)[1]
    assert_match(/\AFirst \{\\it two words\}\./, formatted.match(item)[1])
  end

  def test_leading_index_entries_do_not_add_space_to_list_text
    output = book(<<~XML).to_tex
      <orderedlist><listitem><para>
        <indexterm type="general"><primary>first</primary></indexterm>
        <anchor xml:id="list-anchor"/>
        First two words <indexterm type="general"><primary>middle</primary></indexterm> stay apart.
      </para></listitem></orderedlist>
    XML
    assert_match(/\\CLLgeneral\[\{first\}\]\{first\}\\reference\[[^\]]+\]\{[^}]*\}First two words /, output)
    assert_includes output, 'words \\CLLgeneral[{middle}]{middle} stay apart.'
  end

  def test_index_hierarchy_and_literal_plus
    output = book('<para><indexterm type="general"><primary>a+b</primary><secondary>detail</secondary></indexterm>Body</para>').to_tex
    assert_includes output, '\\CLLgeneral[{a\\char43{}b+detail}]{a\\char43{}b+detail}'
    assert_includes output, 'Body'
  end

  def test_index_keys_preserve_apostrophes_and_ignore_case_and_outer_spaces
    output = book(<<~XML).to_tex
      <para>
        <indexterm type="lojban-word"><primary>bei</primary></indexterm>
        <indexterm type="lojban-word"><primary>be'i</primary></indexterm>
        <indexterm type="lojban-word"><primary>be’i</primary></indexterm>
        <indexterm type="general"><primary>  Avon </primary><secondary> Two   Words </secondary></indexterm>
        <indexterm type="general"><primary>be!ai</primary></indexterm>
        <indexterm type="general"><primary>'</primary></indexterm>
      </para>
    XML
    assert_includes output, '\\CLLlojban[{bei}]{bei}'
    assert_includes output, "\\CLLlojban[{be!ai}]{be'i}"
    assert_includes output, '\\CLLlojban[{be!ai}]{be’i}'
    assert_includes output, '\\CLLgeneral[{avon+two words}]{Avon+Two Words}'
    assert_includes output, '\\CLLgeneral[{be!!ai}]{be!ai}'
    assert_includes output, "\\CLLgeneral[{'}]{'}"
  end

  def test_simplelist_column_order
    members = %w[A B C D].map { |text| "<member>#{text}</member>" }.join
    horizontal = book("<simplelist type='horiz' columns='2'>#{members}</simplelist>").to_tex
    vertical = book("<simplelist type='vert' columns='2'>#{members}</simplelist>").to_tex
    assert_match(/ A .* B .* C .* D /m, horizontal)
    assert_match(/ A .* C .* B .* D /m, vertical)
    assert_raises(RuntimeError) { book('<simplelist columns="0"><member>A</member></simplelist>').to_tex }
  end

  def test_simplelist_inside_a_table_keeps_its_nested_context
    output = book('<informaltable><tr><td><simplelist columns="2"><member>A</member><member>B</member></simplelist></td></tr></informaltable>').to_tex
    assert_includes output, '\\bTABLEnested[split=no]'
    assert_match(/\\bTD[^\n]*\n?\{\n\\begingroup/, output)
  end

  def test_cross_references_use_custom_labels
    input = book(<<~XML)
      <chapter id="c"><title>Grammar</title><section id="s"><title>Rules</title>
        <bridgehead><anchor id="rule" xreflabel="BNF rule #42"/>Rule 42</bridgehead>
        <para><xref linkend="rule"/> and <xref linkend="s"/>.</para>
      </section></chapter>
    XML
    output = input.to_tex
    assert_includes output, '\\goto{BNF rule \\letterhash{}42}'
    assert_includes output, '\\goto{Section 1.1}'
    assert_empty input.report['missing_references']
  end

  def test_selmao_catalog_references_use_names
    input = book(<<~XML)
      <chapter><title>Catalog</title>
        <bridgehead><anchor id="BE" xreflabel="BE"/>selma'o BE</bridgehead>
        <para>Attach with <xref linkend="BE"/>.</para>
      </chapter>
    XML
    output = input.to_tex
    assert_includes output, '\\goto{BE}'
    refute_includes output, '\\goto{Chapter 1}'
  end

  def test_bridgehead_anchors_leave_the_title_for_the_reference_field
    input = book(<<~XML)
      <chapter><title>Catalog</title>
        <bridgehead><anchor id="BE" xreflabel="BE"/>selma'o BE</bridgehead>
        <para>Attach with <xref linkend="BE"/>.</para>
      </chapter>
    XML
    output = input.to_tex
    key = "cll-#{Digest::SHA256.hexdigest('BE')[0, 24]}"
    assert_includes output, "\\subsubject[title={selma'o BE},reference={#{key}}]"
    refute_includes output, "\\reference[#{key}]"
    assert_includes output, "\\goto{BE}[#{key}]"
    assert_empty input.report['missing_references']
  end

  def test_index_see_entries_point_at_their_target
    output = book('<para><indexterm type="general"><primary>masses</primary><see>groups</see></indexterm>' \
                  '<indexterm type="general"><primary>groups</primary></indexterm>Body</para>').to_tex
    assert_includes output, '\\seeCLLgeneral[{masses}]{masses}{groups}'
    refute_match(/\\CLLgeneral\[\{masses\}\]\{masses\}(?!\{)/, output)
    output = book('<para><indexterm type="general"><primary>terms</primary><seealso>words</seealso></indexterm>' \
                  '<indexterm type="general"><primary>words</primary></indexterm>Body</para>').to_tex
    assert_includes output, '\\seeCLLgeneral[{terms}]{CLLseealso->terms}{words}'
    assert_match(/\\CLLgeneral\[\{terms\}\]\{terms\}(?!\{)/, output)
  end

  def test_index_see_target_with_formatting_uses_plain_text
    output = book('<para><indexterm type="general"><primary>masses</primary><see><emphasis>groups</emphasis></see></indexterm>' \
                  '<indexterm type="general"><primary>groups</primary></indexterm>Body</para>').to_tex
    assert_includes output, '\\seeCLLgeneral[{masses}]{masses}{groups}'
    refute_includes output, '{\\it groups}'
  end

  def test_index_see_target_with_special_character_matches_headword
    output = book('<para><indexterm type="general"><primary>R&amp;D</primary></indexterm>' \
                  '<indexterm type="general"><primary>research</primary><see>R&amp;D</see></indexterm>Body</para>').to_tex
    assert_includes output, '\\seeCLLgeneral[{research}]{research}{R\\letterampersand{}D}'
  end

  def test_index_see_target_hidden_only_fails_but_visible_twin_passes
    hidden = '<para role="display-none"><indexterm type="general"><primary>hiddenword</primary></indexterm>Hidden.</para>'
    assert_raises(RuntimeError) do
      book("<para><indexterm type=\"general\"><primary>alias</primary><see>hiddenword</see></indexterm>Visible.</para>#{hidden}").to_tex
    end
    output = book("<para><indexterm type=\"general\"><primary>alias</primary><see>hiddenword</see></indexterm>Visible.</para>" \
                  '<para><indexterm type="general"><primary>hiddenword</primary></indexterm>Also visible.</para>').to_tex
    assert_includes output, '\\seeCLLgeneral[{alias}]{alias}{hiddenword}'
  end

  def test_index_see_target_in_publication_notice_passes
    input = book(<<~XML)
      <info><title>Test</title>
        <othercredit><orgname role="publication-notice">Notice<indexterm type="general"><primary>hiddenword</primary></indexterm></orgname></othercredit>
      </info>
      <chapter><title>Targets</title>
        <para><indexterm type="general"><primary>alias</primary><see>hiddenword</see></indexterm></para>
      </chapter>
    XML
    output = input.to_tex
    assert_includes output, '\\seeCLLgeneral[{alias}]{alias}{hiddenword}'
    assert_empty input.report['missing_references']
  end

  def test_index_see_target_in_chapter_info_title_passes
    input = book(<<~XML)
      <chapter><info><title>Targets<indexterm type="general"><primary>hiddenword</primary></indexterm></title></info>
        <para><indexterm type="general"><primary>alias</primary><see>hiddenword</see></indexterm></para>
      </chapter>
    XML
    output = input.to_tex
    assert_includes output, '\\seeCLLgeneral[{alias}]{alias}{hiddenword}'
    assert_empty input.report['missing_references']
  end

  def test_index_see_target_in_literallayout_fails
    assert_raises(RuntimeError) do
      book('<chapter><title>Targets</title>' \
           '<para><indexterm type="general"><primary>alias</primary><see>hiddenword</see></indexterm></para>' \
           '<literallayout>Hidden<indexterm type="general"><primary>hiddenword</primary></indexterm></literallayout></chapter>').to_tex
    end
  end

  def test_index_two_seealso_targets_keep_page_entry_and_flag
    output = book('<para><indexterm type="general"><primary>related</primary><seealso>alpha</seealso><seealso>beta</seealso></indexterm>' \
                  '<indexterm type="general"><primary>alpha</primary></indexterm>' \
                  '<indexterm type="general"><primary>beta</primary></indexterm>Body</para>').to_tex
    assert_includes output, '\\seeCLLgeneral[{related}]{CLLseealso->related}{alpha}'
    assert_includes output, '\\seeCLLgeneral[{related}]{CLLseealso->related}{beta}'
    assert_match(/\\CLLgeneral\[\{related\}\]\{related\}(?!\{)/, output)
  end

  def test_bridgehead_own_id_lives_only_in_the_reference_field
    input = book(<<~XML)
      <chapter><title>Catalog</title>
        <bridgehead id="bh" xreflabel="BH">Head</bridgehead>
        <para>See <xref linkend="bh"/>.</para>
      </chapter>
    XML
    output = input.to_tex
    key = "cll-#{Digest::SHA256.hexdigest('bh')[0, 24]}"
    assert_includes output, "\\subsubject[title={Head},reference={#{key}}]"
    refute_includes output, "\\reference[#{key}]"
    assert_empty input.report['missing_references']
  end

  def test_index_see_target_without_headword_fails
    assert_raises(RuntimeError) do
      book('<para><indexterm type="general"><primary>widgets</primary><see>gadgets</see></indexterm>Body</para>').to_tex
    end
    assert_raises(RuntimeError) do
      book('<para><indexterm type="lojban-word"><primary>wordrelated</primary><seealso>missing</seealso></indexterm>Body</para>').to_tex
    end
  end

  def test_bridgehead_index_entries_leave_the_title
    input = book(<<~XML)
      <chapter><title>Catalog</title>
        <bridgehead><anchor id="BE" xreflabel="BE"/>selma'o BE<indexterm type="general"><primary>selmao</primary></indexterm></bridgehead>
        <para>Attach with <xref linkend="BE"/>.</para>
      </chapter>
    XML
    output = input.to_tex
    key = "cll-#{Digest::SHA256.hexdigest('BE')[0, 24]}"
    assert_includes output, "\\subsubject[title={selma'o BE},reference={#{key}}]\n\\CLLgeneral[{selmao}]{selmao}"
    refute_match(/title=\{[^}]*CLLgeneral/, output)
    assert_empty input.report['missing_references']
  end

  def test_unsupported_content_fails_instead_of_disappearing
    assert_raises(RuntimeError) { book('<new-semantic-element>Important</new-semantic-element>').to_tex }
    assert_raises(RuntimeError) { book('<mediaobject><imageobject><imagedata fileref="../../secret"/></imageobject></mediaobject>').to_tex }
    assert_raises(RuntimeError) { book('<para xml:id="same"/><para xml:id="same"/>') }
  end

  def test_status_note_renders_label_also_date_and_glyph
    output = book(<<~XML).to_tex
      <chapter><title>Status</title>
      <para role="status-note" condition="status:bpfk-approved;also:historical;date:2015-08-08">Dotside note prose.</para>
      <para role="status-note">Bare note prose.</para>
      </chapter>
    XML
    assert_includes output, '\\startCLLstatus \\dontleavehmode{\\hbox to 0pt{\\hss ●\\hskip.75em}}{\\sc Approved by the BPFK, 2015-08-08}\\crlf {\\tfx also: First-edition rule}\\crlf Dotside note prose.'
    assert_includes output, '\\startCLLstatus \\dontleavehmode{\\hbox to 0pt{\\hss ◆\\hskip.75em}} Bare note prose.'
  end

  def test_status_note_explicit_body_and_extra_role_token
    output = book(<<~XML).to_tex
      <chapter><title>Status</title>
      <para role="status-note" condition="status:proposed;body:bpfk">BPFK proposal prose.</para>
      <para role="extra status-note" condition="status:checkpointed">Extra role prose.</para>
      </chapter>
    XML
    assert_includes output, '{\\sc Proposal, BPFK}'
    assert_includes output, '\\startCLLstatus \\dontleavehmode{\\hbox to 0pt{\\hss ■\\hskip.75em}}{\\sc BPFK checkpoint}\\crlf Extra role prose.'
  end

  def test_status_note_trims_leading_whitespace_and_metadata_gap
    output = book(<<~XML).to_tex
      <chapter><title>Status</title>
      <para role="status-note" condition="status:de-facto">
        <indexterm type="general"><primary>entry</primary></indexterm>
        Padded prose.</para>
      </chapter>
    XML
    assert_includes output, '{entry}]{entry}Padded prose.'
  end

  def test_unknown_status_token_keeps_raw_label_and_bare_glyph
    output = book('<para role="status-note" condition="status:invented">Mystery prose.</para>').to_tex
    assert_includes output, '\\startCLLstatus \\dontleavehmode{\\hbox to 0pt{\\hss ◆\\hskip.75em}}{\\sc invented}\\crlf Mystery prose.'
    output = book('<para role="status-note" condition="status:de-facto;status:proposed">First wins.</para>').to_tex
    assert_includes output, '{\\sc Established usage}'
    output = book('<para role="status-note">Bare mark <phrase role="status-mark">clause</phrase>.</para>').to_tex
    assert_includes output, '\\underdots{clause}{\\high{ ◇}}'
    output = book('<para>Ordinary <phrase role="status-mark" condition="status:invented">clause</phrase>.</para>').to_tex
    assert_includes output, '{\\high{ {\\sc[invented]}◇}}'
  end

  def test_status_mark_renders_short_label_and_glyph
    output = book('<chapter><title>Status</title><para>Ordinary <phrase role="status-mark" condition="status:de-facto;also:historical">accepted by parsers</phrase> here.</para></chapter>').to_tex
    assert_includes output, '\\underdots{accepted by parsers}'
    # The space before the group is explicit: TeX would swallow a space
    # after \sc as the control word's delimiter, fusing the clause and
    # the label. Check the built PDF text for 'syllabic [Established'.
    assert_includes output, '{\\high{ {\\sc[Established usage]}◆}}'
  end

  def test_status_and_special_fonts_and_missing_reference_report
    input = book('<para role="status-note">Status <phrase xml:lang="zlm">glyph</phrase><phrase xml:lang="ko">한국</phrase><phrase xml:lang="zh">中文</phrase><xref linkend="outside"/></para>')
    output = input.to_tex
    assert_includes output, '\\startCLLstatus'
    %w[CLLcrisa CLLkorean CLLchinese].each { |font| assert_includes output, "\\#{font}" }
    assert_equal ['outside'], input.report['missing_references']
  end
end
