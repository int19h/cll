#!/usr/bin/env ruby
# Formatter and whitespace guard (issue #207).
# Run from anywhere: ruby scripts/test-html-format.rb

require 'minitest/autorun'
require 'nokogiri'
require 'open3'
require 'shellwords'
require 'fileutils'
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
    assert_same HtmlInlineNeighbors::WIDE_RANGES, HtmlFormat::WIDE_RANGES
    assert_same HtmlInlineNeighbors::WIDE_RANGES, HtmlWhitespaceGuard::WIDE_RANGES
    assert_same HtmlInlineNeighbors::ZWSP, HtmlFormat::ZWSP
    assert_same HtmlInlineNeighbors::ZWSP, HtmlWhitespaceGuard::ZWSP
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
      scripts = File.join(dir, 'scripts')
      FileUtils.cp_r(File.join(ROOT, 'scripts'), scripts)
      cleanup = File.join(scripts, 'xhtml_postprocess_cleanup_file.rb')
      source = File.read(cleanup)
      patched = source.sub("HtmlFormat.format!($document)\n") {
        <<~'RUBY'
          HtmlFormat.format!($document)
            em = $document.at_xpath('//*[local-name()="em"]')
            gap = em&.next_sibling
            gap.unlink if gap&.text? && !gap.content.empty? && gap.content.match?(/\A[ \t\n\r\f]+\z/)
        RUBY
      }
      refute_equal source, patched
      File.write(cleanup, patched)
      pages = File.join(dir, 'pages')
      Dir.mkdir(pages)
      path = File.join(pages, 'chapter-tour.html')
      File.write(path, page('<p><em>a</em> <em>b</em></p>'))
      original = File.binread(path)
      _out, err, status = Open3.capture3('bash', File.join(scripts, 'xhtml_postprocess_cleanup.sh'), pages)
      refute status.success?, err
      assert_equal original, File.binread(path)
      assert_includes err, 'chapter-tour.html'
      refute_match(/chapter-tour\.html\./, err)
    end
  end

  def test_inline_edge_whitespace_sees_the_outside_character
    zw = HtmlFormat::ZWSP
    long = 'a' * 100
    leading = assert_safe(page("<p>#{long}#{zw}<span> word</span></p>"))
    assert_includes body_of(leading), '<span> word</span>'
    refute_includes body_of(leading), "<span>\n"

    trailing = assert_safe(page("<p><span>#{long} </span>#{zw}word</p>"))
    assert_includes body_of(trailing), ' </span>'

    nested_lead = assert_safe(page("<p>#{long}#{zw}<span><em> word</em></span></p>"))
    assert_includes body_of(nested_lead), '<em> word</em>'

    nested_trail = assert_safe(page("<p><span><em>#{long} </em></span>#{zw}word</p>"))
    assert_includes body_of(nested_trail), ' </em>'

    other_node = assert_safe(page("<p>#{long}<span>#{zw}</span> <em>word</em></p>"))
    assert_includes body_of(other_node), '</span> <em>word</em>'
  end

  def test_newline_beside_zwsp_in_another_element_stays
    zw = HtmlFormat::ZWSP
    kept = assert_safe(page("<p>#{zw}<span>\nword</span></p>"))
    assert_match(%r{<span>\nword</span>}, body_of(kept))

    nested = assert_safe(page("<p>#{zw}<span><em>\nword</em></span></p>"))
    assert_match(%r{<em>\nword</em>}, body_of(nested))

    left = assert_safe(page("<p><span>#{zw}</span>\nword</p>"))
    assert_match(%r{</span>\nword}, body_of(left))

    right = assert_safe(page("<p>word\n<span>#{zw}</span></p>"))
    assert_match(%r{word\n<span>}, body_of(right))
  end

  def test_added_wide_ranges_do_not_become_line_breaks
    samples = [
      "\uFF61 \uFF62",
      "\uA000 \uA001",
      "\u{1B000} \u{1B001}",
      "\uFE10 \uFE11",
      "\uFE50 \uFE51",
      "\uFFE8 \uFFE9",
      "\u{16FE0} \u{16FE1}"
    ]
    samples.each do |pair|
      left, right = pair.split(' ')
      pretty = assert_safe(page("<p>#{(pair + ' ') * 30}</p>"))
      body = body_of(pretty)
      assert_includes body, pair
      refute_match(/#{Regexp.escape(left)}\n/, body)
      refute_match(/\n\s*#{Regexp.escape(right)}/, body)
    end
  end

  def test_entity_reference_counts_as_an_inline_neighbor
    source = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html [<!ENTITY z "&#x200B;">]>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /><title>T</title></head><body><p>#{'a' * 100}&z;<span> word</span></p></body></html>
    XML
    pretty = assert_safe(source)
    assert_includes body_of(pretty), '<span> word</span>'
  end

  def test_verbatim_inline_edges_keep_protected_runs
    zw = HtmlFormat::ZWSP
    long = 'a' * 100
    space = assert_safe(page(%(<p><span xml:space="preserve">#{long}#{zw}</span> word</p>)))
    assert_includes body_of(space), "#{zw}</span> word"
    refute_includes body_of(space), "#{zw}</span>\n"

    newline = assert_safe(page(%(<p><span xml:space="preserve">#{zw}</span>\nword</p>)))
    assert_match(%r{</span>\nword}, body_of(newline))

    nested = assert_safe(page(%(<p><span xml:space="preserve">#{zw}</span><em>\nword</em></p>)))
    assert_match(%r{<em>\nword</em>}, body_of(nested))

    mirror = assert_safe(page(%(<p>#{long} <span xml:space="preserve">#{zw}word</span></p>)))
    assert_includes body_of(mirror), " <span xml:space=\"preserve\">#{zw}word</span>"
    refute_match(%r{<span xml:space="preserve">\n}, body_of(mirror))
  end

  def test_stops_that_are_not_line_boundaries_keep_the_run
    zw = HtmlFormat::ZWSP
    math = '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>'
    cases = {
      'math after' => ["<p>a#{zw}\n#{math}</p>", %r{a#{zw}\n<math}],
      'math before' => ["<p>#{math}\n#{zw}b</p>", %r{</math>\n#{zw}b}],
      'preserve span' => [%(<p>a#{zw}\n<span xml:space="preserve">q</span></p>), %r{a#{zw}\n<span}],
      'hidden br' => [%(<p>a#{zw}<br class="example-break"/>\nb</p>), %r{example-break" />\nb}],
      'hidden br before' => [%(<p>a#{zw}\n<br class="example-break"/>b</p>), %r{a#{zw}\n<br}],
      'guibutton' => [%(<p>a#{zw}<span class="guibutton">x</span>\nb</p>), %r{</span>\nb}],
      'display-none' => [%(<p>a#{zw}<span class="display-none">x</span>\nb</p>), %r{</span>\nb}],
      'script' => [%(<p>a#{zw}<script type="text/javascript">var q=1;</script>\nb</p>), %r{</script>\nb}]
    }
    cases.each do |name, (body, pattern)|
      pretty = assert_safe(page(body))
      assert_match pattern, body_of(pretty), name
    end

    hidden_wide = assert_safe(page("<p>漢<span class=\"display-none\">x</span>\n字</p>"))
    assert_match(%r{</span>\n字}, body_of(hidden_wide))
    wide_br = assert_safe(page("<p>漢<br class=\"example-break\"/>\n字</p>"))
    assert_match(%r{example-break" />\n字}, body_of(wide_br))
  end

  def test_nbsp_from_the_dtd_does_not_protect_a_wide_pair
    source = page("<p>漢&nbsp;\n字</p>")
    Dir.chdir(ROOT) do
      doc = Nokogiri::XML(source) do |config|
        config.default_xml
        config.strict
        config.options = Nokogiri::XML::ParseOptions::DTDLOAD
      end
      before = HtmlFormat.write(doc)
      HtmlFormat.format!(doc)
      after = HtmlFormat.write(doc)
      HtmlWhitespaceGuard.compare!(before, after, name: 'dtd-entity.html')
      assert_match(/漢&nbsp;\n字/, body_of(after))
      assert_equal after, HtmlFormat.write(HtmlFormat.format!(Nokogiri::XML(after) { |config|
        config.default_xml
        config.strict
        config.options = Nokogiri::XML::ParseOptions::DTDLOAD
      }))
    end
  end

  def test_a_pair_outside_the_safe_set_keeps_its_run
    wide = assert_safe(page('<p>漢  字</p>'))
    assert_includes body_of(wide), '漢  字'
    zw = HtmlFormat::ZWSP
    kept = assert_safe(page("<p>a#{zw}  b</p>"))
    assert_includes body_of(kept), "#{zw}  b"
    ipa = assert_safe(page("<p>a\n\u0251</p>"))
    assert_match(/a\nɑ/, body_of(ipa))
  end

  def test_a_hidden_block_keeps_the_space_before_it
    pretty = assert_safe(page('<div>a<div class="display-none">x</div> word</div>'))
    body = body_of(pretty)
    assert_includes body, '</div> word'
    refute_includes body, '</div>word'
    zw = HtmlFormat::ZWSP
    marked = assert_safe(page("<div>a#{zw}<div class=\"display-none\">x</div> word</div>"))
    assert_includes body_of(marked), '</div> word'
    # A newline after the hidden block stays, and no line break is inserted before it.
    newline = assert_safe(page("<div>a#{zw}<div class=\"display-none\">x</div>\nword</div>"))
    body = body_of(newline)
    assert_includes body, "a#{zw}<div class=\"display-none\">x</div>\nword"
    refute_includes body, "a#{zw}\n"
    hidden_br = assert_safe(page("<p>a#{zw}<br class=\"display-none\"/>\nword</p>"))
    assert_includes body_of(hidden_br), "display-none\" />\nword"
    refute_includes body_of(hidden_br), "\n      word"
    # A visible block, a hidden block, then an unsafe character. The gap
    # before the hidden block is not free, so the source newline stays.
    shy = "\u00AD"
    frozen = assert_safe(page("<div>  <hr/>\n<div class=\"display-none\">x</div>\n  漢#{shy}b</div>"))
    assert_includes body_of(frozen), "<hr />\n<div class=\"display-none\">x</div>\n  漢#{shy}b"
    safe = assert_safe(page("<div><hr/>\n<div class=\"display-none\">x</div>\nword</div>"))
    assert_includes body_of(safe), "word"
  end

  def test_a_verbatim_neighbor_keeps_the_run
    zw = HtmlFormat::ZWSP
    math = '<math xmlns="http://www.w3.org/1998/Math/MathML"></math>'
    empty_wide = assert_safe(page("<p><span xml:space=\"preserve\">x#{math}</span>\n漢</p>"))
    assert_match(%r{</span>\n漢}, body_of(empty_wide))
    empty_ascii = assert_safe(page("<p><span xml:space=\"preserve\">#{zw}#{math}</span>\nb</p>"))
    assert_match(%r{</span>\nb}, body_of(empty_ascii))
    opaque = assert_safe(page("<p><span xml:space=\"preserve\"><br/>a#{zw}</span>\nword</p>"))
    assert_match(%r{</span>\nword}, body_of(opaque))
    swapped = page("<p><span xml:space=\"preserve\"><br/>a#{zw}</span> word</p>")
    refute_safe_page(page("<p><span xml:space=\"preserve\"><br/>a#{zw}</span>\nword</p>"), swapped)
  end

  def refute_safe_page(before, after)
    assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(before, after, name: 'verbatim-edge.html')
    end
  end

  def test_a_large_page_with_nbsp_stays_fast
    han = '漢' * 200_000
    source = page("<p>#{han}&nbsp;#{han}</p>")
    elapsed = Dir.chdir(ROOT) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      doc = Nokogiri::XML(source) do |config|
        config.default_xml
        config.strict
        config.options = Nokogiri::XML::ParseOptions::DTDLOAD
      end
      before = HtmlFormat.write(doc)
      HtmlFormat.format!(doc)
      after = HtmlFormat.write(doc)
      HtmlWhitespaceGuard.compare!(before, after, name: 'large-nbsp.html')
      assert_includes after, '&nbsp;'
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
    assert_operator elapsed, :<, 8, "large page took #{elapsed.round(2)}s"
  end

  def test_unsafe_edges_keep_the_source_run
    shy = "\u00AD"
    acu = "\u0301"
    cases = {
      'shy-end' => ["<p>a #{shy} </p>", "a #{shy} "],
      'shy-end-long' => ["<p>#{'word ' * 22}a #{shy} </p>", "a #{shy} "],
      'tab-mark-start' => ["<div>\t#{acu}a</div>", "\t#{acu}a"],
      'tab-mark-after-br' => ["<p>x<br/>\t#{acu}b</p>", "<br />\t#{acu}b"]
    }
    cases.each do |name, (body, kept)|
      pretty = assert_safe(page(body))
      assert_includes body_of(pretty), kept, name
    end

    shy_gap = assert_safe(page("<div>a #{shy}<p>t</p></div>"))
    assert_includes body_of(shy_gap), "#{shy}<p"
    mark_gap = assert_safe(page("<div><p>t</p>#{acu}b</div>"))
    assert_includes body_of(mark_gap), "</p>#{acu}b"

    wide = assert_safe(page('<p>x<br/> 漢</p>'))
    assert_includes body_of(wide), '<br /> 漢'
    source = page('<div><a id="q"></a><p>t</p></div>')
    assert_safe(source)
    HtmlWhitespaceGuard.compare!(source, source.sub('</a><p>', "</a>\n<p>"), name: 'anchor')
    math = '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>'
    kept_math = assert_safe(page("<div>#{math}\n<p>t</p></div>"))
    assert_match(%r{</math>\n<p>t</p>}, body_of(kept_math))
  end

  def test_a_long_inline_run_keeps_the_space_before_a_hidden_block
    words = 'word ' * 25
    bodies = [
      "<div>#{words}a <div class=\"display-none\">h</div></div>",
      "<div>#{words}<em>a</em> <div class=\"display-none\">h</div></div>",
      "<div>#{words}a <div class=\"display-none\">h</div> <a id=\"q\"></a></div>",
      "<p>#{words}a <span class=\"display-none\">h</span></p>",
      "<div><p>t</p>#{words}a <div class=\"display-none\">h</div> b</div>"
    ]
    bodies.each do |body|
      pretty = assert_safe(page(body))
      text = body_of(pretty)
      assert_match(/a(?:<\/em>)?\s+<(?:div|span) class="display-none">/, text, body)
      refute_match(/a(?:<\/em>)?<(?:div|span) class="display-none">/, text, body)
    end
  end

  def test_stylesheet_hiding_subjects_fail_closed
    sample = <<~CSS
      /* h1 { display: none } */
      @media screen {
        span.only-media { display: none; }
      }
      @page { @bottom-left { content: "x"; } }
      p.shown { display: block; }
      br.example-break { display: none }
      .article > .titlepage hr { display: none }
    CSS
    assert_equal [
      ['span', ['only-media'], false],
      ['br', ['example-break'], true],
      ['hr', [], false]
    ], hiding_rules(sample)

    found = []
    stylesheet_texts.each { |text| found.concat(hiding_rules(text)) }
    assert_includes found, ['hr', [], false]
    assert_includes found, ['br', ['example-break'], true]
    assert_includes found, ['br', ['table-break'], true]
    assert_includes found, [nil, ['display-none'], true]
    assert_includes found, [nil, ['guibutton'], true]
    assert_includes found, [nil, ['release-separator'], false]
    assert_includes found, ['h3', [], false]
    found.each do |tag, classes, unconditional|
      visibility = HtmlInlineNeighbors.subject_visibility(tag, classes)
      expected = unconditional ? :hidden : :uncertain
      assert_equal expected, visibility, "#{tag.inspect} #{classes.inspect} unconditional=#{unconditional} is #{visibility}"
    end
    assert_equal :hidden, HtmlInlineNeighbors.subject_visibility(nil, ['display-none'])
    assert_equal :uncertain, HtmlInlineNeighbors.subject_visibility('hr', [])
    assert_equal :uncertain, HtmlInlineNeighbors.subject_visibility('h3', [])
    assert_equal :uncertain, HtmlInlineNeighbors.subject_visibility(nil, ['release-separator'])
    assert_equal :visible, HtmlInlineNeighbors.subject_visibility('h1', [])

    bodies = {
      'article' => '<div class="article"><div class="titlepage"><hr/></div></div>',
      'book' => '<div class="book"><div class="titlepage"><hr/></div></div>',
      'body' => '<div><hr/></div>',
      'nested' => '<div class="book"><div><div class="titlepage"><hr/></div></div></div>'
    }
    bodies.each do |kind, body|
      hr = parsed(page(body)).at_xpath('//*[local-name()="hr"]')
      refute HtmlInlineNeighbors.hidden_element?(hr), kind
      assert HtmlInlineNeighbors.uncertain_element?(hr), kind
    end
    separator = parsed(page('<span class="release-separator">x</span>')).at_xpath('//*[local-name()="span"]')
    assert HtmlInlineNeighbors.uncertain_element?(separator)
    hidden = parsed(page('<div class="display-none">x</div>')).at_xpath('//*[local-name()="div"]')
    assert HtmlInlineNeighbors.hidden_element?(hidden)
  end

  def test_titlepage_hr_keeps_the_space_through_cleanup
    {
      'article' => '<div class="article"><div class="titlepage">a<hr/> word</div></div>',
      'book' => '<div class="book"><div class="titlepage">a<hr/> word</div></div>',
      'nested-article' => '<div class="article"><div class="titlepage"><div><div class="titlepage">a<hr/> word</div></div></div></div>',
      'nested-book' => '<div class="book"><div class="titlepage"><div class="titlepage">a<hr/> word</div></div></div>',
      'nested-book-wrapped' => '<div class="book"><div class="titlepage"><div><div class="titlepage">a<hr/> word</div></div></div></div>'
    }.each do |kind, body|
      Dir.mktmpdir do |dir|
        source = page(body)
        File.write(File.join(dir, 'page.html'), source)
        _out, err, status = Open3.capture3(File.join(ROOT, 'scripts/xhtml_postprocess_cleanup.sh'), dir)
        assert status.success?, "#{kind}: #{err}"
        text = File.read(File.join(dir, 'page.html'))
        assert_match(%r{a\s*<hr[^>]*>\s+word}m, text, kind)
        refute_includes text, 'aword'
        assert_safe(source)
        removed = source.sub(' word', 'word')
        message = assert_raises(HtmlWhitespaceGuard::Unsafe) do
          HtmlWhitespaceGuard.compare!(source, removed, name: 'chapter-tour.html')
        end
        assert_match(/REMOVED|CHANGED/, message.message, kind)
      end
    end
  end

  def test_print_only_separator_keeps_the_newline_through_cleanup
    zwsp = "\u200B"
    {
      'astra' => %(<div class="book"><div class="titlepage">a<span class="release-separator">#{zwsp}</span>\nword</div></div>),
      'opus' => %(<div class="book"><div class="titlepage"><p>a<span class="release-separator">#{zwsp}</span>\nb</p></div></div>)
    }.each do |kind, body|
      Dir.mktmpdir do |dir|
        source = page(body)
        File.write(File.join(dir, 'page.html'), source)
        _out, err, status = Open3.capture3(File.join(ROOT, 'scripts/xhtml_postprocess_cleanup.sh'), dir)
        assert status.success?, "#{kind}: #{err}"
        text = File.read(File.join(dir, 'page.html'))
        assert_includes text, "<span class=\"release-separator\">#{zwsp}</span>\n", kind
        refute_includes text, 'aword'
        assert_safe(source)
        collapsed = source.sub("</span>\n", '</span> ')
        message = assert_raises(HtmlWhitespaceGuard::Unsafe) do
          HtmlWhitespaceGuard.compare!(source, collapsed, name: 'chapter-tour.html')
        end
        assert_match(/CHANGED/, message.message, kind)
      end
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
    refute_safe(wrap('<p>漢  字</p>'), wrap('<p>漢 字</p>'))
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

  def test_rejects_a_break_across_an_inline_edge
    zw = HtmlWhitespaceGuard::ZWSP
    refute_safe(wrap("<p>#{zw}<span> word</span></p>"), wrap("<p>#{zw}<span>\nword</span></p>"))
    refute_safe(wrap("<p><span>word </span>#{zw}</p>"), wrap("<p><span>word\n</span>#{zw}</p>"))
    refute_safe(wrap("<p>#{zw}<span><em> word</em></span></p>"), wrap("<p>#{zw}<span><em>\nword</em></span></p>"))
    refute_safe(wrap("<p><span><em>word </em></span>#{zw}</p>"), wrap("<p><span><em>word\n</em></span>#{zw}</p>"))
    refute_safe(wrap("<p>a#{zw} <em>b</em></p>"), wrap("<p>a#{zw}\n<em>b</em></p>"))
    refute_safe(wrap('<p>漢<span> 字</span></p>'), wrap("<p>漢<span>\n字</span></p>"))
    refute_safe(wrap('<p><span>漢 </span>字</p>'), wrap("<p><span>漢\n</span>字</p>"))
    refute_safe(wrap('<p><b><i>漢 </i></b>字</p>'), wrap("<p><b><i>漢\n</i></b>字</p>"))
    refute_safe(wrap("<p>\u{1B000} \u{1B001}</p>"), wrap("<p>\u{1B000}\n\u{1B001}</p>"))
    refute_safe(wrap("<p>\uFF76 \uFF85</p>"), wrap("<p>\uFF76\n\uFF85</p>"))
  end

  def test_rejects_newline_and_space_swaps_beside_an_outside_zwsp
    zw = HtmlWhitespaceGuard::ZWSP
    refute_safe(wrap("<p><span>#{zw}</span>\nword</p>"), wrap("<p><span>#{zw}</span> word</p>"))
    refute_safe(wrap("<p>word\n<span>#{zw}</span></p>"), wrap("<p>word <span>#{zw}</span></p>"))
    refute_safe(wrap("<p>#{zw}<span>\nword</span></p>"), wrap("<p>#{zw}<span> word</span></p>"))
    refute_safe(wrap("<p><span>word\n</span>#{zw}</p>"), wrap("<p><span>word </span>#{zw}</p>"))
  end

  def test_entity_reference_protects_the_neighboring_run
    decl = '<!DOCTYPE html [<!ENTITY z "&#x200B;">]>'
    source = document('<p>&z;<span> word</span></p>', doctype: decl)
    changed = document("<p>&z;<span>\nword</span></p>", doctype: decl)
    refute_safe(source, changed)
    wide = '<!DOCTYPE html [<!ENTITY w "&#x6F22;">]>'
    refute_safe(
      document('<p>&w;<span> 字</span></p>', doctype: wide),
      document("<p>&w;<span>\n字</span></p>", doctype: wide)
    )
  end

  def test_parse_error_names_the_page_and_the_side
    good = wrap('<p>a</p>')
    bad = good.sub('</p>', '')
    after = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(good, bad, name: 'malformed-page-name.html')
    end
    assert_includes after.message, 'malformed-page-name.html'
    assert_includes after.message, 'after'
    refute_match(/before:/, after.message)

    before = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(bad, good, name: 'malformed-page-name.html')
    end
    assert_includes before.message, 'malformed-page-name.html'
    assert_includes before.message, 'before'
  end

  def test_defined_attribute_entities_compare_as_values
    swapped = refute_safe(
      document('<p title="a&nbsp;&ensp;b">x</p>'),
      document('<p title="a&ensp;&nbsp;b">x</p>')
    )
    assert_match(/CHANGED attributes/, swapped)
    removed = refute_safe(
      document('<p title="a&nbsp;b">x</p>'),
      document('<p title="ab">x</p>')
    )
    assert_match(/CHANGED attributes/, removed)
    HtmlWhitespaceGuard.compare!(
      document('<p title="a&nbsp;b">x y</p>'),
      document("<p title=\"a&nbsp;b\">x\ny</p>"),
      name: 'same-entity'
    )
    moved = refute_safe(
      document('<p title="a&nbsp;b">x</p>'),
      document('<p title="ab&nbsp;">x</p>')
    )
    assert_match(/CHANGED attributes/, moved)
    across = refute_safe(
      document('<p title="a&nbsp;b" id="xy">x</p>'),
      document('<p title="ab" id="x&nbsp;y">x</p>')
    )
    assert_match(/CHANGED attributes/, across)
    elements = refute_safe(
      document('<p title="a&nbsp;b">x</p><p title="ab">y</p>'),
      document('<p title="ab">x</p><p title="a&nbsp;b">y</p>')
    )
    assert_match(/CHANGED attributes/, elements)
    wide = refute_safe(
      document('<p title="漢&nbsp;b">x</p>'),
      document('<p title="漢b&nbsp;">x</p>')
    )
    assert_match(/CHANGED attributes/, wide)
    same_char = refute_safe(
      document('<p title="&#233;&nbsp;">x</p>'),
      document('<p title="é&nbsp; ">x</p>')
    )
    assert_match(/CHANGED attributes/, same_char)
    HtmlWhitespaceGuard.compare!(
      document('<p title="&#233;&nbsp;">x</p>'),
      document('<p title="é&nbsp;">x</p>'),
      name: 'charref'
    )
    defined = '<!DOCTYPE html [<!ENTITY a "A"><!ENTITY b "A">]>'
    HtmlWhitespaceGuard.compare!(
      document('<p title="&a;">x</p>', doctype: defined),
      document('<p title="&b;">x</p>', doctype: defined),
      name: 'defined-attr'
    )
  end

  def test_rejects_an_undefined_entity_by_name
    bare = '<!DOCTYPE html>'
    text = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(
        document('<p>a&nosuch;b</p>', doctype: bare),
        document('<p>a&nosuch;b</p>', doctype: bare),
        name: 'missing-text.html'
      )
    end
    assert_includes text.message, 'missing-text.html'
    assert_includes text.message, '&nosuch;'

    attr = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(
        document('<p title="a&字;b">x</p>', doctype: bare),
        document('<p title="ab&字;">x</p>', doctype: bare),
        name: 'missing-attr.html'
      )
    end
    assert_includes attr.message, '&字;'
    latin = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(
        document('<p title="a&eacute;b">x</p>'.sub('eacute', 'é'), doctype: bare),
        document('<p title="x">x</p>', doctype: bare),
        name: 'missing-latin.html'
      )
    end
    assert_includes latin.message, '&é;'
  end

  def test_rejects_a_protected_run_beside_a_verbatim_or_hidden_element
    zw = HtmlWhitespaceGuard::ZWSP
    math = '<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>'
    long = 'a' * 100
    pairs = [
      [page(%(<p><span xml:space="preserve">#{long}#{zw}</span> word</p>)),
       page(%(<p><span xml:space="preserve">#{long}#{zw}</span>\nword</p>))],
      [page(%(<p><span xml:space="preserve">#{zw}</span>\nword</p>)),
       page(%(<p><span xml:space="preserve">#{zw}</span> word</p>))],
      [page(%(<p><span xml:space="preserve">#{zw}</span><em>\nword</em></p>)),
       page(%(<p><span xml:space="preserve">#{zw}</span><em> word</em></p>))],
      [page(%(<p>#{long} <span xml:space="preserve">#{zw}word</span></p>)),
       page(%(<p>#{long}\n<span xml:space="preserve">#{zw}word</span></p>))],
      [page("<p>a#{zw}\n#{math}</p>"), page("<p>a#{zw} #{math}</p>")],
      [page("<p>#{math}\n#{zw}b</p>"), page("<p>#{math} #{zw}b</p>")],
      [page(%(<p>a#{zw}\n<span xml:space="preserve">q</span></p>)),
       page(%(<p>a#{zw} <span xml:space="preserve">q</span></p>))],
      [page(%(<p>a#{zw}<br class="example-break"/>\nb</p>)),
       page(%(<p>a#{zw}<br class="example-break"/> b</p>))],
      [page(%(<p>a#{zw}\n<br class="example-break"/>b</p>)),
       page(%(<p>a#{zw} <br class="example-break"/>b</p>))],
      [page(%(<p>a#{zw}<span class="guibutton">x</span>\nb</p>)),
       page(%(<p>a#{zw}<span class="guibutton">x</span> b</p>))],
      [page(%(<p>a#{zw}<span class="display-none">x</span>\nb</p>)),
       page(%(<p>a#{zw}<span class="display-none">x</span> b</p>))],
      [page(%(<p>a#{zw}<script type="text/javascript">var q=1;</script>\nb</p>)),
       page(%(<p>a#{zw}<script type="text/javascript">var q=1;</script> b</p>))],
      [page("<p>漢<span class=\"display-none\">x</span>\n字</p>"),
       page('<p>漢<span class="display-none">x</span> 字</p>')],
      [page("<p>漢<br class=\"example-break\"/>\n字</p>"),
       page('<p>漢<br class="example-break"/> 字</p>')]
    ]
    pairs.each { |before, after| refute_safe(before, after) }
  end

  def test_compares_the_raw_declaration_and_the_prolog_order
    source = document('<p>a</p>')
    standalone = refute_safe(source, source.sub('encoding="UTF-8"?>', 'encoding="UTF-8" standalone="yes"?>'))
    assert_match(/CHANGED xml declaration/, standalone)
    version_only = refute_safe(source, source.sub('<?xml version="1.0" encoding="UTF-8"?>', '<?xml version="1.0"?>'))
    assert_match(/CHANGED xml declaration/, version_only)

    decl = '<?xml version="1.0" encoding="UTF-8"?>'
    body = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><p>a</p></body></html>\n"
    moved = refute_safe("#{decl}\n<!-- c -->\n#{DOCTYPE}\n#{body}", "#{decl}\n#{DOCTYPE}\n<!-- c -->\n#{body}")
    assert_match(/CHANGED prolog/, moved)

    notation = refute_safe(
      '<!DOCTYPE r [<!NOTATION n SYSTEM "a">]><r/>',
      '<!DOCTYPE r [<!NOTATION n SYSTEM "b">]><r/>'
    )
    assert_match(/CHANGED doctype/, notation)
    parameter = refute_safe(
      '<!DOCTYPE r [<!ENTITY a "A">]><r/>',
      '<!DOCTYPE r [<!ENTITY % a "A">]><r/>'
    )
    assert_match(/CHANGED doctype/, parameter)
    comment = refute_safe(
      '<!DOCTYPE r [<!ELEMENT r ANY>]><r/>',
      '<!DOCTYPE r [<!-- c --><!ELEMENT r ANY>]><r/>'
    )
    assert_match(/CHANGED doctype/, comment)
  end

  def test_rejects_removing_or_changing_the_default_namespace
    source = document('<p>a</p>')
    removed = refute_safe(source, source.sub(' xmlns="http://www.w3.org/1999/xhtml"', ''))
    assert_match(/CHANGED namespace/, removed)
    changed = refute_safe(
      source,
      source.sub('xmlns="http://www.w3.org/1999/xhtml"', 'xmlns="http://www.w3.org/1999/xhtm"')
    )
    assert_match(/CHANGED namespace/, changed)
  end

  def test_rejects_a_free_gap_beside_an_unsafe_character
    shy = "\u00AD"
    acu = "\u0301"
    added_shy = refute_safe(
      wrap("<div>a #{shy}<p>t</p></div>"),
      wrap("<div>a #{shy}\n<p>t</p></div>")
    )
    assert_match(/CHANGED/, added_shy)
    added_mark = refute_safe(
      wrap("<div><p>t</p>#{acu}b</div>"),
      wrap("<div><p>t</p> #{acu}b</div>")
    )
    assert_match(/CHANGED/, added_mark)
  end

  def test_catalog_survives_an_earlier_parse
    Dir.mktmpdir do |dir|
      empty = File.join(dir, 'empty-catalog.xml')
      File.write(empty, <<~XML)
        <?xml version="1.0"?>
        <catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog"/>
      XML
      probe = File.join(dir, 'probe.rb')
      ids = [
        DOCTYPE,
        '<!DOCTYPE html SYSTEM "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">',
        '<!DOCTYPE html SYSTEM "https://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">'
      ]
      texts = ids.map { |id| document('<p title="a&nbsp;b">x</p>', doctype: id) }
      File.write(probe, <<~RUBY)
        require 'nokogiri'
        empty = #{empty.dump}
        guard = #{File.join(ROOT, 'scripts/html_whitespace_guard.rb').dump}
        texts = #{texts.inspect}
        if ARGV[0] == 'before'
          ENV['XML_CATALOG_FILES'] = empty
          Nokogiri::XML('<!DOCTYPE html SYSTEM "missing.dtd"><html/>') { |c| c.nonet.dtdload }
          require guard
        else
          require guard
          ENV['XML_CATALOG_FILES'] = empty
          Nokogiri::XML('<!DOCTYPE html SYSTEM "missing.dtd"><html/>') { |c| c.nonet.dtdload }
        end
        texts.each do |text|
          HtmlWhitespaceGuard.compare!(text, text, name: 'catalog')
          doc = HtmlWhitespaceGuard.parse_tokens(text)[0]
          puts doc.at_xpath('//*[local-name()="p"]')['title']
        end
      RUBY
      %w[before after].each do |mode|
        out, err, status = Open3.capture3('ruby', probe, mode, chdir: ROOT)
        assert status.success?, "#{mode}: #{err}\n#{out}"
        assert_equal ["a\u00A0b", "a\u00A0b", "a\u00A0b"], out.split("\n"), mode
      end
    end
  end
end

# Each hiding rule is [tag, classes, unconditional_single].
# unconditional_single is true only for a top-level rule whose selector is
# one compound. A rule under @media or any other at-rule is not that, and
# neither is a selector with an ancestor. The comment strip runs first, so
# a commented-out rule is not a rule.
def hiding_rules(css)
  rules = []
  scan_css_rules(css.gsub(%r{/\*.*?\*/}m, ''), rules, false)
  rules
end

def scan_css_rules(css, rules, in_at)
  index = 0
  while (brace = css.index('{', index))
    prelude = css[index...brace]
    body, finish = css_block(css, brace)
    if prelude.strip.start_with?('@')
      scan_css_rules(body, rules, true)
    elsif body !~ /\{/ && (body.match?(/display\s*:\s*none\b/i) || body.match?(/visibility\s*:\s*hidden\b/i))
      prelude.split(',').each do |selector|
        subject = selector_subject(selector)
        next unless subject

        rules << [subject[0], subject[1], !in_at && single_compound?(selector)]
      end
    end
    index = finish + 1
  end
end

def single_compound?(selector)
  selector.strip.split(/\s*(?:>|\+|~)\s*|\s+/).reject(&:empty?).length == 1
end

def css_block(css, open_at)
  depth = 0
  cursor = open_at
  while cursor < css.length
    case css[cursor]
    when '{'
      depth += 1
    when '}'
      depth -= 1
      return [css[(open_at + 1)...cursor], cursor] if depth.zero?
    when '"', "'"
      quote = css[cursor]
      cursor += 1
      while cursor < css.length && css[cursor] != quote
        cursor += 1 if css[cursor] == '\\' && cursor + 1 < css.length
        cursor += 1
      end
    end
    cursor += 1
  end
  [css[(open_at + 1)..], css.length - 1]
end

def selector_subject(selector)
  last = selector.strip.split(/\s*(?:>|\+|~)\s*|\s+/).last
  return nil if last.nil? || last.empty? || last.start_with?('@')

  classes = last.scan(/\.([_a-zA-Z][_a-zA-Z0-9-]*)/).flatten
  tag = last.split(/[.#:\[\s>+~]/, 2).first
  tag = nil if tag.nil? || tag.empty? || tag == '*'
  [tag, classes]
end

# Local pages is behind origin/pages in this checkout. Read origin/pages
# when the local branch is missing or is an ancestor of origin/pages.
# Print a note and use assets/css only when neither ref exists.
def stylesheet_texts
  texts = Dir[File.join(ROOT, 'assets/css/*.css')].sort.map { |path| File.read(path) }
  ref = pages_tree_ref
  if ref.nil?
    warn 'note: stylesheet test skipped the pages branch (no pages or origin/pages ref)'
    return texts
  end

  listed, status = Open3.capture2('git', '-C', ROOT, 'ls-tree', '-r', '--name-only', ref)
  return texts unless status.success?

  listed.each_line do |line|
    path = line.strip
    next unless path.end_with?('.css') && !path.start_with?('official/')

    blob, blob_status = Open3.capture2('git', '-C', ROOT, 'show', "#{ref}:#{path}")
    texts << blob if blob_status.success?
  end
  texts
end

def pages_tree_ref
  local = git_commit('pages')
  origin = git_commit('origin/pages')
  if origin && (local.nil? || (local != origin && git_ancestor?(local, origin)))
    'origin/pages'
  elsif local
    'pages'
  end
end

def git_commit(ref)
  out, status = Open3.capture2('git', '-C', ROOT, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}")
  status.success? ? out.strip : nil
end

def git_ancestor?(ancestor, descendant)
  _out, status = Open3.capture2('git', '-C', ROOT, 'merge-base', '--is-ancestor', ancestor, descendant)
  status.success?
end
