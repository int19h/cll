#!/usr/bin/env ruby
# Formatter and whitespace guard (issue #207).
# Run from anywhere: ruby scripts/test-html-format.rb

require 'minitest/autorun'
require 'nokogiri'
require 'open3'
require 'shellwords'
require 'tempfile'

ROOT = File.expand_path('..', __dir__)
require File.join(ROOT, 'scripts/html_format')
require File.join(ROOT, 'scripts/html_whitespace_guard')

DOCTYPE = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "dtd/xhtml1-transitional.dtd">'

def page(body, head: '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /><title>T</title>')
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    #{DOCTYPE}
    <html xmlns="http://www.w3.org/1999/xhtml"><head>#{head}</head><body>#{body}</body></html>
  XML
end

def parsed(text)
  Nokogiri::XML(text) { |config| config.strict.nonet }
end

def formatted(text)
  doc = parsed(text)
  HtmlFormat.format!(doc)
  HtmlFormat.write(doc)
end

def unformatted(text)
  HtmlFormat.write(parsed(text))
end

# Keep the document serialization. A node-level write drops the XHTML
# empty-element rules (<br />, <td></td>) that the formatter relies on.
def body_of(text)
  match = text.match(%r{<body\b[^>]*>.*</body>}m)
  raise "no body in:\n#{text}" unless match
  match[0]
end

# The ePub test runs the packager's real HTML edits, not a copy of them.
def packager_html_edits
  text = File.read(File.join(ROOT, 'scripts/build_epub.sh'))
  match = text.match(/for file in \$\(find \$epubbuilddir\/ -name '\*\.html'\)\ndo\n(.*?)\ndone\n/m)
  raise 'packager HTML loop not found in scripts/build_epub.sh' unless match
  match[1]
end

