# frozen_string_literal: true

# Whitespace-safe layout for the book's XHTML pages (issue #207).
#
# The formatter only adds, removes, or reshapes whitespace text. A run may
# appear or disappear only at a free gap. Everywhere else an existing run
# becomes one space or one line break. pre, script, style, textarea,
# xml:space="preserve", MathML, other namespaces, and a block inside an
# inline element stay byte for byte.
#
# br.example-break and br.table-break are display:none in assets/css/master.css.
# A line break after one of them would show as a space, so whitespace that
# follows them stays one space. A normal br breaks the line only when
# whitespace already follows it.
#
# Block-level elements are assumed to be blocks on the page. See the note
# at the top of assets/css/master.css.

require 'nokogiri'

module HtmlFormat
  XHTML = 'http://www.w3.org/1999/xhtml'
  WS_CHAR = /[ \t\n\r\f]/
  WS_RUN = /[ \t\n\r\f]+/
  TEXT_ESCAPE = /[&<>]/
  ATTR_ESCAPE = /[&<"]/
  WIDTH = 100
  INDENT = 2
  SAVE = Nokogiri::XML::Node::SaveOptions::AS_XML

  BLOCK = %w[
    html head body address article aside blockquote caption col colgroup dd details dialog div dl dt
    fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr li main nav ol p pre
    section summary table tbody td tfoot th thead tr ul
  ].freeze

  ELEMENT_ONLY = %w[html head table thead tbody tfoot tr colgroup ul ol dl].freeze

  VERBATIM = %w[pre script style textarea].freeze

  VOID = %w[area base br col embed hr img input link meta param source track wbr].freeze

  HIDDEN_BR = %w[example-break table-break].freeze
  DOCUMENT_ROOTS = %w[html head body].freeze

  # Cached on the element. Repeated .name and .namespace calls allocate a
  # string every time, and the predicates run once per ancestor.
  F_HTML = 1
  F_BLOCK = 2
  F_VERBATIM = 4
  F_BR = 8
  F_ELEMENT_ONLY = 16
  F_VOID = 32
  F_HIDDEN_BR = 64

  module_function

  def info(node)
    return node.instance_variable_get(:@_hf) if node.instance_variable_defined?(:@_hf)

    bits = 0
    if node.element?
      namespace = node.namespace
      html = namespace.nil? || namespace.href == XHTML
      name = node.name
      if html
        bits |= F_HTML
        bits |= F_BLOCK if BLOCK.include?(name)
        bits |= F_VERBATIM if VERBATIM.include?(name)
        bits |= F_BR if name == 'br'
        bits |= F_ELEMENT_ONLY if ELEMENT_ONLY.include?(name)
        bits |= F_VOID if VOID.include?(name)
        if (bits & F_BR) != 0 && hidden_br_class?(node)
          bits |= F_HIDDEN_BR
        end
      elsif namespace && namespace.href != XHTML
        bits |= F_VERBATIM
      end
      bits |= F_VERBATIM if node['xml:space'] == 'preserve'
      node.instance_variable_set(:@_hn, name)
      node.instance_variable_set(:@_hp, namespace&.prefix)
    end
    node.instance_variable_set(:@_hf, bits)
    bits
  end

  def cached_name(node)
    info(node)
    node.instance_variable_get(:@_hn)
  end

  def hidden_br_class?(node)
    classes = node['class']
    return false unless classes
    classes.split(/[ \t\n\r\f]+/).any? { |item| HIDDEN_BR.include?(item) }
  end

  def format!(doc)
    ensure_content_type_meta!(doc)
    format_element(doc.root, 0)
    doc
  end

  def write(doc)
    text = doc.to_xml(save_with: SAVE)
    text.end_with?("\n") ? text : "#{text}\n"
  end

  def html?(node)
    (info(node) & F_HTML) != 0
  end

  def block?(node)
    (info(node) & F_BLOCK) != 0
  end

  def void?(node)
    (info(node) & F_VOID) != 0
  end

  def br?(node)
    (info(node) & F_BR) != 0
  end

  def hidden_br?(node)
    (info(node) & F_HIDDEN_BR) != 0
  end

  def verbatim?(node)
    (info(node) & F_VERBATIM) != 0
  end

  def element_only?(node)
    (info(node) & F_ELEMENT_ONLY) != 0
  end

  # F1 applies only when the container has no text other than whitespace.
  def structural?(node)
    element_only?(node) && node.children.all? { |child| !child.text? || blank?(child) }
  end

  def blank?(node)
    node.text? && node.content.match?(/\A[ \t\n\r\f]*\z/)
  end

  def inline_parent?(node)
    html?(node) && !block?(node) && !verbatim?(node)
  end

  # libxml2 writes a Content-Type meta while saving an XHTML document, and it
  # does not put that tag in the tree. Add the same element first so a second
  # format pass sees the same head the first pass wrote.
  def ensure_content_type_meta!(doc)
    subset = doc.internal_subset
    return unless subset && subset.external_id.to_s.include?('XHTML')
    head = doc.root&.element_children&.find { |child| child.name == 'head' && html?(child) }
    return unless head
    return if head.element_children.any? { |child| content_type_meta?(child) }

    meta = Nokogiri::XML::Node.new('meta', doc)
    meta.namespace = head.namespace if head.namespace
    meta['http-equiv'] = 'Content-Type'
    meta['content'] = 'text/html; charset=UTF-8'
    if (first = head.children.first)
      first.add_previous_sibling(meta)
    else
      head.add_child(meta)
    end
  end

  def content_type_meta?(node)
    node.name == 'meta' && node['http-equiv'].to_s.casecmp('content-type').zero?
  end

  def format_element(element, depth)
    return unless element&.element?
    return if verbatim?(element)
    return if block?(element) && inline_ancestor?(element)

    if html?(element) && element.name == 'head'
      layout_children(element, depth, recurse: false)
      return
    end
    return if element.children.empty?

    if whitespace_only?(element) && !structural?(element)
      keep_one_space(element)
      return
    end
    if one_line?(element, depth)
      flatten(element)
      return
    end
    if structural?(element)
      layout_children(element, depth, recurse: true)
      return
    end
    layout_mixed(element, depth)
  end

  def inline_ancestor?(element)
    parent = element.parent
    parent&.element? && inline_parent?(parent)
  end

  def whitespace_only?(element)
    kids = element.children
    !kids.empty? && kids.all? { |child| child.text? && blank?(child) }
  end

  def keep_one_space(element)
    element.children.each(&:unlink)
    element.add_child(Nokogiri::XML::Text.new(' ', element.document))
  end

  def one_line?(element, depth)
    return false if DOCUMENT_ROOTS.include?(cached_name(element))
    return false unless shallow?(element)
    return false if nonfree_edge_whitespace?(element)
    return false if forced_break?(element)
    length = flat_length(element)
    return false if length.nil?
    length <= WIDTH - INDENT * depth
  end

  def shallow?(element)
    element.element_children.none? do |child|
      block?(child) && child.element_children.any? { |grand| block?(grand) }
    end
  end

  # A normal br that already has whitespace after it must break the line,
  # so the element cannot stay on one line. A hidden br must not break.
  def forced_break?(element)
    found = false
    walk = lambda do |node, verbatim|
      return if found
      node.children.each do |child|
        break if found
        next unless child.element?
        if verbatim || verbatim?(child) || (block?(child) && inline_parent?(node))
          next
        end
        if br?(child) && !hidden_br?(child) && whitespace_follows?(child)
          found = true
          break
        end
        walk.call(child, false)
      end
    end
    walk.call(element, false)
    found
  end

  def whitespace_follows?(node)
    nxt = node.next_sibling
    nxt&.text? && nxt.content.match?(WS_CHAR)
  end

  def nonfree_edge_whitespace?(element)
    kids = element.children.to_a
    return false if kids.empty?
    first = kids.first
    if first.text? && first.content.match?(/\A[ \t\n\r\f]/) && !free_before?(element, kids, 0)
      return true
    end
    last = kids.last
    if last.text? && last.content.match?(/[ \t\n\r\f]\z/) && !free_after?(element, kids, kids.length - 1)
      return true
    end
    false
  end

  def significant(kids, index, step)
    cursor = index + step
    while cursor >= 0 && cursor < kids.length
      child = kids[cursor]
      return child unless child.text? && blank?(child)
      cursor += step
    end
    nil
  end

  def free_before?(parent, kids, index)
    prev = significant(kids, index, -1)
    return false if prev && br?(prev)
    return true if structural?(parent)
    prev && block?(prev)
  end

  def free_after?(parent, kids, index)
    return false if br?(kids[index])
    nxt = significant(kids, index, 1)
    return true if structural?(parent)
    nxt && block?(nxt)
  end

  def blank_gap_free?(parent, kids, index)
    prev = significant(kids, index, -1)
    return false if prev && br?(prev)
    return true if structural?(parent)
    nxt = significant(kids, index, 1)
    (prev && block?(prev)) || (nxt && block?(nxt))
  end

  def flat_length(element)
    return serialized_length(element) if verbatim?(element) || (block?(element) && inline_ancestor?(element))
    return nil if verbatim?(element) && serialized_text(element).include?("\n")
    length = open_length(element)
    kids = element.children.to_a
    kids.each_with_index do |child, index|
      if child.text? || child.cdata?
        piece = collapsed_text(parent: element, kids: kids, index: index, node: child)
        return nil if piece.nil?
        length += piece
      elsif child.comment? || child.processing_instruction?
        length += serialized_length(child)
      elsif child.element?
        if verbatim?(child) || (block?(child) && inline_parent?(element))
          return nil if serialized_text(child).include?("\n")
          length += serialized_length(child)
        elsif child.children.empty?
          length += empty_length(child)
        else
          inner = flat_length(child)
          return nil if inner.nil?
          length += inner
        end
      end
    end
    length + close_length(element)
  end

  def collapsed_text(parent:, kids:, index:, node:)
    raw = node.content
    return 0 if raw.empty?
    if node.cdata?
      return nil if raw.include?("\n")
      return serialized_length(node)
    end
    if blank?(node)
      return 0 if blank_gap_free?(parent, kids, index)
      return 1
    end
    collapsed_length(raw, free_before?(parent, kids, index), free_after?(parent, kids, index))
  end

  # Length after a whitespace run becomes one space, an optional edge space
  # is dropped, and XML text escapes are counted. The same rules as
  # rewrite_flat_text. Scanning avoids copying the text for every ancestor.
  def collapsed_length(raw, drop_lead, drop_trail)
    length = 0
    extra = 0
    pending = false
    started = false
    raw.each_codepoint do |cp|
      if ws_codepoint?(cp)
        pending = true if started || !drop_lead
        next
      end
      if pending
        length += 1
        pending = false
      end
      started = true
      extra += escape_extra(cp, quote: false)
      length += 1
    end
    length += 1 if pending && !drop_trail
    length + extra
  end

  def ws_codepoint?(cp)
    cp == 32 || cp == 9 || cp == 10 || cp == 13 || cp == 12
  end

  # Extra characters the writer adds. &amp; is +4, &lt; and &gt; are +3,
  # and &quot; in an attribute is +5. Text does not escape a quote, and an
  # attribute does not escape >.
  def escape_extra(cp, quote:)
    case cp
    when 38 then 4
    when 60 then 3
    when 62 then quote ? 0 : 3
    when 34 then quote ? 5 : 0
    else 0
    end
  end

  def flatten(element)
    return if verbatim?(element) || (block?(element) && inline_ancestor?(element))
    kids = element.children.to_a
    kids.each_with_index do |child, index|
      if child.text?
        rewrite_flat_text(element, kids, index, child)
      elsif child.element? && !verbatim?(child) && !(block?(child) && inline_parent?(element))
        flatten(child)
      end
    end
  end

  def rewrite_flat_text(parent, kids, index, node)
    return if node.cdata?
    raw = node.content
    if blank?(node)
      if blank_gap_free?(parent, kids, index)
        node.unlink
      else
        node.content = ' '
      end
      return
    end
    text = raw.gsub(WS_RUN, ' ')
    text = text.sub(/\A /, '') if free_before?(parent, kids, index)
    text = text.sub(/ \z/, '') if free_after?(parent, kids, index)
    if text.empty?
      node.unlink
    else
      node.content = text
    end
  end

  def layout_children(element, depth, recurse:)
    element.children.to_a.each { |child| child.unlink if child.text? && blank?(child) }
    kids = element.children.to_a
    return if kids.empty?
    kids.each do |child|
      separate_before(child, depth + 1)
      format_element(child, depth + 1) if recurse && child.element?
    end
    ensure_text_before_end(element, depth)
  end

  def layout_mixed(element, depth)
    runs = []
    element.children.to_a.each do |child|
      if block?(child)
        runs << [:block, [child]]
      elsif runs.last && runs.last[0] == :inline
        runs.last[1] << child
      else
        runs << [:inline, [child]]
      end
    end
    runs.each_with_index do |(kind, nodes), index|
      if kind == :block
        place_block(nodes[0], element, depth, index == runs.length - 1)
      else
        place_inline(element, nodes, depth, index, index == runs.length - 1)
      end
    end
  end

  def place_block(child, parent, depth, last)
    separate_before(child, depth + 1)
    format_element(child, depth + 1)
    ensure_text_before_end(parent, depth) if last
  end

  def place_inline(parent, nodes, depth, index, last)
    lead_free = index.positive? || structural?(parent)
    trail_free = !last || structural?(parent)
    lead = edge_whitespace?(nodes, :lead)
    trail = edge_whitespace?(nodes, :trail)
    content = strip_edges(nodes)
    if content.empty?
      if !lead_free && !trail_free && parent.children.empty?
        parent.add_child(Nokogiri::XML::Text.new(' ', parent.document))
      end
      ensure_text_before_end(parent, depth) if last && (lead_free || trail) && parent.element_children.any?
      return
    end
    if lead_free || lead
      separate_before(content[0], depth + 1)
      start_col = INDENT * (depth + 1)
    else
      start_col = INDENT * depth + open_length(parent)
    end
    wrap(content, depth + 1, start_col)
    ensure_text_before_end(parent, depth) if last && (trail_free || trail)
  end

  def edge_whitespace?(nodes, side)
    node = side == :lead ? nodes.first : nodes.last
    return false unless node&.text?
    side == :lead ? node.content.match?(/\A[ \t\n\r\f]/) : node.content.match?(/[ \t\n\r\f]\z/)
  end

  # Drop edge whitespace from the list that wrap() sees. Whitespace that
  # already follows a br stays in the tree: that gap is not free, and a
  # hidden br must not gain a line break.
  def strip_edges(nodes)
    nodes = nodes.dup
    while nodes[0] && blank?(nodes[0])
      nodes.shift.unlink
    end
    while nodes[-1] && blank?(nodes[-1])
      if nodes.length >= 2 && br?(nodes[-2])
        nodes.pop
        break
      end
      nodes.pop.unlink
    end
    return nodes if nodes.empty?
    if nodes[0].text? && !nodes[0].cdata?
      nodes[0].content = nodes[0].content.sub(/\A[ \t\n\r\f]+/, '')
      nodes.shift.unlink if nodes[0].content.empty?
    end
    return nodes if nodes.empty?
    if nodes[-1].text? && !nodes[-1].cdata?
      stripped = nodes[-1].content.sub(/[ \t\n\r\f]+\z/, '')
      if !stripped.empty?
        nodes[-1].content = stripped
      elsif nodes.length >= 2 && br?(nodes[-2])
        nodes[-1].content = ' '
        nodes.pop
      else
        nodes.pop.unlink
      end
    end
    nodes
  end

  # A block starts on its own line. The gap after a br is not free: reshape
  # whitespace that is already there, and do not create any. A hidden br
  # keeps a space, because a line break after it would show on the page.
  def separate_before(node, depth)
    prev = previous_significant(node)
    if prev && br?(prev)
      gap = node.previous_sibling
      if gap&.text? && blank?(gap) && !gap.content.empty?
        gap.content = hidden_br?(prev) ? ' ' : "\n" + ' ' * (INDENT * depth)
      end
      return
    end
    replace_gap(node, "\n" + ' ' * (INDENT * depth))
  end

  def previous_significant(node)
    prev = node.previous_sibling
    while prev&.text? && blank?(prev)
      prev = prev.previous_sibling
    end
    prev
  end

  def replace_gap(node, text)
    prev = node.previous_sibling
    if prev&.text? && blank?(prev)
      prev.content = text
    else
      node.add_previous_sibling(Nokogiri::XML::Text.new(text, node.document))
    end
  end

  def ensure_text_before_end(element, depth)
    text = "\n" + ' ' * (INDENT * depth)
    last = element.children.last
    if last&.text? && blank?(last)
      prev = previous_significant(last)
      if prev && hidden_br?(prev)
        last.content = ' ' unless last.content.empty?
        return
      end
      last.content = text
    else
      element.add_child(Nokogiri::XML::Text.new(text, element.document))
    end
  end

  def wrap(nodes, depth, start_col)
    items = []
    nodes.each { |node| collect(node, items) }
    assign_breaks(items, depth, start_col)
    apply_breaks(items, depth)
  end

  def collect(node, items)
    if node.text? && !node.cdata?
      parts = node.content.split(/([ \t\n\r\f]+)/, -1)
      node.instance_variable_set(:@html_format_parts, parts)
      parts.each_with_index do |part, index|
        if index.odd?
          items << { kind: :ws, node: node, index: index }
        elsif !part.empty?
          items << { kind: :atom, length: text_length(part) }
        end
      end
    elsif node.cdata? || node.comment? || node.processing_instruction?
      items << { kind: :atom, length: serialized_length(node) }
    elsif node.element?
      if verbatim?(node) || block?(node)
        items << { kind: :atom, length: serialized_length(node) }
      elsif node.children.empty?
        items << { kind: :atom, length: empty_length(node) }
        items << { kind: :br, hidden: hidden_br?(node) } if br?(node)
      else
        items << { kind: :atom, length: open_length(node) }
        node.children.each { |child| collect(child, items) }
        items << { kind: :atom, length: close_length(node) }
      end
    end
  end

  def assign_breaks(items, depth, start_col)
    indent_col = INDENT * depth
    column = start_col
    chunk = 0
    pending = nil
    br_state = nil

    decide = lambda do |next_chunk|
      if column + 1 + next_chunk > WIDTH && column > indent_col
        pending[:decision] = :break
        column = indent_col + next_chunk
      else
        pending[:decision] = :space
        column += 1 + next_chunk
      end
      pending = nil
    end

    items.each do |item|
      case item[:kind]
      when :atom
        chunk += item[:length]
        br_state = nil
      when :br
        if pending
          decide.call(chunk)
        else
          column += chunk
        end
        chunk = 0
        br_state = item[:hidden] ? :hidden : :break
      when :ws
        if br_state == :break
          br_state = nil
          column += chunk
          chunk = 0
          pending = nil
          item[:decision] = :break
          column = indent_col
        elsif br_state == :hidden
          br_state = nil
          item[:decision] = :space
          chunk += 1
        else
          if pending
            decide.call(chunk)
          else
            column += chunk
          end
          chunk = 0
          pending = item
        end
      end
    end
    if pending
      decide.call(chunk)
    end
  end

  def apply_breaks(items, depth)
    indent = "\n" + ' ' * (INDENT * depth)
    by_node = {}
    items.each do |item|
      next unless item[:kind] == :ws
      (by_node[item[:node]] ||= []) << item
    end
    by_node.each do |node, breaks|
      parts = node.instance_variable_get(:@html_format_parts)
      breaks.each do |item|
        parts[item[:index]] = item[:decision] == :break ? indent : ' '
      end
      node.content = parts.join
      node.remove_instance_variable(:@html_format_parts)
    end
  end

  def qualified_name(element)
    info(element)
    prefix = element.instance_variable_get(:@_hp)
    name = element.instance_variable_get(:@_hn)
    prefix && !prefix.empty? ? "#{prefix}:#{name}" : name
  end

  def escaped_attr_length(value)
    value = value.to_s
    return value.length unless value.match?(ATTR_ESCAPE)
    extra = 0
    value.each_codepoint { |cp| extra += escape_extra(cp, quote: true) }
    value.length + extra
  end

  def text_length(text)
    text = text.to_s
    return text.length unless text.match?(TEXT_ESCAPE)
    extra = 0
    text.each_codepoint { |cp| extra += escape_extra(cp, quote: false) }
    text.length + extra
  end

  def open_length(element)
    length = 1 + qualified_name(element).length
    element.namespace_definitions.each do |ns|
      href_length = escaped_attr_length(ns.href)
      if ns.prefix.nil? || ns.prefix.empty?
        length += 9 + href_length
      else
        length += 10 + ns.prefix.length + href_length
      end
    end
    element.attribute_nodes.each do |attr|
      prefix = attr.namespace&.prefix
      name = prefix && !prefix.empty? ? "#{prefix}:#{attr.name}" : attr.name
      length += 1 + name.length + 2 + escaped_attr_length(attr.value) + 1
    end
    length + 1
  end

  def close_length(element)
    qualified_name(element).length + 3
  end

  def empty_length(element)
    void?(element) ? open_length(element) + 2 : open_length(element) + close_length(element)
  end

  def serialized_length(node)
    node.to_xml(save_with: SAVE).length
  end

  def serialized_text(node)
    node.to_xml(save_with: SAVE)
  end
end
