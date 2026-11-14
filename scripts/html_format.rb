# frozen_string_literal: true

require 'nokogiri'
require_relative 'html_stylesheet_scan'
require_relative 'util'

# Indent-only formatter for the book's XHTML pages (issue #207).
#
# A free gap is a whitespace-only text node, or an empty spot, whose parent
# is a visible block and whose neighbors are visible blocks (or one visible
# block and the start or end of the parent). The formatter rewrites only
# those gaps. Every other byte stays, including inline text and the inside
# of a verbatim element.
#
# A plain head is not shown. The exception applies only when head has no
# non-whitespace text, and every element child is an unprefixed title, meta,
# link, script, style, or base in the XHTML namespace or in no namespace.
# The generated pages put some head scripts in no namespace. A prefixed name
# such as x:title is not metadata. A gap in a head that qualifies, whose
# neighbors are plain elements, including the gap at either edge, is free,
# so each head child starts on its own line. The ePub packager reads those
# lines. Any other head keeps every gap in the head, and the gap between
# html and head. A class, id, style, or hidden attribute, or an excluded
# tag or class, keeps the gap it bounds.
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
  # table through th: table parts. A part is a block only when every step
  # from it up to a table element is a parent an HTML parser keeps. A part
  # whose placement is not valid freezes its whole subtree: the parser
  # drops the tags, and a gap inside them would become a space.
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
  # A table part is a block only when every step up to table is one of
  # these parents. col is also a child of table in the XHTML tree; the
  # HTML parser would wrap it.
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
  # Element children an HTML parser leaves in head when the tag is unprefixed.
  # head_metadata? also requires the XHTML namespace or no namespace. A head
  # script in the generated pages has no namespace. A prefixed name does not
  # match, and neither does an element in any other namespace.
  HEAD_CONTENT = %w[title meta link script style base].freeze
  BLOCK_TAG = BLOCK_TAGS.to_h { |tag| [tag, true] }.freeze
  EXCLUSION_TAG = EXCLUSION_TAGS.to_h { |tag| [tag, true] }.freeze
  EXCLUSION_CLASS = EXCLUSION_CLASSES.to_h { |name| [name, true] }.freeze
  FREEZE_TAG = FREEZE_TAGS.to_h { |tag| [tag, true] }.freeze
  FREEZE_CLASS = FREEZE_CLASSES.to_h { |name| [name, true] }.freeze
  HEAD_CONTENT_TAG = HEAD_CONTENT.to_h { |tag| [tag, true] }.freeze

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
      # DocBook writes <html...><head> with nothing between the tags. Head is
      # not a visible block, and the ordinary rule would keep the join. This
      # gap stays free so head starts on its own line, only while head itself
      # is plain metadata.
      return true if left.nil? && head?(right) && head_exception?(right)
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

  # libxml inserts an encoding meta while saving an XHTML document that
  # lacks one. The inserted meta is not in the tree, so a second format
  # would indent it and the bytes would change. Put the contract meta in
  # the tree before either write.
  def ensure_content_type_meta!(document)
    root = document.root
    return document unless root
    head = root.elements.find { |element| head?(element) }
    return document unless head
    ensure_contract_meta!(document, head)
    document
  end

  def write(document)
    serialize_page(document, mode: :html)
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
    # The XHTML 1.0 DTD fixed xml:space="preserve" on pre, script, and style.
    # HTML5 pages have no DTD, so those elements stay verbatim by name.
    return true if node.name == 'pre' || node.name == 'script' || node.name == 'style'
    return true unless xhtml?(node)
    VERBATIM_TAGS.include?(node.name)
  end

  # A preserving white-space value is inherited, so the whole subtree is
  # left as it was. An unreadable style might hide such a value. A table
  # part in an invalid place freezes its subtree for the same reason: the
  # HTML parser drops the tags and exposes the gaps.
  def subtree_frozen?(node)
    return true if FREEZE_TAG[node.name]
    class_tokens(node).each do |token|
      return true if FREEZE_CLASS[token]
    end
    info = style_info(node)
    return true if info == :unreadable
    return true if info && info[:preserve]
    misplaced_table_part?(node)
  end

  # nil when the element has no style attribute. :unreadable when the
  # attribute contains a character this check does not parse (a quote, an
  # escape, !important, or a comment marker). Otherwise :preserve is true
  # when the winning white-space or white-space-collapse value is not in
  # HtmlStylesheetScan::SAFE_VALUE. A malformed declaration is dropped and
  # does not replace an earlier one. Any declaration other than the
  # STYLE_ALLOW pairs means the element is not a visible block.
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
    whitespace = nil
    collapse = nil
    raw.split(';').each do |part|
      piece = part.strip
      next if piece.empty?
      colon = piece.index(':')
      next unless colon
      prop = piece[0...colon].strip.downcase
      next if prop.empty?
      value = piece[(colon + 1)..].strip.downcase.gsub(/[ \t\r\n\f]+/, ' ')
      verdict = HtmlStylesheetScan.value_verdict(prop, value)
      next if verdict == :drop
      if prop == 'white-space'
        whitespace = verdict
      elsif prop == 'white-space-collapse'
        collapse = verdict
      end
      allowed = false unless STYLE_ALLOW[prop] == value
    end
    preserve = whitespace == :unsafe || collapse == :unsafe
    { allowed: allowed, preserve: preserve }
  end

  # Quotes, escapes, !important, and comment markers can hide a value.
  # Brackets are classified by HtmlStylesheetScan.value_verdict: a balanced
  # value is safe or unsafe, and an unbalanced value is dropped.
  def style_unreadable?(text)
    text.each_char do |char|
      return true if char == '\\' || char == '"' || char == "'" || char == '!' ||
                     char == '/' || char == '*'
    end
    false
  end

  # True when this part is not a table part, or every parent from here up
  # to a table element is a parent the HTML parser keeps.
  def table_parent_ok?(node)
    return true unless TABLE_PARENT[node.name]
    current = node
    while TABLE_PARENT[current.name]
      parent = current.parent
      return false unless parent&.element? && xhtml?(parent)
      return false unless TABLE_PARENT[current.name].include?(parent.name)
      return true if parent.name == 'table'
      current = parent
    end
    false
  end

  def misplaced_table_part?(node)
    return false unless node&.element? && xhtml?(node)
    return false unless TABLE_PARENT[node.name]
    !table_parent_ok?(node)
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
    flags[0] = true if kind == :html && count.positive? && head?(sigs[0]) && head_exception?(sigs[0])
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

  # The head exception applies only when the head is plain metadata.
  # Non-whitespace text, a prefixed name, or any other element means no
  # gap in that head is free, and the gap before head is not free either.
  def head_exception?(node)
    plain_head_part?(node) && head_metadata?(node)
  end

  def head_metadata?(head)
    return false unless head&.element?
    child = head.child
    while child
      if child.text?
        return false unless whitespace_only?(child.content)
      elsif child.element?
        return false unless head_content_element?(child)
      end
      child = child.next
    end
    true
  end

  # Unprefixed, and in the XHTML namespace or in no namespace. HTML ignores
  # an xmlns attribute and uses the qualified name, so x:title is not a
  # title. The book's head scripts are unprefixed and have no namespace.
  def head_content_element?(element)
    return false unless HEAD_CONTENT_TAG[element.name]
    prefix = element.namespace&.prefix
    return false unless prefix.nil? || prefix.empty?
    href = namespace_href(element)
    href.nil? || href.empty? || href == XHTML_NS
  end

  # A plain head is not rendered. Each plain element child starts on its
  # own line, including a child that is the first or the last.
  def head_gap?(head, left, right)
    return false unless head_exception?(head)
    left_ok = left.nil? || plain_head_part?(left)
    right_ok = right.nil? || plain_head_part?(right)
    left_ok && right_ok && !(left.nil? && right.nil?)
  end
  private_class_method :format_element, :normalize_gaps, :indent_for, :gap_text,
                       :inside_verbatim?, :visible_block_uncached, :verbatim_uncached,
                       :subtree_frozen?, :style_info, :style_info_uncached,
                       :style_unreadable?,
                       :table_parent_ok?, :misplaced_table_part?, :plain_head_part?,
                       :head_exception?, :head_metadata?, :head_content_element?,
                       :xml_space?, :gap_kind,
                       :block_edges?, :head_gap?, :content_type_meta?
end
