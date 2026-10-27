#!/usr/bin/env ruby
# Convert the shared, preprocessed DocBook tree, without an HTML or XSL stage.
require 'json'
require 'nokogiri'
require 'fileutils'
require 'optparse'

class DocBookTypst
  attr_reader :document, :references, :stats

  def initialize(path, allow_missing: false)
    @allow_missing = allow_missing
    @document = Nokogiri::XML(File.open(path)) { |c| c.strict.dtdload.noent.nonet }
    @document.remove_namespaces!
    @references = {}
    @numbers = {}
    @stats = Hash.new(0)
    @indexes = {}
    @index_types = @document.xpath('/book/index').map { |n| n['type'] }
    @document.xpath('//*[@id]').each do |n|
      raise "Duplicate XML ID: #{n['id']}" if @references.key?(n['id'])
      @references[n['id']] = n
    end
    number_components
    @index_entries = {}
    @document.xpath('//indexterm').each do |n|
      next unless @index_types.include?(n['type'])
      # Hidden paragraphs and controls do not occur in the print output.
      next if n.ancestors.any? { |a| a['role'] == 'display-none' || a.name == 'guibutton' }
      path = %w[primary secondary tertiary].filter_map { |name| n.at_xpath(name) }
      next if path.empty?
      key = JSON.generate([n['type'], *path.map { |p| plain(p) }])
      @indexes[n.path] = key
      @index_entries[key] ||= {type: n['type'], nodes: path, see: [], seealso: []}
      %w[see seealso].each { |name| @index_entries[key][name.to_sym] |= n.xpath(name).map { |x| plain(x) } }
    end
  end

  def number_components
    chapter = 0
    article = 0
    @document.root.element_children.each do |component|
      case component.name
      when 'chapter'
        chapter += 1
        @numbers[component.path] = chapter.to_s
      when 'article', 'appendix'
        article += 1
        @numbers[component.path] = (64 + article).chr
      end
      number_sections(component, @numbers[component.path])
      %w[example table figure].each do |kind|
        component.xpath(".//#{kind}").each_with_index do |node, i|
          @numbers[node.path] = [@numbers[component.path], i + 1].compact.join('.')
        end
      end
    end
  end

  def number_sections(parent, prefix)
    parent.xpath('./section').each_with_index do |section, i|
      @numbers[section.path] = [prefix, i + 1].compact.join('.')
      number_sections(section, @numbers[section.path])
    end
  end

  def q(value)
    # JSON string syntax is also valid Typst string syntax for these characters.
    JSON.generate(value.to_s).gsub("\u2028", '\\u{2028}').gsub("\u2029", '\\u{2029}')
  end

  def plain(node)
    return '' unless node
    copy = node.dup
    copy.xpath('.//indexterm | .//anchor').remove
    copy.text.gsub(/\s+/, ' ').strip
  end

  def children(node, except: [])
    block = %w[book chapter section article appendix example glossary glossdiv glossdef variablelist varlistentry itemizedlist orderedlist listitem mediaobject].include?(node.name)
    node.children.reject { |n| (n.element? && except.include?(n.name)) || (block && n.text? && n.text.strip.empty?) }.map { |n| render(n) }.join
  end

  def anchor(node)
    node['id'] ? "#metadata(none)#label(#{q(node['id'])})" : ''
  end

  def content(text)
    "[#{text}]"
  end

  # XML indentation at a paragraph boundary is not visible in HTML. Keep
  # index and anchor nodes in place while trimming the surrounding text.
  def trim_list_paragraph_edge(node, trailing: false)
    nodes = node.children.to_a
    nodes.reverse! if trailing
    nodes.each do |child|
      if child.text?
        child.content = trailing ? child.text.rstrip : child.text.lstrip
        return true unless child.text.empty?
      elsif child.element?
        next if %w[indexterm anchor guibutton].include?(child.name) || child['role'] == 'display-none'
        return true if child.children.empty?
        return true if trim_list_paragraph_edge(child, trailing: trailing)
      end
    end
    false
  end

  def styled(node, body)
    role = node['role'].to_s
    lang = node['lang'].to_s
    if lang == 'zlm'
      body = "#text(font: \"Crisa\", size: 1.1em, weight: \"regular\", style: \"normal\")[#{body}]"
    elsif lang == 'ko'
      body = "#text(font: \"Noto Serif KR\")[#{body}]"
    elsif lang.start_with?('zh')
      body = "#text(font: \"Noto Serif SC\")[#{body}]"
    elsif lang == 'jbo' || %w[jbo jbophrase pronunciation-jbo compound-cmavo-jbo].include?(role)
      body = "#emph[#{body}]"
    end
    body = "#strong[#{body}]" if %w[selbri gloss bold].include?(role)
    body = "#text(size: 1.2em, weight: \"bold\")[#{body}]" if role == 'logical-vowel'
    body = "#text(font: \"DejaVu Sans Mono\")[#{body}]" if %w[monospace X-SAMPA].include?(role)
    body = "#underline(stroke: (paint: gray, dash: \"dotted\"))[#{body}]#super[◇]" if role == 'status-mark'
    body
  end

  def target_text(id)
    node = @references[id]
    unless node
      raise "Unresolved cross-reference: #{id}" unless @allow_missing
      warn "Reference outside this excerpt: #{id}"
      return "#{id} (outside this excerpt)"
    end
    return node['xreflabel'] if node['xreflabel']
    if node.name == 'anchor'
      node = node.ancestors.find { |a| %w[example section chapter article appendix figure table bridgehead].include?(a.name) } || node.parent
    end
    number = @numbers[node.path]
    prefix = {'chapter' => 'Chapter', 'section' => 'Section', 'example' => 'Example', 'table' => 'Table', 'figure' => 'Figure', 'appendix' => 'Appendix'}[node.name]
    return "#{prefix} #{number}" if prefix && number
    plain(node.at_xpath('title') || node)
  end

  def math(node)
    elements = node.element_children
    case node.name
    when 'math', 'mrow' then elements.map { |e| math(e) }.reject(&:empty?).join(' ')
    when 'mn'
      value = node.text.strip
      raise "Unsupported MathML number: #{value.inspect}" unless value.match?(/\A[0-9]+(?:\.[0-9]+)?\z/)
      value
    when 'mi'
      value = node.text.strip
      # Quoted strings retain surrounding spaces in Typst math. Emit native
      # letters. Reject unsupported identifiers rather than treating them as
      # text or executable Typst syntax.
      raise "Unsupported MathML identifier: #{value.inspect}" unless value.match?(/\A[A-Za-z]\z/)
      value
    when 'mo'
      value = node.text.strip
      return '' if value == "\u2062"
      {'−' => '-', '-' => '-', '+' => '+', '=' => '=', '±' => 'plus.minus', '×' => 'times', '÷' => 'div'}.fetch(value) do
        # The source uses mo for connecting words too. Keep them upright,
        # with a clause gap after a leading comma and no gap before it.
        if value.start_with?(',') && value[1..].strip.match?(/\A[[:alpha:]]/)
          "\\, quad upright(#{q(value[1..].strip)})"
        elsif value.empty?
          ''
        else
          "upright(#{q(value)})"
        end
      end
    when 'mfrac'
      raise 'mfrac requires two children' unless elements.size == 2
      "frac(#{math(elements[0])}, #{math(elements[1])})"
    when 'msup'
      raise 'msup requires two children' unless elements.size == 2
      "attach(#{math(elements[0])}, t: #{math(elements[1])})"
    when 'msub'
      raise 'msub requires two children' unless elements.size == 2
      "attach(#{math(elements[0])}, b: #{math(elements[1])})"
    when 'msqrt' then "sqrt(#{elements.map { |e| math(e) }.join(' ')})"
    else raise "Unsupported MathML element: #{node.name} at line #{node.line}"
    end
  end

  def table(node)
    rows = node.xpath('./tr | ./thead/tr | ./tbody/tr | ./tfoot/tr')
    raise "Unsupported table structure at line #{node.line}" if rows.empty?
    width = rows.map { |r| r.element_children.sum { |c| [c['colspan'].to_i, 1].max } }.max
    cells = []
    rows.each_with_index do |row, y|
      x = 0
      row.element_children.each do |cell|
        span = cell['colspan'] == '0' ? width - x : [cell['colspan'].to_i, 1].max
        raise "Unsupported table rowspan at line #{cell.line}" if cell['rowspan'].to_i > 1
        body = children(cell)
        body = "#emph[#{body}]" if row['class'] == 'jbo'
        body = "#strong[#{body}]" if row['class'] == 'gloss' || row.parent.name == 'thead' || cell.name == 'th'
        cells << "table.cell(x: #{x}, y: #{y}, colspan: #{span}, #{content(anchor(cell) + body)})"
        x += span
      end
    end
    caption = node.at_xpath('caption')
    title = caption ? "#block(sticky: true, above: 0pt, below: 3pt)[#strong[#text(#{q("Table #{@numbers[node.path]} ")})#{children(caption)}]]" : ''
    border = node['class'].to_s.split.include?('noborder') ? 'false' : 'true'
    vertical = node['class'].to_s.split.include?('vertsep') ? 'true' : 'false'
    "#{title}#cll-table(#{width}, border: #{border}, rows: #{rows.size}, vertsep: #{vertical}, #{cells.join(",\n")})\n"
  end

  def simplelist(node)
    members = node.xpath('./member')
    return members.map { |m| children(m) }.join('#text(", ")') if node['type'] == 'inline'
    columns = [node['columns'].to_i, 1].max
    rows = (members.size.to_f / columns).ceil
    cells = []
    members.each_with_index do |member, i|
      x, y = node['type'] == 'horiz' ? [i % columns, i / columns] : [i / rows, i % rows]
      cells << "table.cell(x: #{x}, y: #{y})[#{anchor(member)}#{children(member)}]"
    end
    "#cll-table(#{columns}, border: false, #{cells.join(',')})\n"
  end

  def render(node)
    if node.text? || node.type == Nokogiri::XML::Node::ENTITY_REF_NODE
      text = node.text.gsub(/\s+/, ' ')
      return text.empty? ? '' : "#text(#{q(text)})"
    end
    return '' unless node.element?
    return '' if node.name == 'guibutton' || node['role'] == 'display-none'
    @stats[node.name] += 1
    body = case node.name
    when 'book' then children(node, except: ['info'])
    when 'chapter', 'article', 'appendix', 'section'
      title = node.at_xpath('title')
      level = node.name == 'section' ? node.ancestors.count { |a| a.name == 'section' } + 2 : 1
      marks = anchor(node) + (title ? title.xpath('.//anchor | .//indexterm').map { |n| render(n) }.join : '')
      clean_title = title&.dup
      clean_title&.xpath('.//anchor | .//indexterm')&.remove
      number = @numbers[node.path]
      prefix = node.name == 'chapter' ? "Chapter #{number}" : (node.name == 'section' ? number : '')
      "#cll-heading(#{level}, #{q(prefix)}, #{q(plain(title))}, marks: [#{marks}])[#{clean_title ? children(clean_title) : ''}]\n#{children(node, except: ['title'])}"
    when 'para', 'simpara'
      if node.ancestors.any? { |parent| %w[itemizedlist orderedlist].include?(parent.name) }
        trim_list_paragraph_edge(node)
        trim_list_paragraph_edge(node, trailing: true)
      end
      if %w[allowbreaks twocolumn].include?(node['role']) && plain(node).empty?
        ''
      else
        body = anchor(node) + styled(node, children(node))
        if node['role'] == 'status-note'
          "#cll-status[#{body}]\n"
        else
          indent = node.parent.name == 'section' && node['role'] != 'noindent' && node.previous_element&.name != 'title'
          "#cll-par(indent: #{indent})[#{body}]\n"
        end
      end
    when 'example'
      title = node.at_xpath('title')
      title_body = anchor(node) + (title ? children(title) : '')
      number = @numbers.fetch(node.path)
      allow_breaks = node['role'] == 'allowbreaks' || node.previous_element&.[]('role') == 'allowbreaks'
      "#cll-example(#{q(number)}, breakable: #{allow_breaks})[#{title_body}][#{children(node, except: ['title'])}]\n"
    when 'informaltable', 'table' then table(node)
    when 'foreignphrase', 'phrase' then styled(node, children(node))
    when 'emphasis' then node['role'] == 'bold' ? "#strong[#{children(node)}]" : "#emph[#{children(node)}]"
    when 'quote' then "#text(\"“\")#{children(node)}#text(\"”\")"
    when 'subscript' then "#sub[#{children(node)}]"
    when 'superscript' then "#super[#{children(node)}]"
    when 'anchor' then ''
    when 'xref'
      caption = target_text(node['linkend'])
      @references.key?(node['linkend']) ? "#cll-ref(#{q(node['linkend'])}, #{q(caption)})" : "#text(#{q(caption)})"
    when 'link', 'ulink'
      href = node['href'] || node['url']
      dest = href ? q(href) : "label(#{q(node['linkend'])})"
      target_text(node['linkend']) unless href
      if href || @references.key?(node['linkend'])
        "#link(#{dest})[#{children(node)}]"
      else
        children(node)
      end
    when 'glossterm'
      if node['linkend'] && @references.key?(node['linkend'])
        "#link(label(#{q(node['linkend'])}))[#{children(node)}]"
      else
        children(node)
      end
    when 'indexterm'
      key = @indexes[node.path]
      key && !node.at_xpath('see') ? "#metadata(#{q(key)})<cll-index>" : ''
    when 'index'
      entries = @index_entries.select { |_, v| v[:type] == node['type'] }.sort_by do |_, v|
        v[:nodes].map { |n| (n['sortas'] || plain(n)).downcase }
      end
      previous = []
      items = entries.map do |key, entry|
        path = entry[:nodes].map { |n| plain(n) }
        # Print each parent once, including parents that have no page references.
        parents = path[0...-1].each_with_index.filter_map do |_, depth|
          next if previous[0..depth] == path[0..depth]
          "(depth: #{depth}, key: none, body: [#{children(entry[:nodes][depth])}], see: (), seealso: ())"
        end
        previous = path
        parents << "(depth: #{path.size - 1}, key: #{q(key)}, body: [#{children(entry[:nodes].last)}], see: #{tuple(entry[:see])}, seealso: #{tuple(entry[:seealso])})"
        parents
      end.flatten
      "#cll-heading(1, \"\", #{q(plain(node.at_xpath('title')))})[#{children(node.at_xpath('title'))}]\n#cll-index((#{items.join(",\n")}#{items.empty? ? '' : ','}))\n"
    when 'glossary'
      title = node.at_xpath('title')
      "#cll-heading(1, \"\", #{q(plain(title))})[#{children(title)}]\n#{node.xpath('./para').map { |p| render(p) }.join}#columns(2, gutter: 5mm)[#set text(size: 0.9em)\n#{children(node, except: ['title', 'para'])}]\n"
    when 'glossdiv'
      "#block(sticky: true, above: 5pt, below: 2pt)[#strong[#{children(node.at_xpath('title'))}]]#{children(node, except: ['title'])}"
    when 'glossentry'
      "#cll-gloss[#{anchor(node)}#{children(node.at_xpath('glossterm'))}][#{children(node.at_xpath('glossdef'))}]\n"
    when 'itemizedlist', 'orderedlist'
      items = node.xpath('./listitem').map { |li| content(anchor(li) + styled(li, children(li))) }
      kind = node.name == 'orderedlist' ? 'numbered' : (node['role'] == 'bullets' ? 'bullets' : 'plain')
      in_example = node.ancestors.any? { |parent| parent.name == 'example' }
      "#cll-list(kind: #{q(kind)}, in-example: #{in_example}, #{items.join(',')})\n"
    when 'simplelist' then simplelist(node)
    when 'variablelist' then children(node)
    when 'varlistentry'
      "#cll-gloss[#{node.xpath('./term').map { |n| children(n) }.join('#text(", ")')}][#{children(node.at_xpath('listitem'))}]\n"
    when 'blockquote' then "#block(inset: (left: 2em), above: 4.5pt, below: 4.5pt)[#{children(node)}]\n"
    when 'bridgehead'
      marks = anchor(node) + node.xpath('.//anchor | .//indexterm').map { |n| render(n) }.join
      clean = node.dup
      clean.xpath('.//anchor | .//indexterm').remove
      "#cll-heading(3, \"\", #{q(plain(node))}, marks: [#{marks}])[#{children(clean)}]\n"
    when 'citetitle' then "#emph[#{children(node)}]"
    when 'filename', 'literal', 'code' then "#text(font: \"DejaVu Sans Mono\")[#{children(node)}]"
    when 'literallayout', 'programlisting', 'screen' then "#raw(#{q(node.text)}, block: true)\n"
    when 'mediaobject', 'inlinemediaobject'
      image = node.at_xpath('imageobject/imagedata')
      raise "Missing image at line #{node.line}" unless image
      path = image['fileref']
      raise "Unsafe image path: #{path}" unless path && path.start_with?('assets/') && !path.split('/').include?('..')
      "#cll-image(#{q(path)}, #{q(plain(node.at_xpath('textobject')))})\n"
    when 'math' then "#math.equation(block: #{node['display'] == 'block'}, $#{math(node)}$)"
    when 'inlineequation', 'informalequation', 'mathphrase', 'glossdef', 'term', 'listitem', 'caption', 'title', 'member'
      children(node)
    when 'footnote' then "#footnote[#{children(node)}]"
    else raise "Unsupported DocBook element: #{node.name} at line #{node.line}"
    end
    # A two-column hint applies to the following table, as in the Prince CSS.
    if node.previous_element&.[]('role') == 'twocolumn'
      body = "#columns(2, gutter: 5mm)[#{body}]"
    end
    (%w[chapter article appendix section para simpara example glossentry bridgehead].include?(node.name) ? '' : anchor(node)) + body
  end

  def tuple(values)
    '(' + values.map { |v| q(v) }.join(',') + (values.empty? ? '' : ',') + ')'
  end

  def convert
    info = @document.at_xpath('/book/info')
    raise 'Missing book info' unless info
    title = plain(info.at_xpath('title'))
    author = info.xpath('author/personname/*').map { |n| plain(n) }.join(' ')
    credits = info.xpath('othercredit/orgname[not(@role="publication-notice")]').map { |n| plain(n) }
    notice = info.at_xpath('othercredit/orgname[@role="publication-notice"]')&.dup
    disclaimer = plain(notice&.at_xpath('phrase[@role="publication-disclaimer"]'))
    notice&.xpath('phrase[@role="publication-disclaimer"]')&.remove
    version = plain(info.at_xpath('releaseinfo/phrase[@role="release-version"]'))
    date = plain(info.at_xpath('releaseinfo/phrase[@role="release-date"]'))
    "// Generated from preprocessed DocBook. Do not edit.\n#import \"book.typ\": *\n" \
      "#show: cll-book.with(title: #{q(title)}, author: #{q(author)})\n" \
      "#cll-title(#{q(title)}, #{q(plain(info.at_xpath('subtitle')))}, #{q(author)}, #{tuple(credits)}, version: #{q(version)}, date: #{q(date)}, notice: #{q(plain(notice))}, disclaimer: #{q(disclaimer)})\n" \
      "#outline(title: [Table of Contents], depth: 2)\n" + render(@document.root)
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--allow-missing-references') { options[:allow_missing] = true }
  end.parse!
  abort 'Usage: docbook_to_typst.rb [--allow-missing-references] INPUT.xml OUTPUT.typ' unless ARGV.size == 2
  begin
    converter = DocBookTypst.new(ARGV[0], **options)
    result = converter.convert
    File.write(ARGV[1] + '.tmp', result)
    File.rename(ARGV[1] + '.tmp', ARGV[1])
    warn "Typst conversion: #{converter.stats.to_json}"
  rescue StandardError => e
    warn "Typst conversion failed: #{e.message}"
    exit 1
  end
end