class HtmlFormatContract < Minitest::Test
  def assert_guard(before, after, name: 'fixture')
    HtmlWhitespaceGuard.compare!(before, after, name: name)
  end

  def assert_safe(source)
    plain = unformatted(source)
    pretty = formatted(source)
    assert_guard(plain, pretty)
    assert_equal pretty, formatted(pretty), pretty
    pretty.lines.each do |line|
      refute line.end_with?(" \n") || line.end_with?(' '), "trailing space: #{line.inspect}"
      refute_match(/\A +\n?\z/, line, "space-only line: #{line.inspect}")
    end
    assert pretty.end_with?("\n")
    pretty
  end

  def test_element_lists_match_the_guard
    assert_equal HtmlFormat::BLOCK, HtmlWhitespaceGuard::BLOCK
    assert_equal HtmlFormat::ELEMENT_ONLY, HtmlWhitespaceGuard::ELEMENT_ONLY
    assert_equal HtmlFormat::VERBATIM, HtmlWhitespaceGuard::VERBATIM
    assert_equal HtmlFormat::WIDE_RANGES, HtmlWhitespaceGuard::WIDE_RANGES
    assert_equal HtmlFormat::ZWSP, HtmlWhitespaceGuard::ZWSP
  end

  def test_paragraph_edges_hug_or_separate
    hugged = assert_safe(page('<p>alpha <em>beta</em> gamma</p>'))
    assert_includes body_of(hugged), '<p>alpha <em>beta</em> gamma</p>'

    edged = assert_safe(page("<p> alpha <em>beta</em> gamma </p>"))
    assert_includes body_of(edged), "<p>\n"
    assert_includes body_of(edged), "gamma\n"
    refute_includes body_of(edged), '<p> alpha'
    refute_includes body_of(edged), 'gamma </p>'
  end

  def test_inline_spaces_are_kept_and_not_invented
    source = page(<<~HTML)
      <p id="quotes"><a class="indexterm" id="index"/>the <span><em>error-correction quotes</em></span> <span>lo'ai</span>, sa'ai, and le'ai</p>
      <table><tr><td id="connective"><span>ga</span> <span>nai</span> - <span>gi</span></td></tr></table>
    HTML
    pretty = assert_safe(source)
    text = body_of(pretty)
    assert_includes text, '</a>the '
    assert_includes text, '</span> <span>lo\'ai</span>'
    assert_includes text, '<span>ga</span> <span>nai</span>'
    refute_includes text, '</span><span>lo'
    refute_includes text, '</span><span>nai'
  end

  def test_short_gloss_row_stays_one_line_and_a_long_row_breaks_by_cell
    short = assert_safe(page('<table class="interlinear-gloss"><tr class="jbo"><td>mi</td><td>klama</td><td>lo</td><td>zarci</td></tr></table>'))
    assert_includes body_of(short), '<tr class="jbo"><td>mi</td><td>klama</td><td>lo</td><td>zarci</td></tr>'

    cells = Array.new(12) { |index| %(<td id="c#{index}">#{'word' * 8}</td>) }.join
    long = assert_safe(page("<table><tr>#{cells}</tr></table>"))
    body = body_of(long)
    assert_includes body, "<tr>\n"
    refute_match(/<td[^>]*>[^<]*<\/td><td/, body)
  end

  def test_verbatim_regions_stay_byte_for_byte
    pre = "a\n  b  c"
    script = "if (a < b) {\n  x\n}"
    math = '<mi>x</mi> <mi>y</mi>'
    source = page(<<~HTML)
      <pre>#{pre}</pre>
      <script type="text/javascript">#{script.gsub('<', '&lt;')}</script>
      <math xmlns="http://www.w3.org/1998/Math/MathML">#{math}</math>
      <p xml:space="preserve">a  b</p>
    HTML
    pretty = assert_safe(source)
    doc = parsed(pretty)
    assert_equal pre, doc.at('pre').text
    assert_equal script, doc.at('script').text
    math_el = doc.at_xpath('//*[local-name()="math"]')
    assert_equal 'x y', math_el.text
    assert_includes math_el.children.map(&:to_s).join, '<mi>x</mi> <mi>y</mi>'
    assert_equal 'a  b', doc.at('p').text
  end

  def test_no_break_space_stays_whole
    nbsp = "\u00A0"
    pretty = assert_safe(page("<p>foo#{nbsp}bar baz</p>"))
    text = parsed(pretty).at('p').text
    assert_includes text, "foo#{nbsp}bar"
    refute_includes text, "foo\n"
    refute_includes text, "foo #{nbsp}"
  end

  def test_br_breaks_only_where_whitespace_already_exists
    joined = assert_safe(page('<p>foo<br/>bar</p>'))
    assert_includes body_of(joined), '<p>foo<br />bar</p>'

    split = assert_safe(page('<p>foo<br/> bar</p>'))
    assert_match(%r{<p>foo<br />\n +bar</p>}, body_of(split))

    hidden = assert_safe(page('<p>foo<br class="example-break"/> bar</p>'))
    hidden_body = body_of(hidden)
    assert_includes hidden_body, '<br class="example-break" /> bar'
    refute_match(%r{<br class="example-break" />\n}, hidden_body)

    table_break = assert_safe(page('<p>foo<br class="table-break"/> bar</p>'))
    refute_match(%r{<br class="table-break" />\n}, body_of(table_break))
  end

  def test_hidden_br_before_a_block_does_not_gain_a_line_break
    source = page("<div></div><br class=\"example-break\"/>\n<p>text</p>")
    pretty = assert_safe(source)
    body = body_of(pretty)
    refute_match(%r{<br class="example-break" />\n}, body)
    assert_match(%r{<br class="example-break" /> <p>text</p>}, body)
  end

  def test_empty_elements_and_a_single_space
    pretty = assert_safe(page('<table><tr><td></td><td> </td></tr></table><p> </p><p><a id="x"></a></p><p><br/><meta name="g" content="x"/></p>'))
    body = body_of(pretty)
    assert_includes body, '<td></td>'
    assert_includes body, '<td> </td>'
    assert_includes body, '<p> </p>'
    assert_includes body, '<a id="x"></a>'
    assert_includes body, '<br />'
    assert_includes body, '<meta name="g" content="x" />'
    refute_match(%r{<(?:a|p|td|span|div)(?: [^>]*)?/>}, body)
  end

  def test_second_run_matches_for_every_fixture
    fixtures = [
      page('<p>alpha <em>beta</em> gamma</p>'),
      page("<p> alpha </p>"),
      page('<table><tr><td>mi</td><td>klama</td></tr></table>'),
      page("<pre>a\n b</pre>"),
      page('<p>foo<br/> bar baz</p>'),
      page('<p>foo<br class="example-break"/> bar</p>')
    ]
    fixtures.each do |source|
      once = formatted(source)
      assert_equal once, formatted(once)
    end
  end

  def test_lines_do_not_end_with_a_space
    pretty = assert_safe(page('<p>one two three four five six seven eight nine ten eleven twelve thirteen fourteen</p>'))
    pretty.lines.each { |line| refute line.end_with?(" \n") }
  end

  def test_measured_lengths_match_the_writer_escapes
    samples = ['', 'plain', 'a & b', 'a < b > c', "a\n\tb  c", ' "quoted" ', '&amp;', "  \n"]
    rng = Random.new(207)
    30.times do
      samples << Array.new(rng.rand(0..50)) { [32, 9, 10, 13, 12, 38, 60, 62, 34, 97, 233].sample(random: rng) }.pack('U*')
    end
    samples.each do |text|
      assert_equal text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').length, HtmlFormat.text_length(text)
      assert_equal text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('"', '&quot;').length, HtmlFormat.escaped_attr_length(text)
      [true, false].each do |lead|
        [true, false].each do |trail|
          collapsed = text.gsub(/[ \t\n\r\f]+/, ' ')
          collapsed = collapsed.sub(/\A /, '') if lead
          collapsed = collapsed.sub(/ \z/, '') if trail
          assert_equal HtmlFormat.text_length(collapsed), HtmlFormat.collapsed_length(text, lead, trail), text.inspect
        end
      end
    end
  end

  def test_epub_line_contract
    head = '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /><title>Chapter</title><link rel="stylesheet" href="final.css" type="text/css" /><meta name="generator" content="DocBook" />'
    source = page('<h1 class="title"><a id="chapter"/>Chapter <a id="c1"/></h1><p summary="x">Reader text.</p>', head: head)
    pretty = assert_safe(source)
    lines = pretty.lines.map(&:rstrip)
    assert_equal '<?xml version="1.0" encoding="UTF-8"?>', lines[0]
    assert_equal DOCTYPE, lines[1]
    assert_match(/\A<html xmlns="http:\/\/www\.w3\.org\/1999\/xhtml">\z/, lines[2])
    meta_lines = pretty.lines.select { |line| line.include?('<meta ') }
    assert meta_lines.any?
    meta_lines.each do |line|
      assert_match(/\A *<meta [^>]+\/>\n\z/, line)
    end

    file = Tempfile.new(['epub-page', '.html'])
    file.write(pretty)
    file.close
    # A missed grep is the loop's last status. The packager continues after the loop.
    script = "set -e\nfile=#{Shellwords.escape(file.path)}\n#{packager_html_edits}\ntrue\n"
    _out, err, status = Open3.capture3('bash', '-c', script)
    assert status.success?, err
    edited = File.read(file.path)
    doc = parsed(edited)
    assert_equal 'Chapter', doc.at('title').text
    assert_equal 'final.css', doc.at('link')['href']
    assert_nil doc.at('meta')
    refute_includes edited, '<!DOCTYPE'
    refute_includes edited, 'summary='
  ensure
    file&.unlink
  end

  def test_css_does_not_preserve_whitespace
    Dir[File.join(ROOT, 'assets/css/*.css')].each do |path|
      text = File.read(path)
      match = text.match(/white-space\s*:\s*(pre-wrap|pre-line|break-spaces|pre)\b/)
      refute match, "#{path} uses white-space: #{match && match[1]}. Add that element to the verbatim list in scripts/html_format.rb"
    end
  end

  def test_none_mode_changes_no_gap
    source = page('<p id="quotes"><a class="indexterm" id="index"/>the <span>lo\'ai</span> <span>sa\'ai</span></p>')
    file = Tempfile.new(['cleanup', '.html'])
    file.write(source)
    file.close
    env = ENV.to_h.merge('CLL_HTML_FORMAT' => 'none')
    stdout, stderr, status = Open3.capture3(env, 'ruby', File.join(ROOT, 'scripts/xhtml_postprocess_cleanup_file.rb'), file.path, chdir: ROOT)
    assert status.success?, stderr
    HtmlWhitespaceGuard.compare!(source, stdout, name: file.path, strict: true)
  ensure
    file&.unlink
  end

  def test_unknown_format_mode_is_an_error
    file = Tempfile.new(['cleanup', '.html'])
    file.write(page('<p>text</p>'))
    file.close
    env = ENV.to_h.merge('CLL_HTML_FORMAT' => 'fancy')
    _stdout, stderr, status = Open3.capture3(env, 'ruby', File.join(ROOT, 'scripts/xhtml_postprocess_cleanup_file.rb'), file.path, chdir: ROOT)
    refute status.success?
    assert_includes stderr, 'CLL_HTML_FORMAT'
  ensure
    file&.unlink
  end

  def test_whitespace_only_element_collapses_to_one_space
    pretty = assert_safe(page("<p> \n\t </p><p></p>"))
    body = body_of(pretty)
    assert_includes body, '<p> </p>'
    assert_includes body, '<p></p>'
    refute_includes body, '<p>  '
  end

  def test_inline_children_of_a_container_keep_their_space
    listed = assert_safe(page('<ul><span>a</span> <span>b</span></ul>'))
    assert_includes body_of(listed), '</span> <span>b</span>'
    row = assert_safe(page('<table><tr>a <em>b</em></tr></table>'))
    assert_includes body_of(row), 'a <em>b</em>'
  end

  def test_no_break_between_wide_characters_or_beside_zwsp
    han = (['漢 字'] * 40).join
    pretty = assert_safe(page("<p>#{han}</p>"))
    body = body_of(pretty)
    refute_match(/漢\n/, body)
    refute_match(/\n\s*字/, body)
    assert_includes body, '漢 字'

    zw = "#{HtmlFormat::ZWSP} " + ('word ' * 40)
    pretty = assert_safe(page("<p>#{zw}</p>"))
    refute_match(/#{HtmlFormat::ZWSP}\n/, body_of(pretty))
  end

  def test_guibutton_text_is_not_broken
    label = (['play'] * 40).join(' ')
    pretty = assert_safe(page(%(<p><span class="x guibutton y">#{label}</span></p>)))
    assert_equal label, parsed(pretty).at('span').text
    other = assert_safe(page(%(<p><span class="not-guibutton">#{label}</span></p>)))
    assert_includes parsed(other).at('span').text, "\n"
  end

  def test_cleanup_keeps_the_page_when_the_guard_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'chapter-tour.html')
      File.write(path, page('<p><em>a</em> <em>b</em></p>'))
      original = File.binread(path)
      env = ENV.to_h.merge('CLL_HTML_GUARD_BREAK' => 'drop-space')
      _out, err, status = Open3.capture3(env, 'bash', File.join(ROOT, 'scripts/xhtml_postprocess_cleanup.sh'), dir)
      refute status.success?, err
      assert_equal original, File.binread(path)
      assert_includes err, 'chapter-tour.html'
      refute_match(/chapter-tour\.html\./, err)
    end
  end
end

class HtmlWhitespaceGuardContract < Minitest::Test
  def wrap(body)
    page(body)
  end

  def refute_safe(before, after)
    error = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(before, after, name: 'chapter-tour.html')
    end
    assert_includes error.message, 'chapter-tour.html'
    error.message
  end

  def test_rejects_a_space_before_an_end_tag
    message = refute_safe(wrap('<p>Example 2.1.</p>'), wrap('<p>Example 2.1. </p>'))
    assert_match(/ADDED +between "Example 2\.1\." and <\/p>/, message)
  end

  def test_rejects_a_space_after_a_start_tag
    message = refute_safe(wrap('<p>text</p>'), wrap('<p> text</p>'))
    assert_match(/ADDED +between <p> and "text"/, message)
  end

  def test_rejects_a_removed_space_between_spans
    message = refute_safe(
      wrap('<p><span class="foreignphrase">a</span> <span>b</span></p>'),
      wrap('<p><span class="foreignphrase">a</span><span>b</span></p>')
    )
    assert_match(/REMOVED between <\/span> and <span>/, message)
  end

  def test_rejects_a_new_break_after_br
    message = refute_safe(wrap('<p>foo<br/>bar</p>'), wrap("<p>foo<br/>\nbar</p>"))
    assert_match(/ADDED +between <\/br> and "bar"/, message)
  end

  def test_rejects_a_changed_word_attribute_value_and_attribute_order
    word = refute_safe(wrap('<p>alpha</p>'), wrap('<p>beta</p>'))
    assert_match(/CHANGED between <p> and <\/p>/, word)

    value = refute_safe(wrap('<p class="one">a</p>'), wrap('<p class="two">a</p>'))
    assert_match(/CHANGED attributes of <p class="one">/, value)

    order = refute_safe(wrap('<p id="q" class="one">a</p>'), wrap('<p class="one" id="q">a</p>'))
    assert_match(/CHANGED attributes of <p/, order)
  end

  def test_rejects_a_changed_space_inside_pre_and_math
    pre = refute_safe(wrap("<pre>a b</pre>"), wrap("<pre>a  b</pre>"))
    assert_match(/CHANGED between <pre> and <\/pre>/, pre)

    math = '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi> <mi>y</mi></math>'
    changed = '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi><mi>y</mi></math>'
    message = refute_safe(wrap(math), wrap(changed))
    assert_match(/CHANGED/, message)
    assert_match(%r{</mi>}, message)
  end

  def test_accepts_free_gaps
    HtmlWhitespaceGuard.compare!(
      wrap('<div>a</div><div>b</div>'),
      wrap("<div>a</div>\n<div>b</div>"),
      name: 'blocks'
    )
    HtmlWhitespaceGuard.compare!(
      wrap('<table><tr><td>a</td></tr></table>'),
      wrap("<table><tr>\n<td>a</td></tr></table>"),
      name: 'cells'
    )
  end

  def test_strict_mode_rejects_a_free_gap
    assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(
        wrap('<div>a</div><div>b</div>'),
        wrap("<div>a</div>\n<div>b</div>"),
        name: 'blocks',
        strict: true
      )
    end
  end

  def test_command_compares_files_and_directories
    Dir.mktmpdir do |dir|
      before = File.join(dir, 'before')
      after = File.join(dir, 'after')
      Dir.mkdir(before)
      Dir.mkdir(after)
      File.write(File.join(before, 'page.html'), wrap('<p>a</p>'))
      File.write(File.join(after, 'page.html'), formatted(wrap('<p>a</p>')))
      File.write(File.join(before, 'notes.txt'), 'skip')
      ok = Open3.capture2('ruby', File.join(ROOT, 'scripts/html_whitespace_guard.rb'), before, after)
      assert ok[1].success?, ok[0]
      bad_status = nil
      File.write(File.join(after, 'page.html'), wrap('<p> a</p>'))
      _out, err, bad_status = Open3.capture3('ruby', File.join(ROOT, 'scripts/html_whitespace_guard.rb'), before, after)
      refute bad_status.success?
      assert_includes err, 'page.html'
    end
  end

  def document(body, decl: '<?xml version="1.0" encoding="UTF-8"?>', doctype: DOCTYPE, before: '', after: '')
    "#{decl}\n#{before}#{doctype}\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body>#{body}</body></html>#{after}\n"
  end

  def test_rejects_a_doctype_only_change
    source = document('<p>a</p>')
    refute_safe(source, document('<p>a</p>', doctype: '<!DOCTYPE html>'))
    refute_safe(source, document('<p>a</p>', doctype: ''))
    changed = source.sub('XHTML 1.0 Transitional', 'XHTML 1.0 Strict')
    message = refute_safe(source, changed)
    assert_match(/CHANGED doctype/, message)
  end

  def test_rejects_a_document_comment_or_pi_change
    source = document('<p>a</p>', before: "<!-- note -->\n<?cll keep?>\n", after: "\n<!-- tail -->\n<?cll after?>")
    refute_safe(source, source.sub('<!-- note -->', ''))
    refute_safe(source, source.sub('<?cll keep?>', ''))
    refute_safe(source, source.sub('<!-- tail -->', ''))
    refute_safe(source, source.sub('<?cll after?>', ''))
  end

  def test_rejects_an_xml_declaration_change
    source = document('<p>a</p>')
    version = refute_safe(source, source.sub('version="1.0"', 'version="1.1"'))
    assert_match(/CHANGED xml declaration/, version)
    encoding = refute_safe(source, source.sub('encoding="UTF-8"', 'encoding="ISO-8859-1"'))
    assert_match(/CHANGED xml declaration/, encoding)
  end

  def test_rejects_entity_substitution_deletion_and_redefinition
    decls = "<!ENTITY a \"alpha\"><!ENTITY b \"beta\">"
    body = '<p>&a;</p><pre>&a;</pre>'
    source = document(body, doctype: "<!DOCTYPE html [#{decls}]>")
    substituted = refute_safe(source, document('<p>&b;</p><pre>&a;</pre>', doctype: "<!DOCTYPE html [#{decls}]>"))
    assert_match(/&a;|&b;/, substituted)
    refute_safe(source, document('<p></p><pre>&a;</pre>', doctype: "<!DOCTYPE html [#{decls}]>"))
    redefined = document(body, doctype: '<!DOCTYPE html [<!ENTITY a "omega"><!ENTITY b "beta">]>')
    message = refute_safe(source, redefined)
    assert_match(/CHANGED doctype/, message)
    verbatim = refute_safe(source, document('<p>&a;</p><pre>alpha</pre>', doctype: "<!DOCTYPE html [#{decls}]>"))
    assert_match(/CHANGED/, verbatim)
  end

  def test_rejects_namespace_uri_and_prefix_rebinding
    math = '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>'
    foreign = refute_safe(wrap(math), wrap('<math xmlns="urn:other"><mi>x</mi></math>'))
    assert_match(/CHANGED namespace/, foreign)

    bound = '<p xmlns:x="urn:one" x:foo="a">a</p>'
    uri = refute_safe(wrap(bound), wrap('<p xmlns:x="urn:two" x:foo="a">a</p>'))
    assert_match(/CHANGED namespace/, uri)
    prefix = refute_safe(wrap(bound), wrap('<p xmlns:y="urn:one" y:foo="a">a</p>'))
    assert_match(/CHANGED namespace/, prefix)
  end

  def test_rejects_a_space_between_inline_children_of_a_container
    refute_safe(
      wrap('<ul><span>a</span> <span>b</span></ul>'),
      wrap('<ul><span>a</span><span>b</span></ul>')
    )
    refute_safe(
      wrap('<ol><em>a</em> <em>b</em></ol>'),
      wrap('<ol><em>a</em><em>b</em></ol>')
    )
    refute_safe(
      wrap('<dl><span>a</span> <span>b</span></dl>'),
      wrap('<dl><span>a</span><span>b</span></dl>')
    )
    refute_safe(
      wrap('<table><tr>a <em>b</em></tr></table>'),
      wrap('<table><tr>a<em>b</em></tr></table>')
    )
    HtmlWhitespaceGuard.compare!(
      wrap('<ul><li>a</li><li>b</li></ul>'),
      wrap("<ul><li>a</li>\n<li>b</li></ul>"),
      name: 'items'
    )
  end

  def test_rejects_a_break_between_wide_characters
    refute_safe(wrap('<p>漢 字</p>'), wrap("<p>漢\n字</p>"))
    refute_safe(wrap("<p>漢#{HtmlWhitespaceGuard::ZWSP} 字</p>"), wrap("<p>漢#{HtmlWhitespaceGuard::ZWSP}\n字</p>"))
    HtmlWhitespaceGuard.compare!(wrap('<p>漢  字</p>'), wrap('<p>漢 字</p>'), name: 'wide')
    HtmlWhitespaceGuard.compare!(wrap('<p>alpha beta</p>'), wrap("<p>alpha\nbeta</p>"), name: 'ordinary')
  end

  def test_rejects_adding_or_removing_the_single_kept_space
    removed = refute_safe(wrap('<p> </p>'), wrap('<p></p>'))
    assert_match(/REMOVED between <p> and <\/p>/, removed)
    added = refute_safe(wrap('<p></p>'), wrap('<p> </p>'))
    assert_match(/ADDED +between <p> and <\/p>/, added)
    cell = refute_safe(wrap('<table><tr><td> </td></tr></table>'), wrap('<table><tr><td></td></tr></table>'))
    assert_match(/REMOVED between <td> and <\/td>/, cell)
  end

  def test_rejects_a_break_inside_guibutton
    source = wrap('<p><span class="guibutton">play more</span></p>')
    changed = wrap("<p><span class=\"guibutton\">play\nmore</span></p>")
    message = refute_safe(source, changed)
    assert_match(/CHANGED/, message)
  end
end
