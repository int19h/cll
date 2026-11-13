# frozen_string_literal: true

# Compare two XHTML texts and refuse an unsafe whitespace change (issue #207).
#
# The guard parses each text on its own. It does not call the formatter.
# A whitespace run may appear or disappear only at a free gap. Inside a
# verbatim element the text must match byte for byte. The gap after a br
# is never free.
#
# Usage: ruby scripts/html_whitespace_guard.rb [--strict] BEFORE AFTER
# BEFORE and AFTER are files, or directories of .html files with the same names.

require 'nokogiri'

module HtmlWhitespaceGuard
  class Unsafe < StandardError
  end

  XHTML = 'http://www.w3.org/1999/xhtml'
  WS_RUN = /[ \t\n\r\f]+/

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
        bits |= G_VERBATIM if VERBATIM.include?(name)
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
    walk(doc.root, tokens, false, false)
    [doc, tokens]
  rescue Nokogiri::XML::SyntaxError => error
    raise Unsafe, "not well-formed XML: #{error.message.strip}"
  end

  def walk(element, tokens, verbatim, inline_ancestor)
    inside_inline = inline_ancestor || inline?(element)
    region = verbatim || verbatim?(element) || (block?(element) && inline_ancestor)
    tokens << [:start, cached_name(element), element_kind(element), attributes(element), region]
    element.children.each do |child|
      if child.element?
        child_region = region || verbatim?(child) || (block?(child) && inside_inline)
        walk(child, tokens, child_region, inside_inline)
      elsif child.text? || child.cdata?
        append_text(tokens, child, region || child.cdata?)
      elsif child.comment?
        tokens << [:comment, child.content]
      elsif child.processing_instruction?
        tokens << [:pi, child.name, child.content]
      end
    end
    tokens << [:end, cached_name(element), element_kind(element), nil, region]
  end

  def append_text(tokens, node, verbatim)
    raw = node.content
    return if raw.empty?
    if verbatim
      tokens << [:vtext, raw]
      return
    end
    if raw.match?(/\A[ \t\n\r\f]*\z/)
      tokens << [:ws]
      return
    end
    tokens << [:ws] if raw.match?(/\A[ \t\n\r\f]/)
    core = raw.gsub(WS_RUN, ' ').strip
    tokens << [:text, core] unless core.empty?
    tokens << [:ws] if raw.match?(/[ \t\n\r\f]\z/)
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

  def inline?(node)
    html?(node) && !block?(node) && !verbatim?(node)
  end

  def element_kind(element)
    bits = ginfo(element)
    return :br if (bits & G_BR) != 0
    return :block if (bits & G_BLOCK) != 0
    :inline
  end

  def attributes(element)
    element.attribute_nodes.map do |attr|
      prefix = attr.namespace&.prefix
      name = prefix && !prefix.empty? ? "#{prefix}:#{attr.name}" : attr.name
      [name, attr.value]
    end
  end

  def differences(left, right, strict:)
    left_doc, left_tokens = left
    right_doc, right_tokens = right
    problems = []
    unless doctype(left_doc) == doctype(right_doc)
      problems << 'CHANGED doctype'
    end
    left_content = content_tokens(left_tokens)
    right_content = content_tokens(right_tokens)
    unless left_content == right_content
      problems.concat(content_problems(left_content, right_content))
      return problems
    end
    gap_problems(left_tokens, right_tokens, strict: strict)
  end

  def doctype(doc)
    subset = doc.internal_subset
    [subset&.name, subset&.external_id, subset&.system_id]
  end

  # append_text already collapses each text run, so this only drops
  # whitespace tokens.
  def content_tokens(tokens)
    tokens.reject { |token| token[0] == :ws }
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
    elsif %i[text vtext].include?(left_here[0]) || %i[text vtext].include?(right_here[0])
      ["CHANGED between #{before} and #{after}: #{label(left_here)} / #{label(right_here)}"]
    elsif left_here[0] == :start && right_here[0] == :start && left_here[1] == right_here[1]
      ["CHANGED attributes of #{label(left_here)} between #{before} and #{after}"]
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
    return true if parent && ELEMENT_ONLY.include?(parent[1])
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
    when :comment
      'a comment'
    when :pi
      "<?#{token[1]}>"
    else
      token[0].to_s
    end
  end

  def attribute_label(attrs)
    return '' unless attrs
    chosen = attrs.find { |name, _| name == 'class' } || attrs.find { |name, _| name == 'id' }
    return '' unless chosen
    %( #{chosen[0]}="#{chosen[1]}")
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
