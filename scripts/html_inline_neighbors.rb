# frozen_string_literal: true

# Shared by the HTML formatter and the whitespace guard (issue #207).
# One wide-character list and one inline-neighbor search, so the two agree.
#
# A whitespace run is protected when either side is U+200B, even when the
# other side is unknown. A visible verbatim inline element, such as MathML
# or a span with xml:space="preserve", contributes its first or last
# character. When it has none, that side is unknown, and an unknown side
# beside a wide character protects the run. An element the stylesheet hides
# (display-none, guibutton, a hidden br, script, style) is skipped.
# A visible br is a line boundary. External DTD entities contribute no
# character: the formatter loads the DTD and the guard does not, and neither
# uses that expansion for a neighbor.
#
# A head without a Content-Type meta element is formatted again on a second
# pass. The pages of this book include that element.

module HtmlInlineNeighbors
  ZWSP = "\u200B"
  # No character could be read from a visible inline element. This is not
  # the same as a block or a visible br, which end the line.
  UNKNOWN = :unknown

  HIDDEN_CLASS = %w[display-none guibutton].freeze
  HIDDEN_BR = %w[example-break table-break].freeze
  PREDEFINED_ENTITIES = %w[amp lt gt apos quot].freeze

  # East Asian wide and fullwidth characters. A space between two of these,
  # or beside U+200B, is not a line break: a segment break would be removed.
  WIDE_RANGES = [
    0x1100..0x115F,
    0x2E80..0x9FFF,
    0xA000..0xA4CF,
    0xAC00..0xD7AF,
    0xF900..0xFAFF,
    0xFE10..0xFE19,
    0xFE30..0xFE4F,
    0xFE50..0xFE6F,
    0xFF01..0xFF60,
    0xFF61..0xFF9F,
    0xFFE0..0xFFE6,
    0xFFE8..0xFFEE,
    0x16FE0..0x18D08,
    0x1AFF0..0x1AFFF,
    0x1B000..0x1B12F,
    0x20000..0x3FFFD
  ].freeze

  module_function

  def wide_char?(char)
    return false unless char.is_a?(String) && !char.empty?

    cp = char.ord
    WIDE_RANGES.any? { |range| range.cover?(cp) }
  end

  # Unknown means a visible inline element yielded no character. Nil means
  # a real line boundary or the end of the run. U+200B protects either way.
  def protect_run?(before_char, after_char)
    return true if before_char == ZWSP || after_char == ZWSP

    left_unknown = before_char == UNKNOWN
    right_unknown = after_char == UNKNOWN
    return true if left_unknown && (right_unknown || wide_char?(after_char))
    return true if right_unknown && wide_char?(before_char)
    return false if before_char.nil? || after_char.nil? || left_unknown || right_unknown

    wide_char?(before_char) && wide_char?(after_char)
  end

  # The character on the before or after side of node.
  # Walk siblings, descend into inline elements, and when the siblings run
  # out climb to an inline parent. A block or a visible br ends the run.
  # rules responds to block?, br?, inline?, and verbatim?.
  def neighbor_char(node, direction, rules)
    before = direction == :before
    side = before ? :last : :first
    current = node
    while current
      sib = before ? current.previous_sibling : current.next_sibling
      while sib
        found = edge_of(sib, side, rules)
        return nil if found == :boundary
        return UNKNOWN if found == UNKNOWN
        return found if found

        sib = before ? sib.previous_sibling : sib.next_sibling
      end
      parent = current.parent
      break unless parent&.element? && rules.inline?(parent)
      break if hidden_element?(parent)

      current = parent
    end
    nil
  end

  # nil: nothing here, keep looking. :boundary: a real line end.
  # UNKNOWN: a visible element with no character. A string is the character.
  def edge_of(node, side, rules)
    unless node.element?
      return nil if node.comment? || node.processing_instruction?

      text = text_of(node)
      return nil if text.nil? || text.empty?

      return side == :last ? last_non_ws(text) : first_non_ws(text)
    end

    return :boundary if rules.block?(node)
    return nil if hidden_element?(node)
    return :boundary if rules.br?(node)

    if rules.verbatim?(node) || rules.inline?(node)
      found = read_edge(node, side, rules)
      return found if found
      return UNKNOWN if rules.verbatim?(node)

      return nil
    end
    :boundary
  end

  # First or last visible character inside node, or nil when it has none.
  # An empty visible verbatim descendant is unknown: do not read past it.
  def read_edge(node, side, rules)
    children = node.children
    seq = side == :last ? children.reverse_each : children.each
    seq.each do |child|
      found = read_child(child, side, rules)
      return found if found
    end
    nil
  end

  def read_child(child, side, rules)
    if child.element?
      return nil if hidden_element?(child)
      return :boundary if rules.block?(child) || rules.br?(child)
      if rules.verbatim?(child)
        found = read_edge(child, side, rules)
        return found if found

        return UNKNOWN
      end
      return read_edge(child, side, rules)
    end

    text = text_of(child)
    return nil if text.nil? || text.empty?

    side == :last ? last_non_ws(text) : first_non_ws(text)
  end

  # display:none in assets/css/master.css, plus script and style, which
  # the browser does not render. A hidden br is display:none as well.
  def hidden_element?(node)
    return false unless node.element?

    name = node.name
    return true if name == 'script' || name == 'style'

    classes = node['class']
    return false unless classes

    tokens = classes.split(/[ \t\n\r\f]+/)
    return true if tokens.any? { |token| HIDDEN_CLASS.include?(token) }

    name == 'br' && tokens.any? { |token| HIDDEN_BR.include?(token) }
  end

  def text_of(node)
    if node.text? || node.cdata?
      node.content
    elsif node.is_a?(Nokogiri::XML::EntityReference)
      entity_text(node)
    end
  end

  # Predefined and internal-subset entities expand the same way with or
  # without the external DTD. An entity from that DTD, such as nbsp, does not.
  def entity_text(node)
    name = node.name
    return node.content.to_s if PREDEFINED_ENTITIES.include?(name)
    return node.content.to_s if internal_entity?(node)

    ''
  end

  def internal_entity?(node)
    internal_entity_names(node.document).include?(node.name)
  end

  def internal_entity_names(doc)
    return doc.instance_variable_get(:@_ient) if doc.instance_variable_defined?(:@_ient)

    names = {}
    subset = doc.internal_subset
    if subset
      subset.children.each do |decl|
        next unless decl.is_a?(Nokogiri::XML::EntityDecl)
        next if decl.entity_type == 4 || decl.entity_type == 5

        names[decl.name] = true
      end
    end
    doc.instance_variable_set(:@_ient, names)
    names
  end

  # Byte scan. each_char would allocate a string for every leading space,
  # and a formatted page is mostly those spaces.
  def first_non_ws(text)
    index = 0
    limit = text.bytesize
    while index < limit
      byte = text.getbyte(index)
      if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
        index += 1
        next
      end
      length = if byte < 0x80
                 1
               elsif byte < 0xE0
                 2
               elsif byte < 0xF0
                 3
               else
                 4
               end
      return text.byteslice(index, length)
    end
    nil
  end

  # Whitespace is ASCII, so scan bytes from the end and decode one character.
  # String#[] by index walks the whole UTF-8 string.
  def last_non_ws(text)
    index = text.bytesize - 1
    while index >= 0
      byte = text.getbyte(index)
      if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
        index -= 1
        next
      end
      start = index
      start -= 1 while start > 0 && (text.getbyte(start) & 0xC0) == 0x80
      return text.byteslice(start, index - start + 1)
    end
    nil
  end

  def ws_char?(char)
    char == ' ' || char == "\t" || char == "\n" || char == "\r" || char == "\f"
  end

  def boundary_ws?(text, side)
    return false if text.empty?

    byte = side == :first ? text.getbyte(0) : text.getbyte(text.bytesize - 1)
    byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
  end
end
