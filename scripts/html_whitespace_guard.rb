# frozen_string_literal: true

# Compare two XHTML texts and refuse an unsafe whitespace change (issue #207).
#
# The guard parses each text on its own. It does not call the formatter.
# A whitespace run may appear or disappear only at a free gap. Inside a
# verbatim element the text must match byte for byte. The gap after a br
# is never free. The comparison covers the XML declaration, the doctype
# and its internal subset, and comments, processing instructions, and
# entity references anywhere in the document.
#
# Usage: ruby scripts/html_whitespace_guard.rb [--strict] BEFORE AFTER
# BEFORE and AFTER are files, or directories of .html files with the same names.

require 'nokogiri'

module HtmlWhitespaceGuard
  class Unsafe < StandardError
  end

  XHTML = 'http://www.w3.org/1999/xhtml'
  XMLNS = 'http://www.w3.org/2000/xmlns/'
  WS_RUN = /[ \t\n\r\f]+/
  ZWSP = "\u200B"

  # East Asian wide and fullwidth characters. A space between two of these,
  # or beside U+200B, is not a line break: a segment break would be removed
  # and the space would disappear. Keep the same ranges in html_format.rb.
  WIDE_RANGES = [
    0x1100..0x115F,
    0x2E80..0x9FFF,
    0xAC00..0xD7AF,
    0xF900..0xFAFF,
    0xFE30..0xFE4F,
    0xFF01..0xFF60,
    0xFFE0..0xFFE6,
    0x20000..0x3FFFD
  ].freeze

  # These lists match scripts/html_format.rb. The guard keeps its own copy.
  BLOCK = %w[
    html head body address article aside blockquote caption col colgroup dd details dialog div dl dt
    fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr li main nav ol p pre
    section summary table tbody td tfoot th thead tr ul
  ].freeze

  ELEMENT_ONLY = %w[html head table thead tbody tfoot tr colgroup ul ol dl].freeze

  VERBATIM = %w[pre script style textarea].freeze

  # One namespace lookup per element. html? and the other predicates run
  # several times on each node, and each lookup allocates.
  G_HTML = 1
  G_BLOCK = 2
  G_VERBATIM = 4
  G_BR = 8

  module_function

  def ginfo(node)
    return node.instance_variable_get(:@_wg) if node.instance_variable_defined?(:@_wg)

    bits = 0
    if node.element?
      namespace = node.namespace
      html = namespace.nil? || namespace.href == XHTML
      name = node.name
      if html
        bits |= G_HTML
        bits |= G_BLOCK if BLOCK.include?(name)
        bits |= G_VERBATIM if VERBATIM.include?(name) || guibutton?(node)
        bits |= G_BR if name == 'br'
      elsif namespace && namespace.href != XHTML
        bits |= G_VERBATIM
      end
      bits |= G_VERBATIM if node['xml:space'] == 'preserve'
      node.instance_variable_set(:@_wn, name)
    end
    node.instance_variable_set(:@_wg, bits)
    bits
  end

  def cached_name(node)
    ginfo(node)
    node.instance_variable_get(:@_wn)
  end

  # sance-next.js reads .guibutton with innerText while it is hidden.
  # The class is one token, so "not-guibutton" does not match.
  def guibutton?(node)
    classes = node['class']
    return false unless classes
    classes.split(/[ \t\n\r\f]+/).include?('guibutton')
  end

  def compare!(before, after, name:, strict: false)
    left = parse_tokens(before)
    right = parse_tokens(after)
    problems = differences(left, right, strict: strict)
    return if problems.empty?

    shown = problems.first(10)
    lines = ["#{name}: #{problems.length} unsafe whitespace changes"]
    shown.each { |problem| lines << "  #{problem}" }
    raise Unsafe, lines.join("\n")
  end

  def parse_tokens(text)
    doc = Nokogiri::XML(text) { |config| config.strict.nonet }
    raise Unsafe, 'not well-formed XML' unless doc.root

    tokens = []
    walk_document(doc, tokens)
    [doc, tokens]
  rescue Nokogiri::XML::SyntaxError => error
    raise Unsafe, "not well-formed XML: #{error.message.strip}"
  end

  def walk_document(doc, tokens)
    doc.children.each do |child|
      next if child.is_a?(Nokogiri::XML::DTD)
      if child.element?
        walk(child, tokens, false, false)
      elsif child.text? || child.cdata?
        next if child.text? && child.content.match?(/\A[ \t\n\r\f]*\z/)
        append_text(tokens, child, child.cdata?, nil, nil)
      elsif child.comment?
        tokens << [:comment, child.content]
      elsif child.processing_instruction?
        tokens << [:pi, child.name, child.content]
      elsif child.is_a?(Nokogiri::XML::EntityReference)
        tokens << [:entity, child.name]
      end
    end
  end

  def walk(element, tokens, verbatim, inline_ancestor)
    inside_inline = inline_ancestor || inline?(element)
    region = verbatim || verbatim?(element) || (block?(element) && inline_ancestor)
    tokens << start_token(element, region)
    kids = element.children
    kids.each_with_index do |child, index|
      if child.element?
        child_region = region || verbatim?(child) || (block?(child) && inside_inline)
        walk(child, tokens, child_region, inside_inline)
      elsif child.text? || child.cdata?
        if region || child.cdata?
          append_text(tokens, child, true, nil, nil)
        else
          left, right = neighbor_chars(kids, index)
          append_text(tokens, child, false, left, right)
        end
      elsif child.is_a?(Nokogiri::XML::EntityReference)
        tokens << [:entity, child.name]
      elsif child.comment?
        tokens << [:comment, child.content]
      elsif child.processing_instruction?
        tokens << [:pi, child.name, child.content]
      end
    end
    tokens << [:end, cached_name(element), element_kind(element), nil, region, element.namespace&.href]
  end

  # [:start, name, kind, attrs, region, uri, decls, container_free]
  # container_free is only for gap checks. content_tokens drops it.
  def start_token(element, region)
    [
      :start, cached_name(element), element_kind(element), attributes(element), region,
      element.namespace&.href, namespace_decls(element), container_free?(element)
    ]
  end

  def append_text(tokens, node, verbatim, left_char, right_char)
    raw = node.content
    return if raw.empty?
    if verbatim
      tokens << [:vtext, raw]
      return
    end
    if raw.match?(/\A[ \t\n\r\f]*\z/)
      append_ws_run(tokens, raw, left_char, right_char)
      return
    end

    parts = raw.split(/([ \t\n\r\f]+)/, -1)
    buffer = +''
    pending_lead = nil
    pending_trail = false

    flush = lambda do
      return if buffer.empty?
      tokens << [:text, buffer]
      buffer = +''
    end

    parts.each_with_index do |part, index|
      if index.even?
        next if part.empty?
        if pending_lead
          append_ws_run(tokens, pending_lead, left_char, part[0])
          pending_lead = nil
        end
        buffer << part
      elsif protect_run?(char_before_run(parts, index) || left_char, char_after_run(parts, index) || right_char)
        if pending_lead
          append_ws_run(tokens, pending_lead, left_char, char_before_run(parts, index))
          pending_lead = nil
        end
        flush.call
        tokens << [:wsp, newline_run?(part) ? "\n" : ' ']
      elsif char_after_run(parts, index).nil?
        pending_trail = true
      elsif buffer.empty?
        pending_lead = part
      else
        buffer << ' '
      end
    end

    flush.call
    tokens << [:ws] if pending_trail
  end

  # A protected run records space and newline as different tokens, so a
  # segment break cannot replace the space. Other runs stay presence-only.
  # The run after a br stays presence-only: a normal br may still break.
  def append_ws_run(tokens, run, left_char, right_char)
    if protect_run?(left_char, right_char)
      tokens << [:wsp, newline_run?(run) ? "\n" : ' ']
    else
      tokens << [:ws]
    end
  end

  def protect_run?(left_char, right_char)
    return false if left_char.nil? || right_char.nil?
    return true if left_char == ZWSP || right_char == ZWSP
    wide_char?(left_char) && wide_char?(right_char)
  end

  def wide_char?(char)
    cp = char.ord
    WIDE_RANGES.any? { |range| range.cover?(cp) }
  end

  def newline_run?(run)
    run.include?("\n") || run.include?("\r")
  end

  def char_before_run(parts, index)
    text = parts[index - 1]
    return nil if text.nil? || text.empty?
    text[-1]
  end

  def char_after_run(parts, index)
    text = parts[index + 1]
    return nil if text.nil? || text.empty?
    text[0]
  end

  # The character on each side of a text node, skipping blank text.
  # A block sibling is not an inline neighbor: the gap between blocks is free.
  def neighbor_chars(kids, index)
    [neighbor_char(kids, index, -1), neighbor_char(kids, index, 1)]
  end

  def neighbor_char(kids, index, step)
    cursor = index + step
    while cursor >= 0 && cursor < kids.length
      child = kids[cursor]
      if child.element?
        return nil if block?(child) || br?(child)
        char = element_edge_char(child, step.negative? ? :last : :first)
        return char if char
      elsif child.text? || child.cdata?
        text = child.content.gsub(WS_RUN, '')
        return (step.negative? ? text[-1] : text[0]) unless text.empty?
      elsif child.is_a?(Nokogiri::XML::EntityReference)
        text = child.content.to_s.gsub(WS_RUN, '')
        return (step.negative? ? text[-1] : text[0]) unless text.empty?
      end
      cursor += step
    end
    nil
  end

  def element_edge_char(node, side)
    seq = side == :last ? node.children.reverse_each : node.children.each
    seq.each do |child|
      if child.text? || child.cdata?
        text = child.content.gsub(WS_RUN, '')
        return (side == :last ? text[-1] : text[0]) unless text.empty?
      elsif child.element?
        next if block?(child)
        char = element_edge_char(child, side)
        return char if char
      elsif child.is_a?(Nokogiri::XML::EntityReference)
        text = child.content.to_s.gsub(WS_RUN, '')
        return (side == :last ? text[-1] : text[0]) unless text.empty?
      end
    end
    nil
  end

  def html?(node)
    (ginfo(node) & G_HTML) != 0
  end

  def block?(node)
    (ginfo(node) & G_BLOCK) != 0
  end

  def verbatim?(node)
    (ginfo(node) & G_VERBATIM) != 0
  end

  def br?(node)
    (ginfo(node) & G_BR) != 0
  end

  def inline?(node)
    html?(node) && !block?(node) && !verbatim?(node)
  end

  def element_kind(element)
    bits = ginfo(element)
    return :br if (bits & G_BR) != 0
    return :block if (bits & G_BLOCK) != 0
    :inline
  end

  # html and head are always element-only. ul, ol, dl, and the table
  # containers are element-only only when every significant child is a block.
  def container_free?(element)
    name = cached_name(element)
    return true if name == 'html' || name == 'head'
    return false unless ELEMENT_ONLY.include?(name)
    element.children.all? { |child| container_child?(child) }
  end

  def container_child?(child)
    return child.content.match?(/\A[ \t\n\r\f]*\z/) if child.text?
    return true if child.comment? || child.processing_instruction?
    child.element? && block?(child)
  end

  def attributes(element)
    element.attribute_nodes.map { |attr|
      href = attr.namespace&.href
      next if href == XMLNS
      [href, attr.name, attr.value]
    }.compact
  end

  def namespace_decls(element)
    element.namespace_definitions.map { |ns| [ns.prefix, ns.href] }
  end

  def differences(left, right, strict:)
    left_doc, left_tokens = left
    right_doc, right_tokens = right
    problems = []
    unless xml_declaration(left_doc) == xml_declaration(right_doc)
      problems << 'CHANGED xml declaration'
    end
    unless doctype(left_doc) == doctype(right_doc)
      problems << 'CHANGED doctype'
    end
    left_content = content_tokens(left_tokens)
    right_content = content_tokens(right_tokens)
    if left_content == right_content
      problems.concat(gap_problems(left_tokens, right_tokens, strict: strict))
    else
      problems.concat(content_problems(left_content, right_content))
    end
    problems
  end

  def xml_declaration(doc)
    [doc.version, doc.encoding]
  end

  def doctype(doc)
    subset = doc.internal_subset
    return nil unless subset
    [subset.name, subset.external_id, subset.system_id, subset.children.map { |node| subset_decl(node) }]
  end

  def subset_decl(node)
    if node.is_a?(Nokogiri::XML::EntityDecl)
      [:entity, node.name, node.content, node.external_id, node.system_id]
    else
      [:decl, node.to_s]
    end
  end

  # Drop presence-only whitespace. A protected run (:wsp) stays, because a
  # space and a line break are different there. Also drop the container flag.
  def content_tokens(tokens)
    tokens.reject { |token| token[0] == :ws }.map { |token|
      token[0] == :start ? token[0, 7] : token
    }
  end

  def content_problems(left, right)
    limit = [left.length, right.length].min
    index = (0...limit).find { |cursor| left[cursor] != right[cursor] } || limit
    before = index.positive? ? label(left[index - 1]) : 'the start'
    left_here = left[index]
    right_here = right[index]
    after = label(left[index + 1] || right[index + 1])
    if left_here.nil? || right_here.nil?
      ["CHANGED between #{before} and the end"]
    elsif %i[text vtext entity wsp].include?(left_here[0]) || %i[text vtext entity wsp].include?(right_here[0])
      ["CHANGED between #{before} and #{after}: #{label(left_here)} / #{label(right_here)}"]
    elsif left_here[0] == :start && right_here[0] == :start && left_here[1] == right_here[1]
      if left_here[5] != right_here[5] || left_here[6] != right_here[6]
        ["CHANGED namespace of #{label(left_here)} between #{before} and #{after}"]
      else
        ["CHANGED attributes of #{label(left_here)} between #{before} and #{after}"]
      end
    else
      ["CHANGED between #{before} and #{label(left_here)}"]
    end
  end

  def gap_problems(left_tokens, right_tokens, strict:)
    left_gaps = gaps(left_tokens)
    right_gaps = gaps(right_tokens)
    problems = []
    left_gaps.each_with_index do |gap, index|
      other = right_gaps[index]
      next unless other
      next if gap[2] == other[2]
      next if !strict && free_gap?(gap)
      verb = other[2] ? 'ADDED  ' : 'REMOVED'
      problems << "#{verb} between #{label(gap[0])} and #{label(gap[1])}"
    end
    problems
  end

  # Each gap is [left, right, ws, parent, verbatim].
  def gaps(tokens)
    found = []
    stack = []
    previous = nil
    pending_ws = false
    verbatim_depth = 0
    tokens.each do |token|
      if token[0] == :ws
        pending_ws = true
        next
      end
      if previous
        found << [previous, token, pending_ws, stack.last, verbatim_depth.positive?]
      end
      pending_ws = false
      previous = token
      if token[0] == :start
        verbatim_depth += 1 if token[4]
        stack << token
      elsif token[0] == :end
        frame = stack.pop
        verbatim_depth -= 1 if frame && frame[4]
      end
    end
    found
  end

  def free_gap?(gap)
    return false if gap[4]
    left = gap[0]
    right = gap[1]
    return false if br_edge?(left)
    parent = gap[3]
    return true if parent && parent[7]
    return true if left[0] == :end && left[2] == :block
    return true if right[0] == :start && right[2] == :block
    false
  end

  def br_edge?(token)
    token && token[0] == :end && token[1] == 'br'
  end

  def label(token)
    return 'the end' unless token
    case token[0]
    when :start
      extra = attribute_label(token[3])
      "<#{token[1]}#{extra}>"
    when :end
      "</#{token[1]}>"
    when :text, :vtext
      text = token[1].to_s.gsub(WS_RUN, ' ')
      text = "#{text[0, 40]}..." if text.length > 40
      "\"#{text}\""
    when :wsp
      token[1] == "\n" ? 'a line break' : 'a space'
    when :comment
      'a comment'
    when :pi
      "<?#{token[1]}>"
    when :entity
      "&#{token[1]};"
    else
      token[0].to_s
    end
  end

  def attribute_label(attrs)
    return '' unless attrs
    chosen = attrs.find { |_uri, name, _value| name == 'class' } ||
             attrs.find { |_uri, name, _value| name == 'id' }
    return '' unless chosen
    %( #{chosen[1]}="#{chosen[2]}")
  end
end

if $PROGRAM_NAME == __FILE__
  strict = ARGV.delete('--strict')
  if ARGV.length != 2
    warn 'Usage: html_whitespace_guard.rb [--strict] BEFORE AFTER'
    exit 2
  end

  def compare_paths(before, after, strict)
    HtmlWhitespaceGuard.compare!(File.read(before), File.read(after), name: after, strict: strict)
    true
  rescue HtmlWhitespaceGuard::Unsafe => error
    warn error.message
    false
  end

  before_path, after_path = ARGV
  ok = true
  if File.directory?(before_path) || File.directory?(after_path)
    unless File.directory?(before_path) && File.directory?(after_path)
      warn 'BEFORE and AFTER must both be files or both be directories'
      exit 1
    end
    names = Dir.children(before_path).select { |name| name.end_with?('.html') }.sort
    after_names = Dir.children(after_path).select { |name| name.end_with?('.html') }.sort
    (names | after_names).sort.each do |name|
      left = File.join(before_path, name)
      right = File.join(after_path, name)
      unless File.file?(left) && File.file?(right)
        warn "MISSING #{File.file?(left) ? right : left}"
        ok = false
        next
      end
      ok = false unless compare_paths(left, right, strict)
    end
  else
    ok = compare_paths(before_path, after_path, strict)
  end
  exit(ok ? 0 : 1)
end
