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

  def convert(body, info: nil, **options)
    Dir.mktmpdir('convert-', TMP) do |dir|
      path = File.join(dir, 'input.xml')
      xml = book(body)
      xml = xml.sub(/<info>.*?<\/info>/m, info) if info
      File.write(path, xml)
      return DocBookTypst.new(path, **options).convert
    end
  end

  def test_title_page_keeps_notice_and_corner_labels_separate
    info = <<~XML
      <info><title>Title</title><subtitle>Subtitle</subtitle>
      <author><personname><firstname>Ada</firstname></personname></author>
      <othercredit><orgname>revised by the community</orgname></othercredit>
      <releaseinfo><phrase role="release-version">edition-1.2.3+abc1234</phrase><phrase role="release-separator"> │ </phrase><phrase role="release-date">2026-10-27</phrase></releaseinfo>
      <othercredit><orgname role="publication-notice">(not an official publication)<phrase role="publication-disclaimer">A separate disclaimer.</phrase></orgname></othercredit></info>
    XML
    source = convert('<chapter><title>Chapter</title></chapter>', info: info)
    assert_includes source, '#cll-title("Title", "Subtitle", "Ada", ("revised by the community",), version: "edition-1.2.3+abc1234", date: "2026-10-27", notice: "(not an official publication)", disclaimer: "A separate disclaimer.")'
    refute_includes source, ' │ '
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

  def test_appendices_use_letters_in_headings_sections_examples_and_references
    source = convert('<appendix id="a"><title>First</title><section id="s"><title>Topic</title><example id="e"><title/><para>Text</para></example><para><xref linkend="a"/> <xref linkend="s"/> <xref linkend="e"/></para></section></appendix><appendix id="b"><title>Second</title></appendix>')
    assert_includes source, '#cll-heading(1, "Appendix A", "First"'
    assert_includes source, '#cll-heading(1, "Appendix B", "Second"'
    assert_includes source, '#cll-heading(2, "A.1", "Topic"'
    assert_includes source, '#cll-example("A.1"'
    assert_includes source, '#cll-ref("a", "Appendix A")'
    assert_includes source, '#cll-ref("s", "Section A.1")'
    assert_includes source, '#cll-ref("e", "Example A.1")'
  end

  def test_appendix_letters_do_not_share_the_article_counter
    source = convert('<article id="article"><title>Article</title><section id="as"><title>ArtSec</title><example id="ae"><title/><para>T</para></example></section><para><xref linkend="article"/></para></article><appendix id="appendix"><title>Appendix</title><section id="section"><title>Topic</title></section><para><xref linkend="appendix"/></para></appendix>')
    assert_includes source, '#cll-heading(1, "", "Article"'
    assert_includes source, '#cll-heading(2, "1", "ArtSec"'
    assert_includes source, '#cll-example("1"'
    assert_includes source, '#cll-ref("article", "Article")'
    assert_includes source, '#cll-heading(1, "Appendix A", "Appendix"'
    assert_includes source, '#cll-heading(2, "A.1", "Topic"'
    assert_includes source, '#cll-ref("appendix", "Appendix A")'
  end

  def test_appendix_letters_continue_past_z_as_aa_ab
    appendices = (1..28).map do |i|
      "<appendix id=\"app#{i}\"><title>App #{i}</title><section id=\"sec#{i}\"><title>S #{i}</title><example id=\"ex#{i}\"><title/><para>E</para></example></section><para><xref linkend=\"app#{i}\"/> <xref linkend=\"sec#{i}\"/></para></appendix>"
    end.join
    source = convert(appendices)
    assert_includes source, '#cll-heading(1, "Appendix Z", "App 26"'
    assert_includes source, '#cll-heading(1, "Appendix AA", "App 27"'
    assert_includes source, '#cll-heading(1, "Appendix AB", "App 28"'
    assert_includes source, '#cll-heading(2, "AA.1", "S 27"'
    assert_includes source, '#cll-example("AA.1"'
    assert_includes source, '#cll-ref("app27", "Appendix AA")'
    assert_includes source, '#cll-ref("sec27", "Section AA.1")'
    refute_includes source, 'Appendix ['
  end

  def test_fraction_powers_and_radicals_use_native_math
    source = convert('<chapter><title>Math</title><para><inlineequation><math><mfrac><msup><mi>x</mi><mn>2</mn></msup><msqrt><mn>7</mn></msqrt></mfrac></math></inlineequation></para></chapter>')
    assert_includes source, '$frac(attach(x, t: 2), sqrt(7))$'
    assert_raises(RuntimeError) { convert('<chapter><title>Bad</title><para><math><unsupported/></math></para></chapter>') }
  end

  def test_math_factors_and_connecting_words
    source = convert('<chapter><title>Math</title><para><math><mo>Iff </mo><mn>4</mn><mo>&#x2062;</mo><mi>a</mi><mo>&#x2062;</mo><mi>c</mi><mo>=</mo><mn>0</mn><mo>, then </mo><mi>x</mi><mo>=</mo><mfrac><mn>1</mn><mrow><mn>2</mn><mi>a</mi></mrow></mfrac></math></para></chapter>')
    assert_includes source, '$upright("Iff") 4 a c = 0 \\, quad upright("then") x = frac(1, 2 a)$'
    refute_includes source, 'italic("a")'
    refute_includes source, '"4"'
    assert_raises(RuntimeError) { convert('<chapter><title>Math</title><para><math><mi>eval</mi></math></para></chapter>') }
    assert_raises(RuntimeError) { convert('<chapter><title>Math</title><para><math><mn>#eval</mn></math></para></chapter>') }
  end

  def test_glossary_subscripts_keep_the_whole_base
    source = convert('<chapter><title>Math</title><para><math xmlns="http://www.w3.org/1998/Math/MathML"><msub><mrow><mi>c</mi><mi>i</mi></mrow><mn>1</mn></msub><mo>=</mo><msub><mi>x</mi><mn>2</mn></msub><msub><mrow/><mn>3</mn></msub></math></para></chapter>')
    assert_includes source, '$attach(c i, b: 1) = attach(x, b: 2) attach(#[], b: 3)$'
  end

  def test_script_bases_accept_both_empty_spellings
    ['<mi/>', '<mrow/>'].each do |base|
      source = convert("<chapter><title>Math</title><para><math><msub>#{base}<mn>3</mn></msub><msup>#{base}<mn>4</mn></msup><msubsup>#{base}<mn>3</mn><mn>4</mn></msubsup></math></para></chapter>")
      assert_includes source, '$attach(#[], b: 3) attach(#[], t: 4) attach(#[], b: 3, t: 4)$'
    end
    assert_raises(RuntimeError) { convert('<chapter><title>Math</title><para><math><mi/></math></para></chapter>') }
  end

  def test_native_math_spacing_matches_handwritten_math
    executable = ENV['TYPST']
    skip 'Set TYPST to run the native math spacing test.' unless executable
    source = convert('<chapter><title>Math</title><para><math><mn>4</mn><mi>a</mi><mi>c</mi></math></para></chapter>')
    generated = source[/\$([^$]+)\$/, 1]
    Dir.mktmpdir('math-spacing-', TMP) do |dir|
      path = File.join(dir, 'spacing.typ')
      File.write(path, <<~TYPST)
        #show math.equation: set text(font: "New Computer Modern Math")
        #context {
          let expected = measure($4 a c$).width
          assert(calc.abs(measure($#{generated}$).width - expected) < 0.001pt)
          assert(measure($"4" italic("a") italic("c")$).width > expected + 1pt)
        }
      TYPST
      _, err, status = Open3.capture3(executable, 'compile', '--ignore-system-fonts', path, File.join(dir, 'spacing.pdf'))
      assert status.success?, err
      assert_empty err
    end
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

  def test_status_note_renders_label_also_date_and_glyph
    source = convert('<chapter><title>Status</title><para role="status-note" condition="status:bpfk-approved;also:historical;date:2015-08-08">Dotside note prose.</para><para role="status-note">Bare note prose.</para></chapter>')
    assert_includes source, '#cll-status(token: "bpfk-approved", glyph: "●", label: "Approved by the BPFK, 2015-08-08", also: "also: First-edition rule")'
    assert_includes source, 'Dotside note prose.'
    assert_includes source, '#cll-status[#text("Bare note prose.")]'
  end

  def test_status_note_explicit_body_and_extra_role_token
    source = convert('<chapter><title>Status</title><para role="status-note" condition="status:proposed;body:bpfk">BPFK proposal prose.</para><para role="extra status-note" condition="status:checkpointed">Extra role prose.</para></chapter>')
    assert_includes source, 'label: "Proposal, BPFK"'
    assert_includes source, 'glyph: "■"'
    assert_includes source, 'token: "checkpointed"'
  end

  def test_status_mark_renders_short_label_and_glyph
    source = convert('<chapter><title>Status</title><para>Ordinary <phrase role="status-mark" condition="status:de-facto;also:historical">accepted by parsers</phrase> here.</para></chapter>')
    # Code-mode strings: markup-mode "..." would print as smart quotes.
    assert_includes source, "#super[#smallcaps(\"\u00A0[Established\u00A0usage]\")#text(\"◆\")]"
    refute_includes source, '#box['
  end

  def test_status_mark_historical_label_uses_nonbreaking_hyphen
    source = convert('<chapter><title>Status</title><para>So <phrase role="status-mark" condition="status:historical">this applies</phrase> here.</para></chapter>')
    assert_includes source, "#super[#smallcaps(\" [First‑edition rule]\")#text(\"◇\")]"
    refute_includes source, 'First-edition'
  end

  def test_status_note_trims_leading_whitespace
    source = convert("<chapter><title>Status</title><para role=\"status-note\" condition=\"status:de-facto\">\n  <indexterm type=\"general\"><primary>entry</primary></indexterm>\n  Padded prose.</para></chapter>")
    assert_includes source, '#text("Padded prose.")]'
    refute_includes source, '#text(" '
  end

  def test_status_unknown_token_keeps_raw_label_and_bare_glyph
    source = convert('<chapter><title>Status</title><para role="status-note" condition="status:invented">Mystery prose.</para><para>Ordinary <phrase role="status-mark" condition="status:invented">clause</phrase> and <phrase role="status-mark">bare</phrase>.</para></chapter>')
    assert_includes source, 'label: "invented"'
    assert_includes source, "#super[#text(\"\u00A0◇\")]"
    assert_includes source, "#super[#smallcaps(\"\u00A0[invented]\")#text(\"◇\")]"
    refute_includes source, '#box['
  end

  def test_native_compilation_with_outline_links_and_indexes
    executable = ENV['TYPST']
    skip 'Set TYPST to run the native compilation test.' unless executable
    source = convert('<chapter id="c"><title><anchor id="alias"/>A chapter</title><section id="s"><title>Section</title><para><indexterm type="general"><primary>fraction</primary></indexterm><xref linkend="alias"/> <inlineequation><math><mfrac><mn>2</mn><mn>7</mn></mfrac></math></inlineequation></para><para role="status-note" condition="status:de-facto;also:historical;date:2015-08-08">Usage note prose.</para><para role="status-note">Bare note.</para><para>Ordinary <phrase role="status-mark" condition="status:de-facto">accepted by parsers</phrase> here.</para></section></chapter>')
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

  def test_compiled_inline_mark_has_plain_label_text
    # Markup-mode "..." in the super would print as smart quotes around
    # the label and glyph; the converter must emit code-mode strings.
    # Needs pdftotext, which the CI smoke job installs.
    executable = ENV['TYPST']
    skip 'Set TYPST to run the native compilation test.' unless executable
    skip 'Install poppler-utils to check rendered text.' unless system('command -v pdftotext >/dev/null 2>&1')
    source = convert('<chapter><title>Status</title><para>Ordinary <phrase role="status-mark" condition="status:de-facto">accepted by parsers</phrase> here.</para></chapter>')
    Dir.mktmpdir('compile-', TMP) do |dir|
      File.write(File.join(dir, 'cll.typ'), source)
      FileUtils.cp(File.expand_path('../typst/book.typ', __dir__), dir)
      fonts = File.expand_path('../assets/fonts', __dir__)
      pdf = File.join(dir, 'cll.pdf')
      _, err, status = Open3.capture3(executable, 'compile', '--ignore-system-fonts', '--font-path', fonts, File.join(dir, 'cll.typ'), pdf)
      assert status.success?, err
      text, serr, tstatus = Open3.capture3('pdftotext', '-layout', pdf, '-')
      assert tstatus.success?, serr
      text = text.gsub(/\s+/, ' ')
      assert_includes text, 'accepted by parsers [Established usage]◆'
      refute_match(/[“”]/, text)
    end
  end

  def test_compiled_historical_mark_never_splits_at_hyphen
    # The hyphen in "First-edition rule" is a line-break opportunity even
    # with hyphenation off; the converter emits U+2011 so the inline label
    # stays whole. Needs pdftotext, which the CI smoke job installs.
    executable = ENV['TYPST']
    skip 'Set TYPST to run the native compilation test.' unless executable
    skip 'Install poppler-utils to check rendered text.' unless system('command -v pdftotext >/dev/null 2>&1')
    paras = [8, 9, 10].map do |n|
      %(<para>#{'word ' * n}so this alternative never <phrase role="status-mark" condition="status:historical">applies here today</phrase> in every case.</para>)
    end
    source = convert("<chapter><title>Status</title>#{paras.join}</chapter>")
    Dir.mktmpdir('compile-', TMP) do |dir|
      File.write(File.join(dir, 'cll.typ'), source)
      FileUtils.cp(File.expand_path('../typst/book.typ', __dir__), dir)
      fonts = File.expand_path('../assets/fonts', __dir__)
      pdf = File.join(dir, 'cll.pdf')
      _, err, status = Open3.capture3(executable, 'compile', '--ignore-system-fonts', '--font-path', fonts, File.join(dir, 'cll.typ'), pdf)
      assert status.success?, err
      text, serr, tstatus = Open3.capture3('pdftotext', '-layout', pdf, '-')
      assert tstatus.success?, serr
      lines = text.split("\n").map(&:strip)
      assert_empty lines.select { |l| l.end_with?('[First-') }
      assert_empty lines.select { |l| l.start_with?('edition') }
      collapsed = text.gsub(/\s+/, ' ')
      assert_equal 3, collapsed.scan("[First‑edition rule]◇").length
      refute_match(/\[First- /, collapsed)
    end
  end

  def test_compiled_outline_keeps_chapter_and_appendix_on_one_line
    # Issue #338: level-1 headings put a linebreak between "Chapter N" /
    # "Appendix A" and the title, which should not split their ToC entries
    # across two lines.
    executable = ENV['TYPST']
    skip 'Set TYPST to run the native compilation test.' unless executable
    skip 'Install poppler-utils to check rendered text.' unless system('command -v pdftotext >/dev/null 2>&1')
    source = convert('<chapter><title>Opening Chapter</title><para>Body.</para></chapter><appendix><title>Chrestomathy</title><para>Text.</para></appendix>')
    Dir.mktmpdir('compile-', TMP) do |dir|
      File.write(File.join(dir, 'cll.typ'), source)
      FileUtils.cp(File.expand_path('../typst/book.typ', __dir__), dir)
      fonts = File.expand_path('../assets/fonts', __dir__)
      pdf = File.join(dir, 'cll.pdf')
      _, err, status = Open3.capture3(executable, 'compile', '--ignore-system-fonts', '--font-path', fonts, File.join(dir, 'cll.typ'), pdf)
      assert status.success?, err
      text, serr, tstatus = Open3.capture3('pdftotext', '-layout', pdf, '-')
      assert tstatus.success?, serr
      toc_page = text.split("\f")[1].to_s
      toc_lines = toc_page.lines.map(&:strip).reject(&:empty?)
      assert toc_lines.any? { |l| l.include?('Chapter 1') && l.include?('Opening Chapter') },
             "Expected Chapter 1 and title on one ToC line:\n#{toc_page}"
      assert toc_lines.any? { |l| l.include?('Appendix A') && l.include?('Chrestomathy') },
             "Expected Appendix A and title on one ToC line:\n#{toc_page}"
    end
  end

  def test_glossterm_in_table_cell_links_to_glossary_entry
    # xml_preprocess.rb links each cmavo-list word with the same glossterm
    # markup a <valsi> gets; the converter turns that link into a Typst
    # link without any table-specific code.
    source = convert('<chapter id="c"><title>C</title><informaltable><colgroup/><tbody><tr><td class="cmavo"><para role="cmavo"><foreignphrase xml:lang="jbo"><glossterm role="valsi" linkend="valsi-mi">mi</glossterm></foreignphrase></para></td></tr></tbody></informaltable><glossary><title>G</title><glossdiv><title>M</title><glossentry xml:id="valsi-mi"><glossterm>mi</glossterm><glossdef><para>I</para></glossdef></glossentry></glossdiv></glossary></chapter>')
    assert_includes source, '#link(label("valsi-mi"))'
  end

  def test_role_matching_uses_token_membership
    source = convert(<<~XML)
      <chapter id="c"><title>Roles</title>
      <section id="s"><title>Sec</title>
      <para>First.</para>
      <para role=" extra noindent ">Flush <emphasis role=" extra bold ">strong</emphasis> <phrase role="extra X-SAMPA">ipa</phrase></para>
      <para role=" extra display-none "><indexterm type="general"><primary>hiddenrole</primary></indexterm>Hidden</para>
      <itemizedlist role=" extra bullets "><listitem><para>One</para></listitem></itemizedlist>
      <itemizedlist role="not-bullets"><listitem><para>Two</para></listitem></itemizedlist>
      <informaltable><tr class="extra jbo"><td>mi</td></tr><tr class="gloss extra"><td>I</td></tr><tr class="not-jbo"><td>plain</td></tr></informaltable>
      </section>
      </chapter>
    XML
    assert_includes source, '#cll-par(indent: false)[#text("Flush ")#strong[#text("strong")]'
    assert_includes source, '#text(font: "DejaVu Sans Mono")[#text("ipa")]'
    refute_includes source, 'Hidden'
    refute_includes source, 'hiddenrole'
    assert_includes source, '#cll-list(kind: "bullets"'
    assert_includes source, '#cll-list(kind: "plain"'
    assert_includes source, '#emph[#text("mi")]'
    assert_includes source, '#strong[#text("I")]'
    refute_includes source, '#emph[#text("plain")]'
  end
end
