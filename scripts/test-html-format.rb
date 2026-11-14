#!/usr/bin/env ruby
# Indent-only HTML formatter and whitespace guard (issue #207).
# Run from anywhere: ruby scripts/test-html-format.rb

require 'minitest/autorun'
require 'nokogiri'
require 'open3'
require 'shellwords'
require 'fileutils'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
require File.join(ROOT, 'scripts/html_format')
require File.join(ROOT, 'scripts/html_whitespace_guard')
require File.join(ROOT, 'scripts/html_stylesheet_scan')

PARSE = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET
DOCTYPE = '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "dtd/xhtml1-transitional.dtd">'
META = '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />'

def page(body, head: "#{META}<title>T</title>")
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    #{DOCTYPE}
    <html xmlns="http://www.w3.org/1999/xhtml"><head>#{head}</head><body>#{body}</body></html>
  XML
end

def parse(text)
  Nokogiri::XML(text) { |config| config.options = PARSE }
end

def format_text(text)
  document = parse(text)
  HtmlFormat.ensure_content_type_meta!(document)
  before = HtmlFormat.write(document)
  HtmlFormat.format!(document)
  after = HtmlFormat.write(document)
  HtmlWhitespaceGuard.compare!(before, after, name: 'fixture')
  after
end

def rendered_chars(text)
  parse(text).xpath('//text()').map { |node| node.content.gsub(/[ \t\r\n\f]/, '') }.join
end

def element(text, name, attr = nil)
  node = parse(text).at_xpath("//*[local-name()='#{name}']#{attr}")
  raise "no #{name} in the page" unless node
  node
end

class StylesheetExclusion < Minitest::Test
  def assert_unreadable(css, needle)
    error = assert_raises(HtmlStylesheetScan::Unreadable) do
      HtmlStylesheetScan.exclusion(css, source: 'fixture.css')
    end
    assert_includes error.message, 'fixture.css'
    assert_includes error.message, needle
  end

  def test_real_stylesheets_match_the_constant
    tags = []
    classes = []
    Dir[File.join(ROOT, 'assets/css/*.css')].sort.each do |path|
      found_tags, found_classes = HtmlStylesheetScan.exclusion(File.read(path), source: path)
      tags.concat(found_tags)
      classes.concat(found_classes)
    end
    tags.concat(comparison_sets[0])
    classes.concat(comparison_sets[1])
    assert_equal HtmlFormat::EXCLUSION_TAGS.sort, tags.uniq.sort
    assert_equal HtmlFormat::EXCLUSION_CLASSES.sort, classes.uniq.sort
  end

  def test_each_unreadable_construct_names_the_rule
    assert_unreadable('div\x { display: block }', 'div\x')
    assert_unreadable('@import "other.css";', '@import')
    assert_unreadable('@layer widgets { p { display: block } }', '@layer')
    assert_unreadable('p[hidden] { display: none }', 'p[hidden]')
    assert_unreadable('#main { display: block }', '#main')
    assert_unreadable('p:first-child { display: block }', 'p:first-child')
    assert_unreadable('p::before { display: block }', 'p::before')
    assert_unreadable('p { display: var(--d) }', 'var(--d)')
    assert_unreadable("p { display: block }\n/* oops", 'comment')
    assert_unreadable('p { display: \62 lock }', '\62')
    assert_unreadable('@page { display: block }', '@page')
    assert_unreadable('@font-face { display: block }', '@font-face')
  end

  def test_a_comment_hides_a_display_rule_and_ordinary_constructs_parse
    css = <<~CSS
      /* p.secret { display: none } */
      img[src$=".png"] { width: 1px; }
      p::before { content: "\\25C6"; }
      @media screen and (max-width: 800px) { .kept { color: red; } }
      @page chapter:left { @top-left { content: "x"; } }
      @font-face { font-family: "A"; src: url("a.otf"); }
      div:nth-last-child(3) { padding: 0; }
      .shown { display: block; }
      @media { h1 { display: none } }
      @supports (display: flex) { span.box { display: block } }
    CSS
    tags, classes = HtmlStylesheetScan.exclusion(css, source: 'safe.css')
    assert_equal %w[h1 span], tags.uniq.sort
    assert_equal %w[box shown], classes.uniq.sort
    refute_includes classes, 'secret'
  end

  def comparison_sets
    text = nil
    %w[origin/pages pages].each do |ref|
      shown, status = Open3.capture2('git', 'show', "#{ref}:scripts/docbook-diff.xsl", chdir: ROOT)
      if status.success?
        text = shown
        break
      end
    end
    if text.nil?
      _fetch, status = Open3.capture2('git', 'fetch', '--depth=1', 'origin', 'pages', chdir: ROOT)
      raise 'the comparison stylesheet on origin/pages is not available' unless status.success?
      text, status = Open3.capture2('git', 'show', 'FETCH_HEAD:scripts/docbook-diff.xsl', chdir: ROOT)
      raise 'the comparison stylesheet is missing' unless status.success?
    end
    match = text.match(/<style\b[^>]*>(.*?)<\/style>/m)
    raise 'the comparison page has no style element' unless match
    css = match[1].gsub(%r{</?xsl:text>}, '')
    HtmlStylesheetScan.exclusion(css, source: 'docbook-diff.xsl')
  end
