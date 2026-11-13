# frozen_string_literal: true

# Shared by the HTML formatter and the whitespace guard (issue #207).
# One safe-character set, one inline-neighbor search, and one free-gap
# decision, so the two agree.
#
# An inline run may change between a space and a line break only when both
# sides are characters in the safe set. The safe set is the scripts this
# book uses: ASCII punctuation and letters, Latin, Greek, Cyrillic, and
# general punctuation. A character is left out when it is wide, a control,
# or in Unicode category Cf, Mn, Me, or Zs (format, mark, or space).
# Every other inline run stays byte for byte. That includes a side that is
# missing, a hidden element, a verbatim element, or a character outside the
# safe set. A visible block or a visible br is a structural boundary, not
# one of those frozen sides.
#
# A gap is free when a visible block bounds it, on either side or as the
# parent edge of a structural container. An empty anchor before a paragraph
# is that shape. A hidden element is not a visible block, so it does not
# make a gap free by itself. A visible block on the other side, or a
# structural container, still does. The gap after a br is never free.
#
# An element the stylesheet hides (display-none, guibutton, a hidden br,
# script, style) is skipped while looking for a character. A visible
# verbatim element, such as MathML or xml:space="preserve", is not read.
# Entity replacement text comes from the document. The formatter and the
# guard both load the local XHTML DTD, so a DTD entity such as nbsp has the
# same characters on both sides.
#
# A head without a Content-Type meta element is formatted again on a second
# pass. The pages of this book include that element.

module HtmlInlineNeighbors
  ZWSP = "\u200B"

  HIDDEN_CLASS = %w[display-none guibutton].freeze
  HIDDEN_BR = %w[example-break table-break].freeze

  # East Asian wide and fullwidth characters. They are outside the safe set.
  # A space between two of them would be removed if a line break replaced it.
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

  # Format, mark, space, and the other categories that must not be safe
  # even when a code point sits inside a script range below.
  UNSAFE_CATEGORY = /[\p{Cf}\p{Mn}\p{Me}\p{Cc}\p{Cs}\p{Co}\p{Cn}\p{Zs}\p{Zl}\p{Zp}]/.freeze

  module_function

  def wide_char?(char)
    return false unless char.is_a?(String) && char.length == 1

    cp = char.ord
    WIDE_RANGES.any? { |range| range.cover?(cp) }
  end

  # Printable ASCII, Latin, Greek, Cyrillic, and general punctuation.
  # U+00A0 is a space. U+00AD is a format character. Both are excluded.
  def safe_char?(char)
    return false unless char.is_a?(String) && char.length == 1

    cp = char.ord
    return true if cp >= 0x21 && cp <= 0x7E
    return false if cp <= 0x20 || cp == 0x7F
    return false if UNSAFE_CATEGORY.match?(char)
    return false if wide_char?(char)
    return true if cp >= 0x00A1 && cp <= 0x024F
    return true if cp >= 0x1E00 && cp <= 0x1EFF
    return true if cp >= 0x0370 && cp <= 0x03FF || cp >= 0x1F00 && cp <= 0x1FFF
    return true if cp >= 0x0400 && cp <= 0x052F
    return true if cp >= 0x2000 && cp <= 0x206F

    false
  end

  def mutable_run?(left, right)
    safe_char?(left) && safe_char?(right)
  end

  # True when an inline run must be copied unchanged. A visible block is
  # not frozen: the formatter reindents there. A visible br is not frozen
  # either: the br rule owns that run. A hidden br is not :br. The search
  # skips it, and the characters on either side decide. Any other unsafe
  # side freezes the run.
  def fixed_inline_run?(left, right)
    return false if mutable_run?(left, right)
    return false if left == :block || right == :block
    return false if left == :br || right == :br

    true
  end

  # A gap may gain or lose whitespace when a visible block bounds it.
  # Either side is enough: a paragraph after an empty anchor is that shape.
  # A hidden element is not that block. The parent edge of a structural
  # container counts, including beside a hidden child. The gap after a br
  # does not.
  def boundary_gap_free?(left_visible_block, right_visible_block, after_br: false, container: false)
    return false if after_br
    return true if container

    left_visible_block || right_visible_block
  end

  # The status on the before or after side of node.
  # A string is a character. :block is a visible block, including the
  # parent edge of a block. :br is a visible br. :verbatim is a visible
  # verbatim element, which is not read. nil means nothing was found.
  # rules responds to block?, br?, inline?, and verbatim?.
  def neighbor_status(node, direction, rules)
    before = direction == :before
    side = before ? :last : :first
    current = node
    while current
      sib = before ? current.previous_sibling : current.next_sibling
      while sib
        found = edge_status(sib, side, rules)
        return found unless found.nil?

        sib = before ? sib.previous_sibling : sib.next_sibling
      end
      parent = current.parent
      break unless parent&.element?
      # The interior of a block, hidden or not, still reindents at its edge.
      return :block if rules.block?(parent)
      return :verbatim if rules.verbatim?(parent)
      break unless hidden_element?(parent) || rules.inline?(parent)

      current = parent
    end
    nil
  end

  # nil: nothing here, keep looking. A string is the character.
  def edge_status(node, side, rules)
    unless node.element?
      return nil if node.comment? || node.processing_instruction?

      text = text_of(node)
      return nil if text.nil? || text.empty?

      return side == :last ? last_non_ws(text) : first_non_ws(text)
    end

    # A hidden element is not a boundary. Look past it, block or inline.
    return nil if hidden_element?(node)
    return :block if rules.block?(node)
    return :br if rules.br?(node)
    return :verbatim if rules.verbatim?(node)
    return read_status(node, side, rules) if rules.inline?(node)

    :block
  end

  # First or last status inside an ordinary inline element.
  # An empty inline element is transparent. A verbatim child is not.
  def read_status(node, side, rules)
    children = node.children
    seq = side == :last ? children.reverse_each : children.each
    seq.each do |child|
      found = edge_status(child, side, rules)
      return found unless found.nil?
    end
    nil
  end

  # display:none in assets/css/master.css, plus script and style, which
  # the browser does not render. A hidden br is display:none as well.
  def hidden_element?(node)
    return false unless node&.element?

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

  def boundary_ws?(text, side)
    return false if text.empty?

    byte = side == :first ? text.getbyte(0) : text.getbyte(text.bytesize - 1)
    byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
  end
end
