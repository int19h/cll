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
# A plain head is not shown. A gap in that head whose neighbors are plain
# elements, including the gap at either edge, is free, so each head child
# starts on its own line. The ePub packager reads those lines. A class, id,
# style, or hidden attribute, or an excluded tag or class, keeps the gap.
module HtmlFormat
  XHTML_NS = 'http://www.w3.org/1999/xhtml'
  XML_NS = 'http://www.w3.org/XML/1998/namespace'
  WHITESPACE = " \t\r\n\f"

  # Tags whose CSS default is a block, a list item, or a table part.
  # A line break beside one of these is not a space, unless the exclusion
  # set below says a stylesheet rule can change that.
  #
  # html, body: the page boxes.
  # h1–h6: headings. h3 is excluded, because the subject of `.whole-index h3`
  # is the h3, and that rule hides it.
  # address, blockquote, p: blocks of text. `p { display: block }` does not exclude p.
  # div, section, article, aside, nav, header, footer, main, hgroup: grouping boxes.
  # pre: a block when it is a sibling. Its contents are verbatim and are not rewritten.
  # hr: a block by default. hr is excluded, because title-page rules hide that subject.
  # ul, ol, li, dl, dt, dd: lists. A list item is a block for whitespace.
  # figure, figcaption, fieldset, legend, form, details, summary: other HTML blocks.
  # table through th: table parts. Whitespace between them is not rendered
  # when the part sits in the parent an HTML parser keeps. A caption, row,
  # or cell in any other parent is not a block: the HTML parser drops the
  # tag, and a gap beside it would become a space.
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

  # The subject (last compound) of a rule that can take a block out of
  # block layout. scripts/test-html-format.rb recomputes this from assets/css
  # and from the comparison-page style.
  EXCLUSION_TAGS = %w[br h3 hr].freeze
  EXCLUSION_CLASSES = %w[
    display-none example-break guibutton release-date release-separator
    release-version table-break tutci
  ].freeze
  # Subjects of a whitespace-preserving rule. The property is inherited, so
  # the whole subtree is verbatim. The book's stylesheets have none: nowrap
  # and normal collapse. scripts/test-html-format.rb recomputes this too.
  FREEZE_TAGS = [].freeze
  FREEZE_CLASSES = [].freeze
  # Inline styles on the generated pages. Any other declaration, or a style
  # this list cannot read, means the element is not a visible block.
  STYLE_ALLOW = {
    'clear' => 'both',
    'list-style-type' => 'disc'
  }.freeze
  # "\n" plus two spaces per ancestor. Depths in this book stay far below 48.
  INDENTS = (0..48).map { |depth| "\n#{'  ' * depth}" }.freeze

  VERBATIM_TAGS = %w[math pre script style svg textarea].freeze
  # A table part is a block only in one of these parents. col is also a
  # child of table in the XHTML tree; the HTML parser would wrap it.
  TABLE_PARENT = {
    'caption' => %w[table].freeze,
    'colgroup' => %w[table].freeze,
    'col' => %w[colgroup table].freeze,
    'thead' => %w[table].freeze,
    'tbody' => %w[table].freeze,
    'tfoot' => %w[table].freeze,
    'tr' => %w[table thead tbody tfoot].freeze,
    'td' => %w[tr].freeze,
    'th' => %w[tr].freeze
  }.freeze
  BLOCK_TAG = BLOCK_TAGS.to_h { |tag| [tag, true] }.freeze
  EXCLUSION_TAG = EXCLUSION_TAGS.to_h { |tag| [tag, true] }.freeze
  EXCLUSION_CLASS = EXCLUSION_CLASSES.to_h { |name| [name, true] }.freeze
  FREEZE_TAG = FREEZE_TAGS.to_h { |tag| [tag, true] }.freeze
  FREEZE_CLASS = FREEZE_CLASSES.to_h { |name| [name, true] }.freeze

  module_function

  def visible_block?(node)
    return false unless node&.element?
    cache = @visible_cache
    if cache && cache.key?(node)
      return cache[node]
    end
    result = visible_block_uncached(node)
    cache[node] = result if cache
    result
  end

  def verbatim?(node)
    return false unless node&.element?
    cache = @verbatim_cache
    if cache && cache.key?(node)
      return cache[node]
    end
    result = verbatim_uncached(node)
    cache[node] = result if cache
    result
  end

  # Remember block and verbatim answers for one walk. Nokogiri returns the
  # same Ruby object for a node, so the node itself is a stable key.
  def with_memo
    previous = [@visible_cache, @verbatim_cache, @inside_cache, @kind_cache, @ns_href, @style_cache]
    @visible_cache = {}
    @verbatim_cache = {}
    @inside_cache = {}
    @kind_cache = {}
    @ns_href = {}
    @style_cache = {}
    yield
  ensure
    @visible_cache, @verbatim_cache, @inside_cache, @kind_cache, @ns_href, @style_cache = previous
  end

  # True when whitespace at this spot has no effect on the page.
  # left and right are the neighboring significant nodes, or nil at an edge.
  def free_gap?(parent, left, right)
    return false unless parent&.element?
    case gap_kind(parent)
    when :verbatim
      false
    when :head
      head_gap?(parent, left, right)
    when :html
      # DocBook writes <html...><head> with nothing between the tags. The ePub
      # packager replaces the whole line that starts with <html, so a joined
      # <head> would be deleted with that line. Head is not a visible block,
      # and the ordinary rule would keep the join. This gap is the exception
      # only while head itself is plain and not excluded.
      return true if left.nil? && head?(right) && plain_head_part?(right)
      return false unless visible_block?(parent)
      block_edges?(left, right)
    when :block
      block_edges?(left, right)
    else
      false
    end
  end

  def format!(document)
    with_memo { format_element(document.root, 0) if document.root }
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
    # blank? is libxml's XML-space test and does not copy the text. A node
    # that is only a form feed is whitespace here and is not blank there.
    return true if node.blank?
    whitespace_only?(node.content)
  end

  def whitespace_only?(text)
    return true if text.nil?
    text.each_byte do |byte|
      # space, tab, LF, CR, FF. A non-ASCII byte is not one of these.
      return false unless byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
    end
    true
  end

  def xhtml?(node)
    namespace_href(node) == XHTML_NS
  end

  # The namespace object is stable, but href allocates a new string. Keep one
  # string for each namespace during a walk.
  def namespace_href(node)
    ns = node.namespace
    return nil unless ns
    cache = @ns_href
    if cache
      return cache[ns] if cache.key?(ns)
      cache[ns] = ns.href
    else
      ns.href
    end
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

  def format_element(element, depth)
    return if verbatim?(element)
    child_depth = depth + 1
    child = element.child
    while child
      nxt = child.next
      format_element(child, child_depth) if child.element?
      child = nxt
    end
    normalize_gaps(element, depth)
  end

  def normalize_gaps(element, depth)
    sigs, gaps = split_children(element)
    flags = free_gap_flags(element, sigs)
    last = sigs.length
    last.downto(0) do |index|
      next unless flags[index]
      right = index == last ? nil : sigs[index]
      indent = indent_for(right.nil? ? depth : depth + 1)
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

  def indent_for(depth)
    INDENTS[depth] || "\n#{'  ' * depth}"
  end

  def gap_text(parent, right)
    depth = right.nil? ? element_depth(parent) : element_depth(right)
    indent_for(depth)
  end

  def split_children(parent)
    sigs = []
    gaps = [[]]
    child = parent.child
    while child
      if whitespace_text?(child)
        gaps.last << child
      else
        sigs << child
        gaps << []
      end
      child = child.next
    end
    [sigs, gaps]
  end

  def inside_verbatim?(node)
    return false unless node&.element?
    cache = @inside_cache
    if cache && cache.key?(node)
      return cache[node]
    end
    result = if verbatim?(node)
               true
             else
               parent = node.parent
               parent&.element? ? inside_verbatim?(parent) : false
             end
    cache[node] = result if cache
    result
  end

  def visible_block_uncached(node)
    return false unless xhtml?(node)
    return false unless BLOCK_TAG[node.name]
    return false if EXCLUSION_TAG[node.name]
    class_tokens(node).each do |token|
      return false if EXCLUSION_CLASS[token]
    end
    return false if node.attribute('hidden')
    info = style_info(node)
    return false if info == :unreadable || (info && !info[:allowed])
    return false unless table_parent_ok?(node)
    true
  end

  def verbatim_uncached(node)
    return true if xml_space?(node)
    return true if subtree_frozen?(node)
    return true unless xhtml?(node)
    VERBATIM_TAGS.include?(node.name)
  end

  # A preserving white-space value is inherited, so the whole subtree is
  # left as it was. An unreadable style might hide such a value.
  def subtree_frozen?(node)
    return true if FREEZE_TAG[node.name]
    class_tokens(node).each do |token|
      return true if FREEZE_CLASS[token]
    end
    info = style_info(node)
    return true if info == :unreadable
    return true if info && info[:preserve]
    false
  end

  # nil when the element has no style attribute. :unreadable when a
  # declaration cannot be checked against STYLE_ALLOW. Otherwise the
  # declarations are all on that list, and :preserve is true when a
  # white-space value would keep an inserted gap.
  def style_info(element)
    cache = @style_cache
    if cache && cache.key?(element)
      return cache[element]
    end
    result = style_info_uncached(element)
    cache[element] = result if cache
    result
  end

  def style_info_uncached(element)
    attr = element.attribute('style')
    return nil unless attr
    raw = attr.value.to_s
    return { allowed: true, preserve: false } if raw.empty?
    return :unreadable if style_unreadable?(raw)
    allowed = true
    preserve = false
    raw.split(';').each do |part|
      piece = part.strip
      next if piece.empty?
      colon = piece.index(':')
      return :unreadable unless colon
      prop = piece[0...colon].strip.downcase
      value = piece[(colon + 1)..].strip.downcase.gsub(/[ \t\r\n\f]+/, ' ')
      return :unreadable if prop.empty? || value.empty?
      if (prop == 'white-space' || prop == 'white-space-collapse') &&
         value != 'normal' && value != 'nowrap'
        preserve = true
      end
      allowed = false unless STYLE_ALLOW[prop] == value
    end
    { allowed: allowed, preserve: preserve }
  end

  def style_unreadable?(text)
    text.each_char do |char|
      return true if char == '\\' || char == '"' || char == "'" || char == '(' ||
                     char == ')' || char == '{' || char == '}' || char == '!' ||
                     char == '/' || char == '*'
    end
    false
  end

  def table_parent_ok?(node)
    parents = TABLE_PARENT[node.name]
    return true unless parents
    parent = node.parent
    parent&.element? && xhtml?(parent) && parents.include?(parent.name)
  end

  # Head gaps stay free only while head and the elements that bound the gap
  # have no class, id, style, or hidden attribute, and neither their tags
  # nor their classes are excluded. A missing neighbor is an edge.
  def plain_head_part?(node)
    return false unless node&.element?
    return false if node.attribute('class') || node.attribute('id') ||
                    node.attribute('style') || node.attribute('hidden')
    return false if EXCLUSION_TAG[node.name]
    class_tokens(node).each do |token|
      return false if EXCLUSION_CLASS[token]
    end
    true
  end

  def xml_space?(element)
    element.attribute_nodes.any? do |attr|
      attr.name == 'space' && attr.namespace&.href == XML_NS
    end
  end

  # One answer per element for the whole walk: a verbatim subtree, head,
  # the html element, some other visible block, or neither.
  def gap_kind(parent)
    cache = @kind_cache
    if cache
      found = cache[parent]
      return found if found
    end
    kind = if inside_verbatim?(parent)
             :verbatim
           elsif head?(parent)
             :head
           elsif parent.name == 'html' && xhtml?(parent)
             :html
           elsif visible_block?(parent)
             :block
           else
             :other
           end
    cache[parent] = kind if cache
    kind
  end

  def block_edges?(left, right)
    left_block = !left.nil? && visible_block?(left)
    right_block = !right.nil? && visible_block?(right)
    return true if left_block && right_block
    return true if left.nil? && right_block
    return true if right.nil? && left_block
    false
  end

  # The same answers as free_gap?, one per gap, for a parent whose significant
  # children are sigs. Gap 0 is the start of the parent. The last gap is the end.
  def free_gap_flags(parent, sigs)
    count = sigs.length
    flags = Array.new(count + 1, false)
    return flags unless parent&.element?
    kind = gap_kind(parent)
    if kind == :head
      index = 0
      while index <= count
        left = index.zero? ? nil : sigs[index - 1]
        right = index == count ? nil : sigs[index]
        flags[index] = head_gap?(parent, left, right)
        index += 1
      end
      return flags
    end
    return flags if kind == :verbatim || kind == :other
    # The gap before <head> is free even though head is not a visible block.
    # A later pass may also mark it free. It must not be cleared.
    flags[0] = true if kind == :html && count.positive? && head?(sigs[0]) && plain_head_part?(sigs[0])
    return flags if kind == :html && !visible_block?(parent)
    return flags unless kind == :block || kind == :html
    blocks = Array.new(count)
    index = 0
    while index < count
      node = sigs[index]
      blocks[index] = node.element? && visible_block?(node)
      index += 1
    end
    index = 0
    while index <= count
      left_nil = index.zero?
      right_nil = index == count
      left_block = left_nil ? false : blocks[index - 1]
      right_block = right_nil ? false : blocks[index]
      if (left_block && right_block) || (left_nil && right_block) || (right_nil && left_block)
        flags[index] = true
      end
      index += 1
    end
    flags
  end

  def content_type_meta?(element)
    return false unless element.element? && element.name == 'meta'
    equiv = element['http-equiv']
    !equiv.nil? && equiv.casecmp('Content-Type').zero?
  end

  # A plain head is not rendered. Each plain element child starts on its
  # own line, including a child that is the first or the last.
  def head_gap?(head, left, right)
    return false unless plain_head_part?(head)
    left_ok = left.nil? || plain_head_part?(left)
    right_ok = right.nil? || plain_head_part?(right)
    left_ok && right_ok && !(left.nil? && right.nil?)
  end
  private_class_method :format_element, :normalize_gaps, :indent_for, :gap_text,
                       :inside_verbatim?, :visible_block_uncached, :verbatim_uncached,
                       :subtree_frozen?, :style_info, :style_info_uncached,
                       :style_unreadable?, :table_parent_ok?, :plain_head_part?,
                       :xml_space?, :gap_kind, :block_edges?, :head_gap?,
                       :content_type_meta?
end
