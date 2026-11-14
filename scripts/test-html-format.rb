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

# The real cleanup shell. Optional class lists patch a copy of the formatter
# the way a stylesheet change updates the constants, then the shell runs.
def run_cleanup(source, freeze_classes: nil, exclusion_classes: nil)
  Dir.mktmpdir do |dir|
    shell = File.join(ROOT, 'scripts/xhtml_postprocess_cleanup.sh')
    if freeze_classes || exclusion_classes
      scripts = File.join(dir, 'scripts')
      Dir.mkdir(scripts)
      %w[xhtml_postprocess_cleanup.sh xhtml_postprocess_cleanup_file.rb html_format.rb html_whitespace_guard.rb util.rb].each do |name|
        FileUtils.cp(File.join(ROOT, 'scripts', name), File.join(scripts, name))
      end
      format_path = File.join(scripts, 'html_format.rb')
      text = File.read(format_path)
      if freeze_classes
        replacement = "FREEZE_CLASSES = %w[#{freeze_classes.join(' ')}].freeze"
        rewritten = text.sub('FREEZE_CLASSES = [].freeze', replacement)
        raise 'freeze constant not patched' if rewritten == text
        text = rewritten
      end
      if exclusion_classes
        rewritten = text.sub(/EXCLUSION_CLASSES = %w\[(.*?)\]\.freeze/m) do
          "EXCLUSION_CLASSES = %w[#{Regexp.last_match(1)} #{exclusion_classes.join(' ')}].freeze"
        end
        raise 'exclusion constant not patched' if rewritten == text
        text = rewritten
      end
      File.write(format_path, text)
      shell = File.join(scripts, 'xhtml_postprocess_cleanup.sh')
    end
    pages = File.join(dir, 'pages')
    Dir.mkdir(pages)
    FileUtils.cp_r(File.join(ROOT, 'dtd'), File.join(pages, 'dtd'))
    path = File.join(pages, 'page.html')
    File.write(path, source)
    _out, err, status = Open3.capture3('bash', shell, pages)
    [status.success?, err, File.read(path)]
  end
end

# Whitespace runs become one space. A whitespace-only node that CSS drops
# (inside html or head, or between blocks) is omitted, so an indent at a
# free gap compares equal. A run beside inline text stays, so "AB" and
# "A B" differ.
def collapsed_whitespace(text)
  document = parse(text)
  chunks = []
  document.xpath('//text()').each do |node|
    content = node.content
    if HtmlFormat.whitespace_only?(content)
      chunks << ' ' unless ignorable_gap?(node)
    else
      chunks << content.gsub(/[ \t\r\n\f]+/, ' ')
    end
  end
  chunks.join
end

def ignorable_gap?(node)
  parent = node.parent
  return false unless parent&.element?
  return true if parent.name == 'html' || parent.name == 'head'
  return false unless HtmlFormat::BLOCK_TAG[parent.name]
  left = neighbor_element(node, :previous)
  right = neighbor_element(node, :next)
  (left.nil? || block_element?(left)) && (right.nil? || block_element?(right))
end

def neighbor_element(node, direction)
  current = node
  loop do
    current = direction == :previous ? current.previous : current.next
    return nil unless current
    next if current.text? && HtmlFormat.whitespace_only?(current.content)
    return current
  end
end

