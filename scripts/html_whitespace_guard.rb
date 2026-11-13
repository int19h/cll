# frozen_string_literal: true

# Compare two XHTML texts and refuse an unsafe whitespace change (issue #207).
#
# The guard parses each text on its own. It does not call the formatter.
# A whitespace run may appear or disappear only at a free gap. Inside a
# verbatim element the text must match byte for byte. The gap after a br
# is never free. The comparison covers the raw XML declaration, the doctype
# and the text of its internal subset, the order of comments and processing
# instructions around the doctype, and comments, processing instructions,
# and entity references in the document. An undefined entity in an attribute
# is dropped by the parser; those "Entity ... not defined" warnings are
# compared in order, without the line numbers.
#
# Usage: ruby scripts/html_whitespace_guard.rb [--strict] BEFORE AFTER
# BEFORE and AFTER are files, or directories of .html files with the same names.

require 'nokogiri'
require_relative 'html_inline_neighbors'

module HtmlWhitespaceGuard
  class Unsafe < StandardError
  end

  XHTML = 'http://www.w3.org/1999/xhtml'
  XMLNS = 'http://www.w3.org/2000/xmlns/'
  WS_RUN = /[ \t\n\r\f]+/
  # One object for every ordinary whitespace run. Nothing mutates a token.
  WS_TOKEN = [:ws].freeze
  WSP_SPACE = [:wsp, ' '].freeze
  WSP_BREAK = [:wsp, "\n"].freeze
  ZWSP = HtmlInlineNeighbors::ZWSP
  WIDE_RANGES = HtmlInlineNeighbors::WIDE_RANGES

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
      href = href_of(namespace)
      html = namespace.nil? || href == XHTML
      name = node.name
      if html
        bits |= G_HTML
        bits |= G_BLOCK if BLOCK.include?(name)
        bits |= G_VERBATIM if VERBATIM.include?(name) || guibutton?(node)
        bits |= G_BR if name == 'br'
      elsif href && href != XHTML
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
    left = parse_side(before, name, 'before')
    right = parse_side(after, name, 'after')
    problems = differences(left, right, strict: strict)
    return if problems.empty?

    shown = problems.first(10)
    lines = ["#{name}: #{problems.length} unsafe whitespace changes"]
    shown.each { |problem| lines << "  #{problem}" }
    raise Unsafe, lines.join("\n")
  end

  def parse_side(text, name, side)
    parse_tokens(text)
  rescue Unsafe => error
    raise Unsafe, "#{name}: #{side}: #{error.message}"
  end

  def parse_tokens(text)
    doc = Nokogiri::XML(text) { |config| config.strict.nonet }
    raise Unsafe, 'not well-formed XML' unless doc.root

    tokens = []
    walk_document(doc, tokens)
    [doc, tokens, raw_declaration(text)]
  rescue Nokogiri::XML::SyntaxError => error
    raise Unsafe, "not well-formed XML: #{error.message.strip}"
  end

  # The declaration is the raw text. Parsed version and encoding hide
  # standalone, a missing encoding, and quote or space differences.
  def raw_declaration(text)
    source = text.delete_prefix("\uFEFF")
    match = source.match(/\A<\?xml\b.*?\?>/m)
    match && match[0]
  end

  def walk_document(doc, tokens)
    # carry[0] is the previous non-whitespace character in the open inline
    # run. A block or a br clears it. queue holds text that still needs the
    # next character, plus tokens that follow that text, so the walk does
    # not search the tree for each node.
    carry = [nil]
    queue = []
    doc.children.each do |child|
      next if child.is_a?(Nokogiri::XML::DTD)
      next if child.text? && child.content.match?(/\A[ \t\n\r\f]*\z/)

      take_node(child, tokens, false, false, carry, queue)
    end
    flush_queue(queue, tokens, nil)
  end

  def walk(element, tokens, verbatim, inline_ancestor, carry, queue)
    inside_inline = inline_ancestor || inline?(element)
    region = verbatim || verbatim?(element) || (block?(element) && inline_ancestor)
    # br is inline by name, but it ends the run the same way a block does.
    if br?(element) || !inline?(element)
      flush_queue(queue, tokens, nil)
      carry[0] = nil
      carry = [nil]
      queue = []
    end

    put_token(queue, tokens, start_token(element, region))
    element.children.each do |child|
      take_node(child, tokens, region, inside_inline, carry, queue)
    end
    # A block's own tail has no next character. An inline tail may.
    flush_queue(queue, tokens, nil) if br?(element) || !inline?(element)
    put_token(
      queue, tokens,
      [:end, cached_name(element), element_kind(element), nil, region, href_of(element.namespace)]
    )
  end

  def take_node(node, tokens, region, inline_ancestor, carry, queue)
    if node.element?
      child_region = region || verbatim?(node) || (block?(node) && inline_ancestor)
      walk(node, tokens, child_region, inline_ancestor, carry, queue)
    elsif node.text? || node.cdata?
      take_text(node, tokens, region, node.cdata?, carry, queue)
    elsif node.is_a?(Nokogiri::XML::EntityReference)
      take_entity(node, tokens, carry, queue)
    elsif node.comment?
      put_token(queue, tokens, [:comment, node.content])
    elsif node.processing_instruction?
      put_token(queue, tokens, [:pi, node.name, node.content])
    end
  end

  def take_text(node, tokens, region, cdata, carry, queue)
    raw = node.content
    return if raw.empty?
    if region
      put_token(queue, tokens, [:vtext, raw])
      return
    end

    first = HtmlInlineNeighbors.first_non_ws(raw)
    if cdata
      flush_queue(queue, tokens, first) if first
      put_token(queue, tokens, [:vtext, raw])
      last = HtmlInlineNeighbors.last_non_ws(raw)
      carry[0] = last if last
      return
    end

    # A blank node has no character, so the run stays open through it.
    if first.nil?
      queue << [:blank, raw, carry[0]]
      return
    end

    flush_queue(queue, tokens, first)
    left = carry[0]
    if HtmlInlineNeighbors.boundary_ws?(raw, :last)
      queue << [:text, raw, left]
    else
      emit_text(tokens, raw, left, nil)
    end
    last = HtmlInlineNeighbors.last_non_ws(raw)
    carry[0] = last if last
  end

  # The reference contributes its replacement characters to the run and
  # keeps its own token. An undefined reference has no characters.
  def take_entity(node, tokens, carry, queue)
    raw = node.content.to_s
    first = raw.empty? ? nil : HtmlInlineNeighbors.first_non_ws(raw)
    flush_queue(queue, tokens, first) if first
    put_token(queue, tokens, [:entity, node.name])
    return if raw.empty?

    last = HtmlInlineNeighbors.last_non_ws(raw)
    carry[0] = last if last
  end

  def put_token(queue, tokens, token)
    if queue.empty?
      tokens << token
    else
      queue << [:ready, token]
    end
  end

  def flush_queue(queue, tokens, right)
    return if queue.empty?

    queue.each do |item|
      case item[0]
      when :text
        emit_text(tokens, item[1], item[2], right)
      when :blank
        append_ws_run(tokens, item[1], item[2], right)
      else
        tokens << item[1]
      end
    end
    queue.clear
  end

  # [:start, name, kind, attrs, region, uri, decls, container_free]
  # container_free is only for gap checks. content_tokens drops it.
  def start_token(element, region)
    [
      :start, cached_name(element), element_kind(element), attributes(element), region,
      href_of(element.namespace), namespace_decls(element), container_free?(element)
    ]
  end

  def emit_text(tokens, raw, left_char, right_char)
    if raw.match?(/\A[ \t\n\r\f]*\z/)
      append_ws_run(tokens, raw, left_char, right_char)
      return
    end
    # An ASCII run is protected only when a neighbor is U+200B. Splitting
    # it would copy every word on the page for a case this node cannot hit.
    if plain_ascii?(raw, left_char, right_char)
      emit_collapsed(tokens, raw)
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
        tokens << (newline_run?(part) ? WSP_BREAK : WSP_SPACE)
      elsif char_after_run(parts, index).nil?
        pending_trail = true
      elsif buffer.empty?
        pending_lead = part
      else
        buffer << ' '
      end
    end

    flush.call
    tokens << WS_TOKEN if pending_trail
  end

  # No protected run. One space and one line break are the same token.
  def plain_ascii?(raw, left_char, right_char)
    return false unless raw.ascii_only?
    return false if HtmlInlineNeighbors.boundary_ws?(raw, :first) && left_char == ZWSP
    return false if HtmlInlineNeighbors.boundary_ws?(raw, :last) && right_char == ZWSP

    true
  end

  def emit_collapsed(tokens, raw)
    lead = HtmlInlineNeighbors.boundary_ws?(raw, :first)
    trail = HtmlInlineNeighbors.boundary_ws?(raw, :last)
    if !lead && !trail
      tokens << [:text, raw.match?(WS_RUN) ? raw.gsub(WS_RUN, ' ') : raw]
      return
    end

    tokens << WS_TOKEN if lead
    core = raw.gsub(WS_RUN, ' ').strip
    tokens << [:text, core] unless core.empty?
    tokens << WS_TOKEN if trail
  end

  # A protected run records space and newline as different tokens, so a
  # segment break cannot replace the space. Other runs stay presence-only.
  # The run after a br stays presence-only: a normal br may still break.
  def append_ws_run(tokens, run, left_char, right_char)
    if protect_run?(left_char, right_char)
      tokens << (newline_run?(run) ? WSP_BREAK : WSP_SPACE)
    else
      tokens << WS_TOKEN
    end
  end

  def protect_run?(left_char, right_char)
    HtmlInlineNeighbors.protect_run?(left_char, right_char)
  end

  def wide_char?(char)
    HtmlInlineNeighbors.wide_char?(char)
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

  # Nokogiri returns a new frozen String for every href, and String#-@
  # then returns that same object. A page repeats a few URIs on every
  # element, so the tokens share one copy.
  def shared_string(text)
    return nil if text.nil?

    (@shared ||= {})[text] ||= text
  end

  # One Ruby object stands for a namespace, while href allocates every call.
  def href_of(namespace)
    return nil unless namespace
    return namespace.instance_variable_get(:@_href) if namespace.instance_variable_defined?(:@_href)

    value = shared_string(namespace.href)
    namespace.instance_variable_set(:@_href, value)
    value
  end

  def attributes(element)
    element.attribute_nodes.map { |attr|
      href = href_of(attr.namespace)
      next if href == XMLNS
      [href, attr.name, attr.value]
    }.compact
  end

  def namespace_decls(element)
    element.namespace_definitions.map { |ns|
      [shared_string(ns.prefix), href_of(ns)]
    }
  end

  def differences(left, right, strict:)
    left_doc, left_tokens, left_decl = left
    right_doc, right_tokens, right_decl = right
    problems = []
    unless left_decl == right_decl
      problems << 'CHANGED xml declaration'
    end
    unless doctype(left_doc) == doctype(right_doc)
      problems << 'CHANGED doctype'
    end
    unless prolog_marks(left_doc) == prolog_marks(right_doc)
      problems << 'CHANGED prolog'
    end
    unless entity_warnings(left_doc) == entity_warnings(right_doc)
      problems << 'CHANGED entity reference'
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

  def doctype(doc)
    subset = doc.internal_subset
    return nil unless subset

    # to_s includes notations, which are absent from children, but drops a
    # comment-only subset. The child list keeps that comment.
    [
      subset.name, subset.external_id, subset.system_id, subset.to_s,
      subset.children.map { |node| subset_decl(node) }
    ]
  end

  def subset_decl(node)
    if node.is_a?(Nokogiri::XML::EntityDecl)
      [:entity, node.name, node.content, node.external_id, node.system_id, node.entity_type]
    else
      [:decl, node.to_s]
    end
  end

  # Comments and processing instructions before the root, with the doctype
  # between them. The content walk skips the doctype, so this is what keeps
  # a comment from moving across it unnoticed.
  def prolog_marks(doc)
    marks = []
    doc.children.each do |child|
      break if child.element?

      if child.is_a?(Nokogiri::XML::DTD)
        marks << :doctype
      elsif child.comment?
        marks << [:comment, child.content]
      elsif child.processing_instruction?
        marks << [:pi, child.name, child.content]
      end
    end
    marks
  end

  # Line and column numbers change when the formatter wraps a line, so only
  # the warning text is compared, in document order.
  def entity_warnings(doc)
    doc.errors.filter_map { |error|
      text = error.to_s.strip.sub(/\A\d+:\d+:\s*/, '')
      text if text.match?(/Entity '.+' not defined/)
    }
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
