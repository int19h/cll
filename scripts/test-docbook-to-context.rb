#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'docbook_to_context'

class ContextBookTest < Minitest::Test
  def book(content)
    ContextBook.new(Nokogiri::XML("<book xmlns:xml='http://www.w3.org/XML/1998/namespace'>#{content}</book>") { |c| c.strict })
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
    assert_match(/\\CLLgeneral\{first\}\\reference\[[^\]]+\]\{[^}]*\}First two words /, output)
    assert_includes output, 'words \\CLLgeneral{middle} stay apart.'
  end

  def test_index_hierarchy_and_literal_plus
    output = book('<para><indexterm type="general"><primary>a+b</primary><secondary>detail</secondary></indexterm>Body</para>').to_tex
    assert_includes output, '\\CLLgeneral{a\\char43{}b+detail}'
    assert_includes output, 'Body'
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

  def test_unsupported_content_fails_instead_of_disappearing
    assert_raises(RuntimeError) { book('<new-semantic-element>Important</new-semantic-element>').to_tex }
    assert_raises(RuntimeError) { book('<mediaobject><imageobject><imagedata fileref="../../secret"/></imageobject></mediaobject>').to_tex }
    assert_raises(RuntimeError) { book('<para xml:id="same"/><para xml:id="same"/>') }
  end

  def test_status_and_special_fonts_and_missing_reference_report
    input = book('<para role="status-note">Status <phrase xml:lang="zlm">glyph</phrase><phrase xml:lang="ko">한국</phrase><phrase xml:lang="zh">中文</phrase><xref linkend="outside"/></para>')
    output = input.to_tex
    assert_includes output, '\\startCLLstatus'
    %w[CLLcrisa CLLkorean CLLchinese].each { |font| assert_includes output, "\\#{font}" }
    assert_equal ['outside'], input.report['missing_references']
  end
end