def block_element?(node)
  node.element? && HtmlFormat::BLOCK_TAG[node.name]
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
    preserve_tags = []
    preserve_classes = []
    Dir[File.join(ROOT, 'assets/css/*.css')].sort.each do |path|
      found = HtmlStylesheetScan.classify(File.read(path), source: path)
      tags.concat(found[0])
      classes.concat(found[1])
      preserve_tags.concat(found[2])
      preserve_classes.concat(found[3])
    end
    compared = comparison_sets
    tags.concat(compared[0])
    classes.concat(compared[1])
    preserve_tags.concat(compared[2])
    preserve_classes.concat(compared[3])
    assert_equal HtmlFormat::EXCLUSION_TAGS.sort, tags.uniq.sort
    assert_equal HtmlFormat::EXCLUSION_CLASSES.sort, classes.uniq.sort
    assert_equal HtmlFormat::FREEZE_TAGS.sort, preserve_tags.uniq.sort
    assert_equal HtmlFormat::FREEZE_CLASSES.sort, preserve_classes.uniq.sort
  end

  def test_each_unreadable_construct_names_the_rule
    assert_unreadable('div\x { display: block }', 'div\x')
    assert_unreadable('@import "other.css";', '@import')
    assert_unreadable('@layer widgets { p { display: block } }', '@layer')
    assert_unreadable('p[hidden] { display: none }', 'p[hidden]')
    assert_unreadable('#main { display: block }', '#main')
    assert_unreadable('p:first-child { display: block }', 'p:first-child')
    assert_unreadable('p:before { display: block }', 'p:before')
    # ::before is the pseudo-element box, not the element.
    tags, classes, preserve_tags, preserve_classes = HtmlStylesheetScan.classify(
      'p.status-note::before { position: absolute; display: block }', source: 'fixture.css'
    )
    assert_empty tags
    assert_empty classes
    assert_empty preserve_tags
    assert_empty preserve_classes
    assert_unreadable('p { display: var(--d) }', 'var(--d)')
    assert_unreadable("p { display: block }\n/* oops", 'comment')
    assert_unreadable('p { display: \62 lock }', '\62')
    assert_unreadable('@page { display: block }', '@page')
    assert_unreadable('@font-face { display: block }', '@font-face')
    assert_unreadable('@page { white-space: pre }', '@page')
    assert_unreadable('@font-face { float: left }', '@font-face')
    assert_unreadable('@page { position: absolute }', '@page')
    assert_unreadable('@font-face { all: initial }', '@font-face')
    assert_unreadable('p:first-child { white-space: pre }', 'p:first-child')
    assert_unreadable('div { white-space: var(--w) }', 'var(--w)')
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
    assert_equal %w[h1], tags.uniq.sort
    assert_empty classes
    refute_includes classes, 'secret'
  end

  # Only the last compound is the subject. display:block, list-item, and a
  # table box exclude nothing. inline-table and every other display value
  # exclude, and so does a visibility value other than visible.
  def test_only_the_subject_is_excluded_and_block_display_is_harmless
    css = <<~CSS
      .article > .titlepage hr { display: none }
      .whole-index h3 { display: none }
      .book > .titlepage .release-version, .release-date { display: block }
      p { display: block }
      li { display: list-item }
      div { display: table }
      td { display: table-cell }
      tr { display: table-row }
      caption { display: table-caption }
      col { display: table-column }
      colgroup { display: table-column-group }
      thead { display: table-header-group }
      tbody { display: table-row-group }
      tfoot { display: table-footer-group }
      span.tutci { display: inline-block }
      div.as-table { display: inline-table }
      section.row { display: flex }
      p.hidden { visibility: hidden }
      p.collapsed { visibility: collapse }
      div.skip { content-visibility: hidden; display: block }
      div.auto { content-visibility: auto }
      p.gone { display: none }
      p.shown { visibility: visible }
      p.clear { content-visibility: visible }
      p.both { display: none; display: block }
      p.hidden-again { display: block; display: none }
      p.important { display: block; display: none !important }
      p.early { display: none !important; display: block }
      p.forced { display: none; display: block !important }
    CSS
    tags, classes = HtmlStylesheetScan.exclusion(css, source: 'subject.css')
    assert_equal %w[div h3 hr p section span], tags.uniq.sort
    assert_equal %w[as-table auto collapsed early gone hidden hidden-again important row skip tutci], classes.uniq.sort
    refute_includes tags, 'li'
    refute_includes classes, 'release-version'
    refute_includes classes, 'release-date'
    refute_includes classes, 'shown'
    refute_includes classes, 'both'
    refute_includes classes, 'forced'
    refute_includes classes, 'clear'
  end

  def test_each_flow_and_whitespace_property
    assert_sets('.probe { white-space: pre }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space: pre-wrap }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space: pre-line }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space: break-spaces }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space: nowrap }')
    assert_sets('.probe { white-space: normal }')
    assert_sets('.probe { white-space-collapse: collapse }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space-collapse: preserve }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space-collapse: preserve-breaks }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space-collapse: break-spaces }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space-collapse: normal }')
    assert_sets('.probe { white-space-collapse: nowrap }')
    assert_sets('.probe { float: left }', classes: %w[probe])
    assert_sets('.probe { float: right }', classes: %w[probe])
    assert_sets('.probe { float: inline-start }', classes: %w[probe])
    assert_sets('.probe { float: none }')
    assert_sets('.probe { position: absolute }', classes: %w[probe])
    assert_sets('.probe { position: fixed }', classes: %w[probe])
    assert_sets('.probe { position: sticky }', classes: %w[probe])
    assert_sets('.probe { position: running(title-version) }', classes: %w[probe])
    assert_sets('.probe { position: static }')
    # relative stays in the flow. Excluding it would exclude the tag p
    # from p.status-note in the book stylesheet.
    assert_sets('p.status-note { position: relative }')
    assert_sets('div.probe { all: initial }', tags: %w[div], classes: %w[probe])
    assert_sets('div.probe { all: unset }', tags: %w[div], classes: %w[probe])
    assert_sets('div.probe { all: revert }', tags: %w[div], classes: %w[probe])
    assert_sets('.probe { display: block; float: left }', classes: %w[probe])
    assert_sets('.probe { float: left !important; float: none }', classes: %w[probe])
    assert_sets('.probe { float: left; float: none !important }')
    assert_sets('.probe { white-space: normal; white-space: pre !important }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space: pre !important; white-space: normal }', preserve_classes: %w[probe])
    assert_sets('.probe { white-space: pre; white-space: nowrap !important }')
    assert_sets('p.probe { white-space: pre; float: left }', tags: %w[p], classes: %w[probe], preserve_tags: %w[p], preserve_classes: %w[probe])
  end

  def test_a_missing_comparison_stylesheet_names_the_fetch
    error = assert_raises(RuntimeError) do
      comparison_sets(refs: ['no-such-ref-207'], fetch: false)
    end
    assert_includes error.message, 'git fetch origin pages'
    assert_includes error.message, 'origin/pages'
  end

  def assert_sets(css, tags: [], classes: [], preserve_tags: [], preserve_classes: [])
    found = HtmlStylesheetScan.classify(css, source: 'fixture.css')
    assert_equal tags.sort, found[0].uniq.sort, css
    assert_equal classes.sort, found[1].uniq.sort, css
    assert_equal preserve_tags.sort, found[2].uniq.sort, css
    assert_equal preserve_classes.sort, found[3].uniq.sort, css
  end

  def comparison_sets(refs: %w[origin/pages pages], fetch: true)
    text = nil
    refs.each do |ref|
      shown, _err, status = Open3.capture3('git', 'show', "#{ref}:scripts/docbook-diff.xsl", chdir: ROOT)
      if status.success?
        text = shown
        break
      end
    end
    if text.nil?
      if fetch
        _fetched, _err, status = Open3.capture3('git', 'fetch', '--depth=1', 'origin', 'pages', chdir: ROOT)
        unless status.success?
          raise 'the comparison stylesheet on origin/pages is not available. Fetch it with: git fetch origin pages'
        end
        text, _err, status = Open3.capture3('git', 'show', 'FETCH_HEAD:scripts/docbook-diff.xsl', chdir: ROOT)
        unless status.success?
          raise 'the comparison stylesheet on origin/pages is not available. Fetch it with: git fetch origin pages'
        end
      else
        raise 'the comparison stylesheet on origin/pages is not available. Fetch it with: git fetch origin pages'
      end
    end
    match = text.match(/<style\b[^>]*>(.*?)<\/style>/m)
    raise 'the comparison page has no style element' unless match
    css = match[1].gsub(%r{</?xsl:text>}, '')
    HtmlStylesheetScan.classify(css, source: 'docbook-diff.xsl')
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
    assert block?('<p>x</p>', 'p')
    assert block?('<div class="book">x</div>', 'div')
    assert block?('<div class="chapter book">x</div>', 'div')
    refute block?('<h3>x</h3>', 'h3')
    refute block?('<hr />', 'hr')
    refute block?('<head><title>T</title></head>', 'head')
    refute block?('<br />', 'br')
    refute block?('<span class="tutci">x</span>', 'span')
    refute block?('<div hidden="hidden">x</div>', 'div')
    refute block?('<p hidden="">x</p>', 'p')
    assert block?('<h2 style="clear: both">x</h2>', 'h2')
    assert block?('<ul style="list-style-type: disc; ">x</ul>', 'ul')
    assert block?('<h2 style="clear: both; list-style-type: disc">x</h2>', 'h2')
    refute block?('<div style="display:none">x</div>', 'div')
    refute block?('<div style="display: inline">x</div>', 'div')
    refute block?('<div style="float:left">x</div>', 'div')
    refute block?('<div style="position:absolute">x</div>', 'div')
    refute block?('<div style="all: initial">x</div>', 'div')
    refute block?('<div style="white-space: pre">x</div>', 'div')
    refute block?('<div style="white-space: nowrap">x</div>', 'div')
    refute block?('<div style="clear: left">x</div>', 'div')
    pre_style = element(page('<div style="white-space: pre-wrap">x</div>'), 'div')
    refute HtmlFormat.visible_block?(pre_style)
    assert HtmlFormat.verbatim?(pre_style)
    nowrap = element(page('<div style="white-space: nowrap">x</div>'), 'div')
    refute HtmlFormat.verbatim?(nowrap)
    clear = element(page('<h2 style="clear: both">x</h2>'), 'h2')
    refute HtmlFormat.verbatim?(clear)
    refute block?('<div><colgroup></colgroup></div>', 'colgroup')
    refute block?('<div><col /></div>', 'col')
    refute block?('<div><thead></thead></div>', 'thead')
    refute block?('<div><tbody></tbody></div>', 'tbody')
    refute block?('<div><tfoot></tfoot></div>', 'tfoot')
    refute block?('<div><tr></tr></div>', 'tr')
    refute block?('<div><td></td></div>', 'td')
    refute block?('<div><th></th></div>', 'th')
    refute block?('<div><caption></caption></div>', 'caption')
    refute block?('<table><td>x</td></table>', 'td')
    assert block?('<table><caption>c</caption></table>', 'caption')
    assert block?('<table><colgroup><col /></colgroup></table>', 'colgroup')
    assert block?('<table><colgroup><col /></colgroup></table>', 'col')
    assert block?('<table><col /></table>', 'col')
    assert block?('<table><thead><tr><th>h</th></tr></thead></table>', 'thead')
    assert block?('<table><tbody><tr><td>a</td></tr></tbody></table>', 'tbody')
    assert block?('<table><tfoot><tr><td>a</td></tr></tfoot></table>', 'tfoot')
    assert block?('<table><tr><td>a</td></tr></table>', 'tr')
    assert block?('<table><thead><tr><th>h</th></tr></thead></table>', 'tr')
    assert block?('<table><tr><td>a</td><th>b</th></tr></table>', 'td')
    assert block?('<table><tr><td>a</td><th>b</th></tr></table>', 'th')
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
    assert HtmlFormat.free_gap?(chapter, sigs[0], sigs[1])
    assert HtmlFormat.free_gap?(chapter, sigs[1], sigs[2])
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

    ruled = parse(page('<div class="chapter"><div class="section">a</div><hr /><div class="section">b</div></div>'))
    ruled_parent = ruled.at_xpath('//*[@class="chapter"]')
    ruled_sigs, = HtmlFormat.split_children(ruled_parent)
    refute HtmlFormat.free_gap?(ruled_parent, ruled_sigs[0], ruled_sigs[1])
    refute HtmlFormat.free_gap?(ruled_parent, ruled_sigs[1], ruled_sigs[2])

    noted = parse(page('<div class="chapter"><div class="section">a</div><!-- n --><div class="section">b</div></div>'))
    noted_parent = noted.at_xpath('//*[@class="chapter"]')
    noted_sigs, = HtmlFormat.split_children(noted_parent)
    refute HtmlFormat.free_gap?(noted_parent, noted_sigs[0], noted_sigs[1])

    [chapter, parent, pre, head, html, ruled_parent, noted_parent].each do |node|
      assert_flags_match(node)
    end
  end

  def test_a_marked_head_keeps_its_gaps
    %w[class="tutci" id="x" style="display:inline" hidden="hidden"].each do |attr|
      marked = parse(%(<html xmlns="http://www.w3.org/1999/xhtml"><head #{attr}><style>/*A*/</style><style>/*B*/</style></head><body><p>a</p></body></html>))
      head = marked.at_xpath('//*[local-name()="head"]')
      sigs, = HtmlFormat.split_children(head)
      refute HtmlFormat.free_gap?(head, nil, sigs[0]), attr
      refute HtmlFormat.free_gap?(head, sigs[0], sigs[1]), attr
      refute HtmlFormat.free_gap?(head, sigs[1], nil), attr
      html = marked.at_xpath('//*[local-name()="html"]')
      refute HtmlFormat.free_gap?(html, nil, head), attr
      assert_flags_match(head)
      assert_flags_match(html)
    end
    styled = parse(page('<p>a</p>', head: '<style class="tutci">/*A*/</style><style class="tutci">/*B*/</style>'))
    head = styled.at_xpath('//*[local-name()="head"]')
    sigs, = HtmlFormat.split_children(head)
    refute HtmlFormat.free_gap?(head, sigs[0], sigs[1])
    broken = parse(page('<p>a</p>', head: '<title>T</title><br /><meta name="g" content="x" />'))
    head = broken.at_xpath('//*[local-name()="head"]')
    sigs, = HtmlFormat.split_children(head)
    refute HtmlFormat.free_gap?(head, sigs[0], sigs[1])
    refute HtmlFormat.free_gap?(head, sigs[1], sigs[2])
    assert_flags_match(head)
  end

  def assert_flags_match(parent)
    sigs, = HtmlFormat.split_children(parent)
    flags = HtmlFormat.free_gap_flags(parent, sigs)
    assert_equal sigs.length + 1, flags.length
    (sigs.length + 1).times do |index|
      left = index.zero? ? nil : sigs[index - 1]
      right = index == sigs.length ? nil : sigs[index]
      assert_equal HtmlFormat.free_gap?(parent, left, right), flags[index]
    end
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
    paras = format_text(page('<div class="chapter"><p>One</p><p>Two</p></div>'))
    assert_includes paras, "<p>One</p>\n      <p>Two</p>"
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
    book = page("<div class=\"book\">\t<div class=\"chapter\">x</div></div>")
    assert_includes format_text(book), "<div class=\"book\">\n      <div class=\"chapter\">x</div>\n    </div>"
    hidden = page("<div class=\"display-none\">\t<div class=\"chapter\">x</div></div>")
    assert_includes format_text(hidden), "<div class=\"display-none\">\t<div class=\"chapter\">x</div>"
    heading = page("<h3>\t<span>x</span></h3>")
    assert_includes format_text(heading), "<h3>\t<span>x</span></h3>"
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
    moved_ns = page('<p>a</p>').sub('http://www.w3.org/1999/xhtml', 'urn:other')
    refute_guard(page('<p>a</p>'), moved_ns, 'namespace http://www.w3.org/1999/xhtml became urn:other')
    refute_guard(page('<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>'),
                 page('<math xmlns="urn:math"><mi>x</mi></math>'),
                 'namespace http://www.w3.org/1998/Math/MathML became urn:math')
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

class ReviewerCases < Minitest::Test
  def assert_cleanup(source, snippet, **options)
    once = format_text(source)
    assert_includes once, snippet
    assert_equal once, format_text(once)
    ok, err, cleaned = run_cleanup(source, **options)
    assert ok, err
    assert_includes cleaned, snippet
    assert_equal cleaned, format_text(cleaned)
  end

  def assert_patched(source, snippet, **options)
    ok, err, cleaned = run_cleanup(source, **options)
    assert ok, err
    assert_includes cleaned, snippet
  end

  def test_hidden_and_inline_style_do_not_open_a_gap
    hidden = '<div><span>A</span><div hidden="hidden"></div><div hidden="hidden"></div><span>B</span></div>'
    assert_cleanup(page(hidden), hidden)
    none = '<div><span>A</span><div style="display:none"></div><div style="display:none"></div><span>B</span></div>'
    assert_cleanup(page(none), none)
    inline = '<div><div style="display:inline">a</div><div style="display:inline">b</div></div>'
    assert_cleanup(page(inline), inline)
    floated = '<div><span>A</span><div style="float:left">F</div><div style="float:left">G</div><span>B</span></div>'
    assert_cleanup(page(floated), floated)
    pinned = '<div><span>A</span><div style="position:absolute">F</div><div style="position:absolute">G</div><span>B</span></div>'
    assert_cleanup(page(pinned), pinned)
    reset = '<div><span>A</span><div style="all: initial">F</div><div style="all: unset">G</div><span>B</span></div>'
    assert_cleanup(page(reset), reset)
  end

  def test_preserving_white_space_freezes_the_subtree
    direct = '<div style="white-space: pre-wrap"><p>a</p><p>b</p></div>'
    assert_cleanup(page(direct), direct)
    nested = '<div style="white-space: pre"><div><p>a</p><p>b</p></div></div>'
    assert_cleanup(page(nested), nested)
    %w[pre pre-line break-spaces].each do |value|
      body = %(<div style="white-space: #{value}"><p>a</p><p>b</p></div>)
      assert_cleanup(page(body), body)
    end
    inherited = '<div class="ws"><div><p>a</p><p>b</p></div></div>'
    assert_patched(page(inherited), inherited, freeze_classes: ['ws'])
  end

  def test_a_stylesheet_subject_is_not_a_gap_block
    body = '<div><span>A</span><div class="probe">F</div><div class="probe">G</div><span>B</span></div>'
    assert_patched(page(body), body, exclusion_classes: ['probe'])
  end

  def test_a_revealed_head_keeps_its_bytes
    source = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      #{DOCTYPE}
      <html xmlns="http://www.w3.org/1999/xhtml"><head class="tutci"><meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /><title>T</title><style type="text/css" class="tutci">/*A*/</style><style type="text/css" class="tutci">/*B*/</style></head><body><p>Body</p></body></html>
    XML
    once = format_text(source)
    assert_includes once, '<html xmlns="http://www.w3.org/1999/xhtml"><head class="tutci">'
    assert_includes once, '<style type="text/css" class="tutci">/*A*/</style><style type="text/css" class="tutci">/*B*/</style>'
    assert_equal once, format_text(once)
    ok, err, cleaned = run_cleanup(source)
    assert ok, err
    assert_includes cleaned, 'lang="en"><head class="tutci">'
    assert_includes cleaned, '/*A*/</style><style type="text/css" class="tutci">/*B*/'
  end

  def test_misplaced_table_parts_stay_joined_and_a_real_table_indents
    %w[colgroup col thead tbody tfoot tr td th caption].each do |tag|
      empty = tag == 'col' ? '<col />' : "<#{tag}></#{tag}>"
      body = "<div><span>A</span>#{empty}#{empty}<span>B</span></div>"
      assert_cleanup(page(body), body)
    end
    table = '<div><table><caption>c</caption><colgroup><col /><col /></colgroup><thead><tr><th>h</th></tr></thead><tbody><tr><td><p>a</p><p>b</p></td><td>d</td></tr></tbody><tfoot><tr><td>f</td></tr></tfoot></table></div>'
    pretty = format_text(page(table))
    assert_includes pretty, "<caption>c</caption>\n        <colgroup>"
    assert_includes pretty, "<col />\n          <col />"
    assert_includes pretty, "<th>h</th>"
    assert_match(%r{<p>a</p>\n +<p>b</p>}, pretty)
    assert_equal pretty, format_text(pretty)
    ok, err, cleaned = run_cleanup(page(table))
    assert ok, err
    assert_match(%r{<p>a</p>\n +<p>b</p>}, cleaned)
  end
end

class ReviewCorpus < Minitest::Test
  CORPUS = File.join(ROOT, 'tests/fixtures/html-format/corpus')
  MUTATIONS = File.join(ROOT, 'tests/fixtures/html-format/mutations')

  def test_corpus_pages_keep_collapsed_whitespace
    paths = Dir[File.join(CORPUS, '*.html')].sort
    assert paths.length > 100, "expected the copied review corpus, found #{paths.length}"
    failures = []
    paths.each do |path|
      check_page(path, failures)
    rescue StandardError => error
      failures << "#{path}: #{error}"
    end
    assert_empty failures.take(20)
  end

  def test_a_whitespace_mutation_is_not_accepted
    before_path = File.join(MUTATIONS, 'span-space-before.html')
    after_path = File.join(MUTATIONS, 'span-space-after.html')
    before_text = File.read(before_path)
    after_text = File.read(after_path)
    refute_equal collapsed_whitespace(before_text), collapsed_whitespace(after_text)
    error = assert_raises(HtmlWhitespaceGuard::Unsafe) do
      HtmlWhitespaceGuard.compare!(before_text, after_text, name: before_path)
    end
    assert_includes error.message, 'whitespace'
  end

  def check_page(path, failures)
    text = File.read(path)
    if entity_problem?(text, path)
      return
    end
    once = format_text(text)
    twice = format_text(once)
    failures << "#{File.basename(path)}: a second format changed the bytes" unless once == twice
    unless collapsed_whitespace(text) == collapsed_whitespace(once)
      failures << "#{File.basename(path)}: collapsed whitespace changed"
    end
  rescue HtmlWhitespaceGuard::Unsafe, Nokogiri::XML::SyntaxError => error
    failures << "#{File.basename(path)}: #{error}"
  end

  def entity_problem?(text, path)
    HtmlWhitespaceGuard.check_entities(text, path, 'original')
    false
  rescue HtmlWhitespaceGuard::Unsafe
    true
  end
end
