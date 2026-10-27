#!/usr/bin/env ruby
# Render the normalized DocBook vocabulary produced by xml_preprocess.rb.
require 'nokogiri'
require 'digest'
require 'json'

class ContextBook
  ESCAPES = {
    '\\' => '\\letterbackslash{}', '{' => '\\letterleftbrace{}',
    '}' => '\\letterrightbrace{}', '%' => '\\letterpercent{}',
    '#' => '\\letterhash{}', '$' => '\\letterdollar{}',
    '&' => '\\letterampersand{}', '_' => '\\letterunderscore{}',
    '^' => '\\letterhat{}', '~' => '\\lettertilde{}', '|' => '\\letterbar{}'
  }.freeze
  TRANSPARENT = %w[book info author personname firstname othername surname othercredit orgname
                   releaseinfo subtitle title caption term glossdef primary secondary tertiary
                   mathphrase inlineequation informalequation colgroup tbody thead imageobject].freeze
  attr_reader :report

  def initialize(document)
    @document = document
    @document.remove_namespaces!
    @ids = {}
    @labels = {}
    @numbers = {}
    @urls = {}
    @report = { 'elements' => Hash.new(0), 'missing_references' => [], 'images' => [], 'math' => 0 }
    document.xpath('//*').each do |node|
      @report['elements'][node.name] += 1
      id = node['id']
      next unless id
      raise "Duplicate ID: #{id}" if @ids.key?(id)
      @ids[id] = node
    end
    number_components
    @ids.each do |id, node|
      owner = node
      owner = owner.parent while owner.element? && !@labels.key?(owner.path) && owner.parent&.element?
      @labels[id] = @labels[owner.path] || plain(node)
    end
  end

  def self.escape(text)
    text.gsub(Regexp.union(ESCAPES.keys)) { |character| ESCAPES.fetch(character) }
  end

  def esc(text)
    self.class.escape(text.to_s)
  end

  def plain(node)
    return '' unless node
    node.xpath('.//text()[not(ancestor::indexterm)]').map(&:text).join.gsub(/\s+/, ' ').strip
  end

  def key(id)
    "cll-#{Digest::SHA256.hexdigest(id)[0, 24]}"
  end

  def number_components
    chapter_number = 0
    @document.root.element_children.each do |component|
      next unless %w[chapter article].include?(component.name)
      chapter_number += 1 if component.name == 'chapter'
      number = component.name == 'chapter' ? chapter_number.to_s : nil
      @numbers[component.path] = number
      @labels[component.path] = number ? "Chapter #{number}" : plain(component.at_xpath('./title'))
      sections(component, number)
      %w[example table].each do |kind|
        component.xpath(".//#{kind}").each_with_index do |node, index|
          n = [number, index + 1].compact.join('.')
          @numbers[node.path] = n
          @labels[node.path] = "#{kind.capitalize} #{n}"
        end
      end
    end
  end

  def sections(parent, prefix)
    parent.xpath('./section').each_with_index do |section, index|
      number = [prefix, index + 1].compact.join('.')
      @numbers[section.path] = number
      @labels[section.path] = "Section #{number}"
      sections(section, number)
    end
  end

  def anchor(node)
    id = node['id']
    id ? "\\reference[#{key(id)}]{#{esc(@labels[id])}}" : ''
  end

  def children(node, except: [], trim_leading: false)
    leading = trim_leading
    node.children.reject { |child| child.element? && except.include?(child.name) }.map do |child|
      part = render(child)
      if leading
        part = part.lstrip if child.text?
        invisible = child.element? && %w[indexterm anchor].include?(child.name)
        leading = false unless part.empty? || invisible
      end
      part
    end.join
  end

  def title(node)
    child = node.at_xpath('./title|./caption')
    child ? children(child) : ''
  end

  def reference(node, explicit = nil)
    id = node['linkend']
    label = explicit || esc(@labels[id] || id)
    unless @ids.key?(id)
      @report['missing_references'] << id unless @report['missing_references'].include?(id)
      return label
    end
    result = "\\goto{#{label}}[#{key(id)}]"
    result += " (p.~\\at[#{key(id)}])" if node.name == 'xref'
    result
  end

  def styled(node, text)
    role = node['role'].to_s
    language = node['lang']
    text = "{\\it #{text}}" if %w[jbo jbophrase pronunciation-jbo compound-cmavo-jbo].include?(role) || language == 'jbo'
    text = "{\\bf #{text}}" if %w[gloss selbri].include?(role)
    text = "{\\tt #{text}}" if role == 'X-SAMPA'
    text = "{\\CLLcrisa #{text}}" if language == 'zlm'
    text = "{\\CLLkorean #{text}}" if language == 'ko'
    text = "{\\CLLchinese #{text}}" if language == 'zh'
    text += '{\\high{◇}}' if role.split.include?('status-mark')
    text
  end

  def heading(node)
    kind = node.name == 'section' ? 'section' : 'chapter'
    if kind == 'section'
      depth = node.ancestors.count { |ancestor| ancestor.name == 'section' }
      kind = 'sub' * depth + 'section'
    end
    number = @numbers[node.path]
    text = title(node)
    text = "Chapter~#{number}\\crlf #{text}" if node.name == 'chapter'
    text = "#{number}\\quad #{text}" if node.name == 'section'
    # Title anchors belong on the heading's page, not in a moving title argument.
    clean_title = node.at_xpath('./title')&.dup
    if clean_title
      clean_title.xpath('.//anchor|.//indexterm').remove
      text = children(clean_title)
      text = "Chapter~#{number}\\crlf #{text}" if node.name == 'chapter'
      text = "#{number}\\quad #{text}" if node.name == 'section'
    end
    refs = [node['id'], *node.xpath('./title//anchor').map { |item| item['id'] }].compact.map { |id| key(id) }
    marks = node.xpath('./title//indexterm').map { |item| render(item) }.join
    "\n\\start#{kind}[title={#{text}},reference={#{refs.join(',')}},number=no]\n#{marks}\n" +
      children(node, except: ['title']) + "\n\\stop#{kind}\n"
  end

  def indexterm(node)
    register = { 'general' => 'CLLgeneral', 'lojban-word' => 'CLLlojban' }[node['type']]
    return '' unless register
    levels = node.xpath('./primary|./secondary|./tertiary')
    terms = levels.map do |term|
      # A literal plus must not become a register hierarchy separator.
      children(term).strip.gsub('+', '\\char43{}')
    end
    keys = levels.map do |term|
      # ConTeXt strips apostrophes before sorting. An escaped sentinel keeps
      # them distinct and before letters with the register's Unicode sorter.
      value = term.text.gsub(/\s+/, ' ').strip.downcase.gsub('!', '!!').gsub(/['’]/, '!a')
      esc(value).gsub('+', '\\char43{}')
    end
    "\\#{register}[{#{keys.join('+')}}]{#{terms.join('+')}}"
  end

  def math(node)
    return esc(node.text.gsub(/\s+/, ' ')) if node.text?
    return '' unless node.element?
    parts = node.element_children
    case node.name
    when 'math', 'mrow' then node.children.map { |child| math(child) }.join
    when 'mn', 'mi' then esc(node.text.strip)
    when 'mo'
      value = node.text.strip
      return '' if value == "\u2062"
      if (connective = value.match(/\A([,;:]?)\s*(iff|then)\z/i))
        punctuation, word = connective.captures
        # These words connect formulas. Keep punctuation on the preceding formula,
        # and use explicit math spacing because ordinary TeX spaces disappear.
        before = punctuation.empty? ? (node.previous_element ? '\\quad ' : '') : "#{esc(punctuation)}\\quad "
        return "#{before}\\mathupright{#{esc(word)}}\\quad "
      end
      return "\\mathtext{#{esc(value)}}" if value.match?(/[A-Za-z]/)
      esc(value)
    when 'mfrac'
      raise 'mfrac needs two operands' unless parts.length == 2
      "\\frac{#{math(parts[0])}}{#{math(parts[1])}}"
    when 'msup'
      raise 'msup needs two operands' unless parts.length == 2
      "{#{math(parts[0])}}^{#{math(parts[1])}}"
    when 'msqrt' then "\\sqrt{#{parts.map { |part| math(part) }.join}}"
    else raise "Unsupported MathML element: #{node.name}"
    end
  end

  def table(node, layout_node: node)
    nested = layout_node.ancestors.any? { |ancestor| %w[table informaltable].include?(ancestor.name) }
    table_command = nested ? 'TABLEnested' : 'TABLE'
    rows = node.xpath('./tr|./thead/tr|./tbody/tr')
    cols = rows.map { |row| row.element_children.sum { |cell| [cell['colspan'].to_i, 1].max } }.max || 1
    border = !node['class'].to_s.split.include?('noborder')
    margin = !nested && layout_node.ancestors.any? { |ancestor| ancestor.name == 'example' } ? '2em' : '0pt'
    output = "\n\\begingroup\n\\setupTABLE[frame=off,offset=0pt,loffset=0.4em,roffset=0.4em,align={flushleft,verytolerant},split=yes,textwidth=local,maxwidth={\\dimexpr(\\availablehsize-#{margin})/#{cols}\\relax},leftmargindistance=#{margin}]\n"
    output += "\\setupTABLE[c][each][rightframe=dash,dashstep=.5bp,rulethickness=0.35bp,framecolor=CLLrule]\n" if border
    output += "\\setupTABLE[c][#{cols}][rightframe=off]\n"
    if node.name == 'table'
      output += "\\blank[small]\\noindentation{\\bf Table~#{@numbers[node.path]} #{title(node)}}\\par\\nobreak\n"
    end
    output += "\\b#{table_command}[split=#{nested ? 'no' : 'yes'}]\n"
    rows.each do |row|
      output += "\\bTR\n"
      position = 0
      row.element_children.each do |cell|
        span = cell['colspan'] == '0' ? cols - position : [cell['colspan'].to_i, 1].max
        raise 'Invalid table span' if span < 1 || position + span > cols
        options = ["nc=#{span}", "nr=#{[cell['rowspan'].to_i, 1].max}"]
        options << 'rightframe=off' if position + span == cols
        content = children(cell)
        content = "{\\it #{content}}" if row['class'] == 'jbo'
        content = "{\\bf #{content}}" if row['class'] == 'gloss' || cell.name == 'th' || row.parent.name == 'thead'
        output += "\\bTD[#{options.join(',')}] #{anchor(cell)}#{content} \\eTD\n"
        position += span
      end
      output += "\\eTR\n"
    end
    output += "\\e#{table_command}\n\\endgroup\n\\blank[small]\n"
    nested ? "{#{output}}" : output
  end

  def simplelist(node)
    members = node.xpath('./member')
    return members.map { |item| children(item) }.join(', ') if node['type'] == 'inline'
    columns = Integer(node['columns'] || '1')
    raise 'A simplelist needs positive columns' unless columns.positive?
    count = (members.length.to_f / columns).ceil
    grid = Nokogiri::XML::Node.new('informaltable', @document)
    grid['class'] = 'noborder'
    count.times do |row_number|
      row = Nokogiri::XML::Node.new('tr', @document)
      columns.times do |column|
        index = node['type'] == 'horiz' ? row_number * columns + column : column * count + row_number
        cell = Nokogiri::XML::Node.new('td', @document)
        members[index]&.children&.each { |child| cell.add_child(child.dup) }
        row.add_child(cell)
      end
      grid.add_child(row)
    end
    table(grid, layout_node: node)
  end

  def render(node)
    return esc(node.text.gsub(/\s+/, ' ')) if node.text?
    return '' unless node.element?
    return '' if node['role'].to_s.split.include?('display-none')
    content = case node.name
    when 'chapter', 'article', 'section' then return heading(node)
    when 'anchor' then ''
    when 'indexterm' then indexterm(node)
    when 'para'
      in_list = node.ancestors.any? { |ancestor| ancestor.name == 'listitem' }
      body = styled(node, children(node, trim_leading: in_list))
      if node['role'] == 'status-note'
        "\n\\startCLLstatus ◇ #{body}\\stopCLLstatus\n"
      elsif node.ancestors.any? { |ancestor| %w[td th].include?(ancestor.name) }
        "#{body}\\par\n"
      else
        prefix = node['role'] == 'noindent' ? '\\noindentation ' : ''
        "\n#{prefix}#{body}\\par\n"
      end
    when 'example'
      # testpage keeps short examples together, while long ones remain breakable.
      "\n\\blank[small]\\testpage[5]\\startnarrower[left]\n" +
        "\\noindentation#{anchor(node)}{\\bf Example~#{@numbers[node.path]} #{title(node)}}\\par\\nobreak\n" +
        children(node, except: ['title']) + "\n\\stopnarrower\\blank[small]\n"
    when 'table', 'informaltable' then table(node)
    when 'quote' then "“#{children(node)}”"
    when 'emphasis' then "{\\#{node['role'] == 'bold' ? 'bf' : 'it'} #{children(node)}}"
    when 'foreignphrase', 'phrase' then styled(node, children(node))
    when 'subscript' then "\\low{#{children(node)}}"
    when 'superscript' then "\\high{#{children(node)}}"
    when 'xref' then reference(node)
    when 'glossterm'
      node['linkend'] ? reference(node, children(node)) : children(node)
    when 'link'
      if node['linkend']
        reference(node, children(node))
      else
        url = node['href']
        raise 'Link without href or linkend' unless url
        name = key(url)
        @urls[name] = url
        "\\goto{#{children(node)}}[url(#{name})]"
      end
    when 'math'
      @report['math'] += 1
      "\\mathematics{#{math(node)}}"
    when 'itemizedlist', 'orderedlist'
      option = node.name == 'orderedlist' ? 'n' : (node['role'] == 'bullets' ? '1' : 'none')
      layout = if node.name == 'orderedlist'
                 'CLLordered'
               else
                 node['role'] == 'bullets' ? 'CLLbulleted' : 'CLLunmarked'
               end
      "\n\\start#{layout}[#{option},packed]\n#{children(node)}\n\\stop#{layout}\n"
    when 'listitem' then "\\startitem #{children(node).strip}\\stopitem\n"
    when 'simplelist' then simplelist(node)
    when 'member' then children(node)
    when 'variablelist' then children(node)
    when 'varlistentry'
      terms = node.xpath('./term').map { |term| children(term) }.join(', ')
      body = node.xpath('./listitem').map { |item| children(item) }.join
      "\n\\noindentation{\\bf #{terms}}\\par\\startnarrower[left]#{body}\\stopnarrower\n"
    when 'blockquote' then "\n\\startnarrower[left]#{children(node)}\\stopnarrower\n"
    when 'bridgehead' then "\n\\subsubject[title={#{children(node)}}]\n"
    when 'glossary'
      "\n\\startchapter[title={#{title(node)}},number=no]\n" +
        node.xpath('./para').map { |item| render(item) }.join +
        "\n\\startcolumns[n=2,balance=yes]\\switchtobodyfont[8.1bp]\\setupinterlinespace[line=9.72bp]\\setupwhitespace[none]\\setupindenting[no]\\setupalign[normal,verytolerant,extremestretch]\\setbreakpoints[compound]\n" +
        children(node, except: %w[title para]) + "\n\\stopcolumns\\stopchapter\n"
    when 'glossdiv'
      "\n\\blank[small]\\testpage[4]\\noindentation{\\bf #{title(node)}}\\par\\nobreak\n#{children(node, except: ['title'])}"
    when 'glossentry'
      "\n\\noindentation#{anchor(node)}{\\bf #{children(node.at_xpath('./glossterm'))}}\\par\\nobreak\n" +
        children(node, except: ['glossterm'])
    when 'glossdef'
      "\\startnarrower[left]#{children(node)}\\stopnarrower\n"
    when 'index'
      register = { 'general' => 'CLLgeneral', 'lojban-word' => 'CLLlojban' }.fetch(node['type'])
      "\n\\startchapter[title={#{title(node)}},number=no]\n\\begingroup\\switchtobodyfont[8.1bp]\\setupinterlinespace[line=9.72bp]\\placeregister[#{register}][n=2,balance=yes]\\endgroup\\stopchapter\n"
    when 'mediaobject', 'inlinemediaobject'
      image = node.at_xpath('.//imagedata')
      raise 'Media object without an image' unless image
      path = image['fileref']
      raise "Unsafe image path: #{path}" unless path&.match?(%r{\Aassets/media/[A-Za-z0-9_. /-]+\z}) && !path.split('/').include?('..')
      @report['images'] << path unless @report['images'].include?(path)
      path += '.png' if File.extname(path).downcase == '.gif'
      "\n\\par\\midaligned{#{anchor(node)}\\externalfigure[#{path}][maxwidth=.9\\textwidth,maxheight=150bp]}\\par\n"
    when 'guibutton', 'textobject' then ''
    when 'literallayout'
      "\n\\startlines\n#{node.text.lines.map { |line| esc(line.rstrip) }.join("\n")}\n\\stoplines\n"
    when 'filename' then "{\\tt #{children(node)}}"
    when 'citetitle' then "{\\it #{children(node)}}"
    else
      raise "Unsupported DocBook element #{node.name} at #{node.path}" unless TRANSPARENT.include?(node.name)
      children(node)
    end
    (%w[example glossentry mediaobject inlinemediaobject].include?(node.name) ? '' : anchor(node)) + content
  end

  def to_tex
    info = @document.root.at_xpath('./info')
    book_title = plain(info&.at_xpath('./title'))
    body = children(@document.root, except: ['info'])
    credit = info ? info.xpath('./othercredit[not(orgname[@role="publication-notice"])]').map { |node| "#{esc(plain(node))}\\par" }.join("\n") : ''
    notice = info&.at_xpath('./othercredit/orgname[@role="publication-notice"]')
    notice_text = notice ? notice.children.map do |child|
      child.element? && child['role'] == 'publication-disclaimer' ? "\\crlf #{children(child)}" : render(child)
    end.join.strip : ''
    version = plain(info&.at_xpath('./releaseinfo/phrase[@role="release-version"]'))
    date = plain(info&.at_xpath('./releaseinfo/phrase[@role="release-date"]'))
    author = info ? info.xpath('./author/personname/*').map { |node| plain(node) }.join(' ') : ''
    subtitle = plain(info&.at_xpath('./subtitle'))
    urls = @urls.map { |name, url| "\\useURL[#{name}][{#{esc(url)}}][][]" }.join("\n")
    <<~TEX
      % Generated by docbook_to_context.rb. Do not edit.
      \\environment cll-layout
      \\setupinteraction[title={#{esc(book_title)}},author={#{esc(author)}},color=black,contrastcolor=black]
      \\def\\CLLBookTitle{#{esc(book_title)}}
      #{urls}
      \\starttext
      \\begingroup
      \\setupfooter[style={\\switchtobodyfont[8bp]},color=CLLmuted]
      \\setupfootertexts[{#{esc(version)}}][{#{esc(date)}}]
      \\startstandardmakeup[footerstate=start]
      \\vfill
      {\\switchtobodyfont[52bp]\\setupalign[middle]#{esc(book_title)}\\par}
      \\blank[2cm]
      {\\switchtobodyfont[16bp]\\setupalign[middle]#{esc(author)}\\par}
      \\blank[big]
      \\startalignment[middle]
      #{esc(subtitle)}\\par
      #{credit}
      {\\switchtobodyfont[12bp]\\tf #{notice_text}\\par}
      \\stopalignment
      \\vfill
      \\stopstandardmakeup
      \\endgroup
      \\starttitle[title={Contents}]
      \\placecontent[criterium=all]
      \\stoptitle
      #{body}
      \\stoptext
    TEX
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: docbook_to_context.rb INPUT.xml OUTPUT.tex REPORT.json' unless ARGV.length == 3
  begin
    document = Nokogiri::XML(File.open(ARGV[0])) { |config| config.strict.dtdload.noent.nonet }
    book = ContextBook.new(document)
    output = book.to_tex
    File.write(ARGV[1], output)
    File.write(ARGV[2], JSON.pretty_generate(book.report) + "\n")
    warn "ConTeXt: #{book.report['missing_references'].length} references outside the input" unless book.report['missing_references'].empty?
  rescue StandardError => error
    abort "ConTeXt conversion failed: #{error.message}"
  end
end
