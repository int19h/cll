#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative 'docbook_to_typst'

class DocBookTypstTest < Minitest::Test
  TMP = File.expand_path('../build/typst-tests', __dir__)
  FileUtils.mkdir_p(TMP)
  def book(body)
    <<~XML
      <book><info><title>Test Book</title><author><personname><firstname>Ada</firstname></personname></author></info>
      #{body}<index type="general"><title>General Index</title></index></book>
    XML
  end

  def convert(body, **options)
    Dir.mktmpdir('convert-', TMP) do |dir|
      path = File.join(dir, 'input.xml')
      File.write(path, book(body))
      return DocBookTypst.new(path, **options).convert
    end
  end

  def test_text_is_escaped_and_entities_keep_their_meaning
    source = convert('<chapter id="c"><title>Chapter</title><para>Literal #eval(&quot;bad&quot;) [x] $a$ &amp; \\ file.</para></chapter>')
    assert_includes source, '#text("Literal #eval(\\"bad\\") [x] $a$ &'
  end

  def test_ids_numbering_and_custom_reference_labels
    source = convert('<chapter id="c"><title><anchor id="alias"/>First</title><section id="s"><title>Section</title><example id="e"><title/><para>Text</para></example><para><xref linkend="e"/> <xref linkend="rule"/></para><bridgehead><anchor id="rule" xreflabel="BNF rule #42"/>Rule</bridgehead></section></chapter>')
    assert_includes source, '#cll-ref("e", "Example 1.1")'
    assert_includes source, '#cll-ref("rule", "BNF rule #42")'
    assert_includes source, 'marks: [#metadata(none)#label("c")#metadata(none)#label("alias")]'
    assert_equal 1, source.scan('#label("alias")').size
  end

  def test_fraction_powers_and_radicals_use_native_math
    source = convert('<chapter><title>Math</title><para><inlineequation><math><mfrac><msup><mi>x</mi><mn>2</mn></msup><msqrt><mn>7</mn></msqrt></mfrac></math></inlineequation></para></chapter>')
    assert_includes source, '$frac(attach(italic("x"), t: "2"), sqrt("7"))$'
    assert_raises(RuntimeError) { convert('<chapter><title>Bad</title><para><math><unsupported/></math></para></chapter>') }
  end

  def test_zero_span_uses_actual_table_width
    source = convert('<chapter><title>Tables</title><informaltable><tr><td>one</td><td>two</td><td>three</td></tr><tr><td colspan="0">translation</td></tr></informaltable></chapter>')
    assert_includes source, '#cll-table(3,'
    assert_includes source, 'x: 0, y: 1, colspan: 3'
    refute_includes source, '12321'
  end

  def test_indexes_preserve_terms_and_exclude_hidden_content
    source = convert('<chapter><title>Index</title><para><indexterm type="general"><primary>alpha</primary><secondary>beta</secondary></indexterm>Text</para><para role="display-none"><indexterm type="general"><primary>hidden</primary></indexterm>Hidden</para></chapter>')
    assert_includes source, '\\"alpha\\",\\"beta\\"'
    assert_includes source, 'depth: 1'
    refute_includes source, 'hidden'
    assert_includes convert('<chapter><title>Empty</title></chapter>'), '#cll-index(())'
  end

  def test_unknown_markup_and_unresolved_references_fail_closed
    assert_raises(RuntimeError) { convert('<chapter><title>Unknown</title><invented>Lost text</invented></chapter>') }
    assert_raises(RuntimeError) { convert('<chapter><title>Missing</title><para><xref linkend="absent"/></para></chapter>') }
    assert_raises(RuntimeError) { convert('<chapter id="same"><title>A</title><para id="same">B</para></chapter>') }
    out, err = capture_io do
      result = convert('<chapter><title>Excerpt</title><para><xref linkend="absent"/></para></chapter>', allow_missing: true)
      assert_includes result, 'outside this excerpt'
      refute_includes result, 'label("absent")'
    end
    assert_empty out
    assert_includes err, 'Reference outside this excerpt: absent'
  end

  def test_list_paragraph_whitespace_keeps_inline_spaces_and_anchors
    source = convert('<chapter id="c"><title>Lists</title><itemizedlist role="bullets"><listitem><para>  <anchor id="item"/><indexterm type="general"><primary>entry</primary></indexterm>  <emphasis> First </emphasis> second <xref linkend="c"/> </para></listitem></itemizedlist><orderedlist><listitem><para> Numbered </para></listitem></orderedlist><example><title/><itemizedlist><listitem><para> Plain </para></listitem></itemizedlist></example></chapter>')
    assert_includes source, '#cll-list(kind: "bullets", in-example: false,'
    assert_includes source, '#cll-list(kind: "numbered", in-example: false,'
    assert_includes source, '#cll-list(kind: "plain", in-example: true,'
    assert_includes source, '#emph[#text("First ")]#text(" second ")#cll-ref("c", "Chapter 1")'
    assert_includes source, '#label("item")'
    assert_includes source, '#text("Numbered")'
    assert_includes source, '#text("Plain")'
    refute_includes source, '#text("  ")'
  end

  def test_native_compilation_with_outline_links_and_indexes
    executable = ENV['TYPST']
    skip 'Set TYPST to run the native compilation test.' unless executable
    source = convert('<chapter id="c"><title><anchor id="alias"/>A chapter</title><section id="s"><title>Section</title><para><indexterm type="general"><primary>fraction</primary></indexterm><xref linkend="alias"/> <inlineequation><math><mfrac><mn>2</mn><mn>7</mn></mfrac></math></inlineequation></para></section></chapter>')
    Dir.mktmpdir('compile-', TMP) do |dir|
      File.write(File.join(dir, 'cll.typ'), source)
      FileUtils.cp(File.expand_path('../typst/book.typ', __dir__), dir)
      fonts = File.expand_path('../assets/fonts', __dir__)
      _, err, status = Open3.capture3(executable, 'compile', '--ignore-system-fonts', '--font-path', fonts, File.join(dir, 'cll.typ'), File.join(dir, 'cll.pdf'))
      assert status.success?, err
      assert_empty err
      assert File.size(File.join(dir, 'cll.pdf')) > 1000
    end
  end
end
