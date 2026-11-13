# frozen_string_literal: true

# Shared by the HTML formatter and the whitespace guard (issue #207).
# One wide-character list and one inline-neighbor search, so the two agree,
# including on entity references.

module HtmlInlineNeighbors
  ZWSP = "\u200B"

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
    return false if char.nil?

    cp = char.ord
    WIDE_RANGES.any? { |range| range.cover?(cp) }
  end

  def protect_run?(before_char, after_char)
    return false if before_char.nil? || after_char.nil?
    return true if before_char == ZWSP || after_char == ZWSP

    wide_char?(before_char) && wide_char?(after_char)
  end

  # The character on the before or after side of node.
  # Walk siblings, descend into inline elements, and when the siblings run
  # out climb to an inline parent. A block or a br ends the run.
  # rules responds to block?, br?, and inline?.
  def neighbor_char(node, direction, rules)
    before = direction == :before
    side = before ? :last : :first
    current = node
    while current
      sib = before ? current.previous_sibling : current.next_sibling
      while sib
        found = edge_of(sib, side, rules)
        return nil if found == :stop
        return found if found

        sib = before ? sib.previous_sibling : sib.next_sibling
      end
      parent = current.parent
      break unless parent&.element? && rules.inline?(parent)

      current = parent
    end
    nil
  end

  def edge_of(node, side, rules)
    if node.element?
      return :stop if rules.block?(node) || rules.br?(node)
      return :stop unless rules.inline?(node)

      children = node.children
      seq = side == :last ? children.reverse_each : children.each
      seq.each do |child|
        found = edge_of(child, side, rules)
        return :stop if found == :stop
        return found if found
      end
      return nil
    end

    text = text_of(node)
    return nil if text.nil? || text.empty?

    side == :last ? last_non_ws(text) : first_non_ws(text)
  end

  def text_of(node)
    if node.text? || node.cdata?
      node.content
    elsif node.is_a?(Nokogiri::XML::EntityReference)
      node.content.to_s
    end
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