end

class VisibleBlocks < Minitest::Test
  def block?(body, name, attr = '')
    HtmlFormat.visible_block?(element(page(body), name, attr))
  end

  def test_block_list_and_exclusion_set
    assert block?('<div class="chapter">x</div>', 'div', '[@class="chapter"]')
    assert block?('<h1>x</h1>', 'h1')
    assert block?('<pre>x</pre>', 'pre')
    assert block?('<table><tr><td>x</td></tr></table>', 'td')
    assert block?('<div class="chapter extra">x</div>', 'div')
    refute block?('<p>x</p>', 'p')
    refute block?('<h3>x</h3>', 'h3')
    refute block?('<hr />', 'hr')
    refute block?('<div class="book">x</div>', 'div')
    refute block?('<div class="chapter book">x</div>', 'div')
    refute block?('<head><title>T</title></head>', 'head')
    refute block?('<br />', 'br')
    refute block?('<span class="tutci">x</span>', 'span')
    foreign = parse(page('<div xmlns="">x</div>')).at_xpath('//*[local-name()="div" and namespace-uri()=""]')
    refute HtmlFormat.visible_block?(foreign)
    spaced = element(page('<div xml:space="preserve" class="chapter">x</div>'), 'div')
    assert HtmlFormat.visible_block?(spaced)
    assert HtmlFormat.verbatim?(spaced)
  end

  def test_free_gaps
    doc = parse(page('<div class="chapter"><div class="section">a</div><p>b</p><div class="section">c</div></div>'))
    chapter = doc.at_xpath('//*[@class="chapter"]')
    sigs, = HtmlFormat.split_children(chapter)
    assert HtmlFormat.free_gap?(chapter, nil, sigs[0])
    refute HtmlFormat.free_gap?(chapter, sigs[0], sigs[1])
    refute HtmlFormat.free_gap?(chapter, sigs[1], sigs[2])
    assert HtmlFormat.free_gap?(chapter, sigs[2], nil)

    both = parse(page('<div class="chapter"><div class="section">a</div><div class="section">b</div></div>'))
    parent = both.at_xpath('//*[@class="chapter"]')
    children, = HtmlFormat.split_children(parent)
    assert HtmlFormat.free_gap?(parent, children[0], children[1])
    assert HtmlFormat.free_gap?(parent, children[1], nil)

    pre = parse(page('<pre><div class="section">a</div></pre>')).at_xpath('//*[local-name()="pre"]')
    inner, = HtmlFormat.split_children(pre)
    refute HtmlFormat.free_gap?(pre, nil, inner[0])

    head = parse(page('<p>a</p>')).at_xpath('//*[local-name()="head"]')
    heads, = HtmlFormat.split_children(head)
    assert HtmlFormat.free_gap?(head, nil, heads[0])
    assert HtmlFormat.free_gap?(head, heads[0], heads[1])
    assert HtmlFormat.free_gap?(head, heads[-1], nil)
    refute HtmlFormat.free_gap?(head, nil, nil)

    html = parse(page('<p>a</p>')).at_xpath('//*[local-name()="html"]')
    html_kids, = HtmlFormat.split_children(html)
    assert HtmlFormat.free_gap?(html, nil, html_kids[0])
    refute HtmlFormat.free_gap?(html, html_kids[0], html_kids[1])
    assert HtmlFormat.free_gap?(html, html_kids[1], nil)

    noted = parse(page('<div class="chapter"><div class="section">a</div><!-- n --><div class="section">b</div></div>'))
    noted_parent = noted.at_xpath('//*[@class="chapter"]')
    noted_sigs, = HtmlFormat.split_children(noted_parent)
    refute HtmlFormat.free_gap?(noted_parent, noted_sigs[0], noted_sigs[1])
  end

  def test_a_foreign_subtree_and_xml_space_are_verbatim
    math = element(page('<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>'), 'math')
    assert HtmlFormat.verbatim?(math)
    script = parse(page('<p>a</p>', head: %(#{META}<script xmlns="" type="text/javascript">a</script>))).at_xpath('//*[local-name()="script"]')
    assert HtmlFormat.verbatim?(script)
    refute HtmlFormat.verbatim?(element(page('<div class="chapter">a</div>'), 'div'))
  end
end

class FormatterOutput < Minitest::Test
  def test_blocks_are_indented_and_a_paragraph_is_not_wrapped
    pretty = format_text(page('<div class="chapter"> <div class="section">x</div><div class="section">y</div></div>'))
    assert_includes pretty, "<div class=\"section\">x</div>\n      <div class=\"section\">y</div>\n    </div>"
    # Existing whitespace must be replaced, not merged and then deleted.
    messy = page("<div class=\"chapter\">\n <div class=\"section\">x</div>\n  <div class=\"section\">y</div>\n </div>")
    once = format_text(messy)
    assert_includes once, "<div class=\"chapter\">\n      <div class=\"section\">x</div>\n      <div class=\"section\">y</div>\n    </div>"
    assert_equal once, format_text(once)
    long = 'word ' * 80
    text = format_text(page("<p>#{long}</p>"))
    assert_includes text, "<p>#{long}</p>"
    refute_match(%r{<p>[^<]*\n}, text)
  end

  def test_table_cells_start_lines_and_keep_their_text
    pretty = format_text(page('<div><table><tr><td>mi</td><td>klama</td></tr></table></div>'))
    assert_includes pretty, "<td>mi</td>\n          <td>klama</td>"
    refute_includes pretty, "<td>\n"
    assert_equal pretty, format_text(pretty)
  end

  def test_inline_text_and_verbatim_text_stay_byte_for_byte
    inline = format_text(page('<p id="quotes"><a class="indexterm" id="index"/>the <span><em>error-correction quotes</em></span> <span>lo\'ai</span>, sa\'ai, and le\'ai</p><table><tr><td id="connective"><span>ga</span> <span>nai</span> - <span>gi</span></td></tr></table>'))
    assert_includes inline, '</span> <span>lo\'ai</span>, sa\'ai'
    assert_includes inline, '<span>ga</span> <span>nai</span> - <span>gi</span>'
    kept = format_text(page("<pre>  a\n b</pre>"))
    assert_includes kept, "<pre>  a\n b</pre>"
    js = "\n    keep this line\n    "
    head = %(#{META}<script xmlns="" type="text/javascript">#{js}</script>)
    scripted = format_text(page('<p>a</p>', head: head))
    assert_includes scripted, "<script xmlns=\"\" type=\"text/javascript\">#{js}</script>"
    foreign = format_text(page('<div xmlns="">  <span>a</span> </div>'))
    assert_includes foreign, '<div xmlns="">  <span>a</span> </div>'
    spaced = format_text(page('<div xml:space="preserve">a  b</div>'))
    assert_includes spaced, '<div xml:space="preserve">a  b</div>'
    odd = format_text(page("<p>\n\t </p>"))
    assert_includes odd, "<p>\n\t </p>"
    marked = "a\u00A0b\u200Bc"
    assert_includes format_text(page("<p>#{marked}</p>")), marked
  end

  def test_excluded_parents_keep_their_whitespace
    source = page("<div class=\"book\">\t<div class=\"chapter\">x</div></div>")
    assert_includes format_text(source), "<div class=\"book\">\t<div class=\"chapter\">x</div>"
  end

  def test_head_children_each_start_a_line
    head = %(#{META}<title>Chapter</title><link rel="stylesheet" href="final.css" type="text/css" />)
    pretty = format_text(page('<p>Hi</p>', head: head))
    assert_match(%r{<html xmlns="http://www.w3.org/1999/xhtml">\n  <head>\n}, pretty)
    refute_match(%r{<html[^>]*><head>}, pretty)
    assert_includes pretty, "</head><body>"
    assert_includes pretty, "<head>\n    <meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />\n"
    assert_includes pretty, "\n    <title>Chapter</title>\n    <link rel=\"stylesheet\" href=\"final.css\" type=\"text/css\" />\n  </head>"
  end

  def test_a_missing_content_type_meta_is_stable
    bare = page('<div class="chapter"><div class="section">x</div></div>', head: '<title>T</title>')
    once = format_text(bare)
    assert_equal 1, once.scan('Content-Type').length
    assert_equal once, format_text(once)
  end

  def test_the_prolog_and_empty_elements_survive_a_second_format
    source = page('<p>a<br />b</p>')
    once = format_text(source)
    assert once.start_with?("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n#{DOCTYPE}\n")
    assert_equal once, format_text(once)
    assert_includes rendered_chars(once), 'ab'
  end

  def test_a_comment_between_blocks_keeps_the_bytes_around_it
    source = page("<div class=\"chapter\"><div class=\"section\">a</div> \n<!-- n --><div class=\"section\">b</div></div>")
    assert_includes format_text(source), "</div> \n<!-- n --><div"
  end
end

class GuardMutations < Minitest::Test
  def refute_guard(before, after, needle)
    error = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(before, after, name: 'chapter-tour.html')
    end
    assert_includes error.message, 'chapter-tour.html'
    assert_includes error.message, needle
  end

  def test_free_whitespace_may_change_and_other_whitespace_may_not
    pretty = format_text(page('<div class="chapter"><div class="section">x</div></div>'))
    moved = pretty.sub(/\n +<div class="section">/, "\n<div class=\"section\">")
    refute_equal pretty, moved
    HtmlWhitespaceGuard.compare!(pretty, moved, name: 'chapter-tour.html')
    error = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(pretty, moved, name: 'chapter-tour.html', strict: true)
    end
    assert_includes error.message, 'whitespace'

    # A space in the same text node as a letter is text, not a free gap.
    hugged = format_text(page('<p>a <em>b</em></p>'))
    refute_guard(hugged, hugged.sub('a <em>', 'a<em>'), 'text differs')
    inline = format_text(page('<p><em>a</em> <em>b</em></p>'))
    refute_guard(inline, inline.sub('</em> <em>', '</em><em>'), 'whitespace')
    refute_guard(inline, inline.sub('</em> <em>', "</em>\n<em>"), 'whitespace')
    pre = format_text(page('<pre><span>a</span> <span>b</span></pre>'))
    refute_guard(pre, pre.sub('</span> <span>', '</span><span>'), 'whitespace')
  end

  def test_two_whitespace_nodes_differ_from_one_outside_a_free_gap
    left = parse(page('<p> <em>a</em></p>'))
    right = parse(page('<p> <em>a</em></p>'))
    em = left.at_xpath('//*[local-name()="em"]')
    em.previous.add_previous_sibling(Nokogiri::XML::Text.new(' ', left))
    error = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare_children(left, right, 'chapter-tour.html', false)
    end
    assert_includes error.message, 'chapter-tour.html'
  end

  def test_non_whitespace_changes_are_rejected
    pretty = format_text(page('<p id="i" class="plain">a <em>b</em></p>'))
    refute_guard(pretty, pretty.sub('>a <', '>z <'), 'text differs')
    refute_guard(pretty, pretty.sub('<em>', '<strong>').sub('</em>', '</strong>'), 'became')
    refute_guard(pretty, pretty.sub('id="i" class="plain"', 'class="plain" id="i"'), 'attributes')
    refute_guard(pretty, pretty.sub('class="plain"', 'class="other"'), 'attributes')
    refute_guard(page('<div xmlns:z="urn:z">t</div>'), page('<div xmlns:z="urn:other">t</div>'), 'namespace')
    left = '<div xmlns:a="urn:a" xmlns:b="urn:b">t</div>'
    right = '<div xmlns:b="urn:b" xmlns:a="urn:a">t</div>'
    refute_guard(page(left), page(right), 'namespace')
    refute_guard(page('<!-- note -->'), page('<!-- notes -->'), 'comment')
    refute_guard(page('<?mark yes?><p>a</p>'), page('<?mark no?><p>a</p>'), 'processing instruction')
  end

  def test_prolog_changes_are_rejected
    source = page('<p>a</p>')
    refute_guard(source, source.sub('UTF-8', 'utf-8'), 'XML declaration')
    refute_guard(source, source.sub('xhtml1-transitional.dtd', 'xhtml1-strict.dtd'), 'DOCTYPE')
    subset = source.sub('xhtml1-transitional.dtd">', 'xhtml1-transitional.dtd" [<!ELEMENT html ANY>]>')
    refute_guard(source, subset, 'DOCTYPE')
    refute_guard("\uFEFF#{source}", source, 'XML declaration')
  end

  def test_named_entities_and_parse_errors_name_the_page
    HtmlWhitespaceGuard.compare!(page('&amp;&lt;&gt;&quot;&apos;&#65;'), page('&amp;&lt;&gt;&quot;&apos;&#65;'), name: 'chapter-tour.html')
    refute_guard(page('&nbsp;'), page('&nbsp;'), '&nbsp;')
    refute_guard(page('&z;'), page('&z;'), '&z;')
    broken = page('<p>a</p>').sub('<p>a</p>', '<p>a</p')
    error = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(broken, page('<p>a</p>'), name: 'chapter-tour.html')
    end
    assert_includes error.message, 'chapter-tour.html'
    assert_includes error.message, 'original side'
    error = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(page('<p>a</p>'), broken, name: 'chapter-tour.html')
    end
    assert_includes error.message, 'formatted side'
  end
end

class CleanupIntegration < Minitest::Test
  def test_none_mode_changes_no_gap_and_an_unknown_mode_fails
    source = page('<p id="quotes"><a class="indexterm" id="index"/>the <span>lo\'ai</span> <span>sa\'ai</span></p>')
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'sample.html')
      File.write(file, source)
      env = ENV.to_h.merge('CLL_HTML_FORMAT' => 'none')
      stdout, stderr, status = Open3.capture3(env, 'ruby', File.join(ROOT, 'scripts/xhtml_postprocess_cleanup_file.rb'), file, chdir: ROOT)
      assert status.success?, stderr
      HtmlWhitespaceGuard.compare!(source, stdout, name: file, strict: true)
      env['CLL_HTML_FORMAT'] = 'fancy'
      _stdout, stderr, status = Open3.capture3(env, 'ruby', File.join(ROOT, 'scripts/xhtml_postprocess_cleanup_file.rb'), file, chdir: ROOT)
      refute status.success?
      assert_includes stderr, 'CLL_HTML_FORMAT'
    end
  end

  def test_cleanup_keeps_the_page_when_the_guard_fails
    Dir.mktmpdir do |dir|
      scripts = File.join(dir, 'scripts')
      Dir.mkdir(scripts)
      %w[xhtml_postprocess_cleanup.sh xhtml_postprocess_cleanup_file.rb html_format.rb html_whitespace_guard.rb util.rb].each do |name|
        FileUtils.cp(File.join(ROOT, 'scripts', name), File.join(scripts, name))
      end
      cleanup = File.join(scripts, 'xhtml_postprocess_cleanup_file.rb')
      source = File.read(cleanup)
      patched = source.sub("HtmlFormat.format!($document)\n") do
        <<~'RUBY'
          HtmlFormat.format!($document)
            em = $document.at_xpath('//*[local-name()="em"]')
            gap = em&.next_sibling
            gap.unlink if gap&.text? && !gap.content.empty? && gap.content.match?(/\A[ \t\n\r\f]+\z/)
        RUBY
      end
      refute_equal source, patched
      File.write(cleanup, patched)
      pages = File.join(dir, 'pages')
      Dir.mkdir(pages)
      FileUtils.cp_r(File.join(ROOT, 'dtd'), File.join(pages, 'dtd'))
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

  def test_formatter_output_satisfies_the_epub_line_contract
    js = "\nkeep this line\n"
    head = %(#{META}<title>Chapter</title><link rel="stylesheet" href="final.css" type="text/css" /><script xmlns="" type="text/javascript">#{js}</script>)
    body = '<p summary="drop">Reader</p>'
    # DocBook puts the DOCTYPE, the html start tag, and head on one line.
    source = %(<?xml version="1.0" encoding="UTF-8"?>\n#{DOCTYPE}<html xmlns="http://www.w3.org/1999/xhtml"><head>#{head}</head><body>#{body}</body></html>\n)
    pretty = format_text(source)
    lines = pretty.lines
    assert lines[0].start_with?('<?xml'), lines[0, 3].inspect
    assert lines[1].start_with?('<!DOCTYPE'), lines[0, 3].inspect
    assert lines[2].start_with?('<html'), lines[0, 3].inspect
    assert lines[2].strip.end_with?('>'), lines[2]
    refute_includes lines[2], '<head'
    text = File.read(File.join(ROOT, 'scripts/build_epub.sh'))
    match = text.match(/for file in \$\(find \$epubbuilddir\/ -name '\*\.html'\)\ndo\n(.*?)\ndone\n/m)
    raise 'packager HTML loop not found' unless match
    file = Tempfile.new(['epub-page', '.html'])
    file.write(pretty)
    file.close
    script = "set -e\nfile=#{Shellwords.escape(file.path)}\n#{match[1]}\ntrue\n"
    _out, err, status = Open3.capture3('bash', '-c', script)
    assert status.success?, err
    edited = File.read(file.path)
    assert_includes edited, '<title>Chapter</title>'
    assert_includes edited, 'href="final.css"'
    assert_includes edited, 'keep this line'
    refute_includes edited, '<!DOCTYPE'
    refute_includes edited, '<meta'
    refute_includes edited, 'summary='
    refute_includes edited, '<script'
  ensure
    file&.unlink
  end
end

class ReviewCorpus < Minitest::Test
  def test_adversarial_pages_keep_rendered_text
    roots = Dir['/build/cll/review-207-*']
    skip 'the review corpus is not on this machine' if roots.empty?
    failures = []
    count = 0
    roots.each do |root|
      Dir.glob(File.join(root, '**/*-before.html')).each do |before_path|
        parts = before_path.split('/')
        next if parts.include?('pages') || parts.any? { |part| part.start_with?('mut-') }
        count += 1
        begin
          check_page(before_path, failures)
        rescue StandardError => error
          failures << "#{before_path}: #{error}"
        end
      end
    end
    assert count > 100, "expected the review corpus, found #{count}"
    assert_empty failures.take(30)
  end

  def check_page(path, failures)
    text = File.read(path)
    if entity_problem?(text, path)
      check_after(path, text, failures)
      return
    end
    once = format_text(text)
    twice = format_text(once)
    failures << "#{path}: a second format changed the bytes" unless once == twice
    failures << "#{path}: rendered text changed" unless rendered_chars(text) == rendered_chars(once)
    check_after(path, text, failures)
  rescue HtmlWhitespaceGuard::Unsafe, Nokogiri::XML::SyntaxError => error
    failures << "#{path}: #{error}"
  end

  def entity_problem?(text, path)
    HtmlWhitespaceGuard.check_entities(text, path, 'original')
    false
  rescue HtmlWhitespaceGuard::Unsafe
    true
  end

  def check_after(path, before_text, failures)
    after_path = path.sub(/-before\.html\z/, '-after.html')
    return unless File.file?(after_path)
    after_text = File.read(after_path)
    changed = rendered_chars(before_text) != rendered_chars(after_text)
    return unless changed
    HtmlWhitespaceGuard.compare!(before_text, after_text, name: path)
    failures << "#{after_path}: the guard accepted a rendered-text change"
  rescue HtmlWhitespaceGuard::Unsafe, Nokogiri::XML::SyntaxError
    nil
  end
end
