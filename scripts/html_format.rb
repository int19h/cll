# frozen_string_literal: true

require 'nokogiri'

# Indent-only formatter for the book's XHTML pages (issue #207).
#
# A free gap is a whitespace-only text node, or an empty spot, whose parent
# is a visible block and whose neighbors are visible blocks (or one visible
# block and the start or end of the parent). The formatter rewrites only
# those gaps. Every other byte stays, including inline text and the inside
# of a verbatim element.
#
# Head is not shown. A gap in head whose neighbors are elements, including
# the gap at either edge of head, is also free, so each head child starts
# on its own line. The ePub packager reads those lines.
module HtmlFormat
  XHTML_NS = 'http://www.w3.org/1999/xhtml'
  XML_NS = 'http://www.w3.org/XML/1998/namespace'
  WHITESPACE = " \t\r\n\f"

  # Tags whose CSS default is a block, a list item, or a table part.
  # A line break beside one of these is not a space, unless the exclusion
  # set below says a stylesheet rule can change that.
  #
  # html, body: the page boxes.
  # h1–h6: headings. h3 is excluded, because master.css hides some h3 elements.
  # address, blockquote, p: blocks of text. p is excluded by `p { display: block }`.
  # div, section, article, aside, nav, header, footer, main, hgroup: grouping boxes.
  # pre: a block when it is a sibling. Its contents are verbatim and are not rewritten.
  # hr: a block by default. hr is excluded, because some title-page rules hide it.
  # ul, ol, li, dl, dt, dd: lists. A list item is a block for whitespace.
  # figure, figcaption, fieldset, legend, form, details, summary: other HTML blocks.
  # table through th: table parts. Whitespace between them is not rendered.
  #
  # Left off the list, because a line break beside them can be a space or
  # they are not boxes in the page:
  # head (its own gap rule), br and img (also excluded by CSS), the inline
  # tags, script, style, textarea, center, menu, dir, and dialog.
  BLOCK_TAGS = %w[
    html body
    h1 h2 h3 h4 h5 h6
    address blockquote p
    div section article aside nav header footer main hgroup
    pre hr
    ul ol li dl dt dd
    figure figcaption fieldset legend form details summary
    table caption colgroup col thead tbody tfoot tr td th
  ].freeze

  # Every tag and class that appears in a selector of a rule that sets
  # display, visibility, or content-visibility. scripts/test-html-format.rb
  # recomputes this from assets/css and from the comparison-page style.
  EXCLUSION_TAGS = %w[br h3 hr img p].freeze
  EXCLUSION_CLASSES = %w[
    article book display-none example-break guibutton publication-notice
    release-date release-separator release-version table-break titlepage
    tutci whole-index
  ].freeze

  VERBATIM_TAGS = %w[math pre script style svg textarea].freeze

  module_function

  def visible_block?(node)
    return false unless node&.element?
    return false unless xhtml?(node)
    return false unless BLOCK_TAGS.include?(node.name)
    return false if EXCLUSION_TAGS.include?(node.name)
    class_tokens(node).each do |token|
      return false if EXCLUSION_CLASSES.include?(token)
    end
    true
  end

  def verbatim?(node)
    return false unless node&.element?
    return true if xml_space?(node)
    return true unless xhtml?(node)
    VERBATIM_TAGS.include?(node.name)
  end

  # True when whitespace at this spot has no effect on the page.
  # left and right are the neighboring significant nodes, or nil at an edge.
  def free_gap?(parent, left, right)
    return false unless parent&.element?
    return false if inside_verbatim?(parent)
    if head?(parent)
      return head_gap?(left, right)
    end
    # DocBook writes <html...><head> with nothing between the tags. The ePub
    # packager replaces the whole line that starts with <html, so a joined
    # <head> would be deleted with that line. Head is not a visible block, and
    # the ordinary rule would keep the join. This gap is the exception.
    if parent.name == 'html' && xhtml?(parent) && left.nil? && head?(right)
      return true
    end
    return false unless visible_block?(parent)
    left_block = block_neighbor?(left)
    right_block = block_neighbor?(right)
    return true if left_block && right_block
    return true if left.nil? && right_block
    return true if right.nil? && left_block
    false
  end

  def format!(document)
    format_element(document.root) if document.root
    document
  end

  # libxml inserts this meta while saving an XHTML document that lacks one.
  # The inserted meta is not in the tree, so a second format would indent it
  # and the bytes would change. Add it before either write when it is missing.
  def ensure_content_type_meta!(document)
    root = document.root
    return document unless root
    head = root.elements.find { |element| head?(element) }
    return document unless head
    return document if head.elements.any? { |element| content_type_meta?(element) }
    meta = Nokogiri::XML::Element.new('meta', document)
    meta.namespace = head.namespace
    meta['http-equiv'] = 'Content-Type'
    meta['content'] = 'text/html; charset=UTF-8'
    first = head.children.first
    if first
      first.add_previous_sibling(meta)
    else
      head.add_child(meta)
    end
    document
  end

  def write(document)
    document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
  end

  def whitespace_text?(node)
    return false unless node&.text?
    return false if node.cdata?
    whitespace_only?(node.content)
  end

  def whitespace_only?(text)
    return false if text.nil?
    i = 0
    while i < text.length
      return false unless WHITESPACE.include?(text[i])
      i += 1
    end
    true
  end

  def xhtml?(node)
    node.namespace&.href == XHTML_NS
  end

  def head?(node)
    node&.element? && node.name == 'head' && xhtml?(node)
  end

  def class_tokens(element)
    value = element['class']
    return [] if value.nil? || value.empty?
    value.split(/[ \t\r\n\f]+/).reject(&:empty?)
  end

  def element_depth(node)
    depth = 0
    current = node.parent
    while current&.element?
      depth += 1
      current = current.parent
    end
    depth
  end

  def format_element(element)
    return if verbatim?(element)
    element.elements.each { |child| format_element(child) }
    normalize_gaps(element)
  end

  def normalize_gaps(element)
    sigs, gaps = split_children(element)
    sigs.length.downto(0) do |index|
      left = index.zero? ? nil : sigs[index - 1]
      right = index == sigs.length ? nil : sigs[index]
      next unless free_gap?(element, left, right)
      indent = gap_text(element, right)
      nodes = gaps[index]
      next if nodes.length == 1 && nodes[0].content == indent
      # Remove the old gap before inserting. libxml merges a new text node
      # into an adjacent text node, and unlinking that neighbor then deletes
      # the indent that was just inserted.
      nodes.each(&:unlink)
      text = Nokogiri::XML::Text.new(indent, element.document)
      if right
        right.add_previous_sibling(text)
      else
        element.add_child(text)
      end
    end
  end

  def gap_text(parent, right)
    depth = right.nil? ? element_depth(parent) : element_depth(right)
    "\n" + ('  ' * depth)
  end

  def split_children(parent)
    sigs = []
    gaps = [[]]
    parent.children.each do |child|
      if whitespace_text?(child)
        gaps.last << child
      else
        sigs << child
        gaps << []
      end
    end
    [sigs, gaps]
  end

  def inside_verbatim?(node)
    current = node
    while current&.element?
      return true if verbatim?(current)
      current = current.parent
    end
    false
  end

  def xml_space?(element)
    element.attribute_nodes.any? do |attr|
      attr.name == 'space' && attr.namespace&.href == XML_NS
    end
  end

  def block_neighbor?(node)
    !node.nil? && visible_block?(node)
  end

  def content_type_meta?(element)
    return false unless element.element? && element.name == 'meta'
    equiv = element['http-equiv']
    !equiv.nil? && equiv.casecmp('Content-Type').zero?
  end

  # Head is not rendered. Each of its element children starts on its own
  # line, including a child that is the first or the last.
  def head_gap?(left, right)
    left_ok = left.nil? || left.element?
    right_ok = right.nil? || right.element?
    left_ok && right_ok && !(left.nil? && right.nil?)
  end
  private_class_method :format_element, :normalize_gaps, :gap_text,
                       :inside_verbatim?, :xml_space?, :block_neighbor?, :head_gap?,
                       :content_type_meta?
end
