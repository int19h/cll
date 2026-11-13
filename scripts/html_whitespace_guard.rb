# frozen_string_literal: true

# Compare two XHTML texts and refuse an unsafe whitespace change (issue #207).
#
# The guard parses each text on its own. It does not call the formatter.
# A whitespace run may appear or disappear only at a free gap. The free-gap
# decision and the characters on each side of a run come from
# HtmlInlineNeighbors, the same module the formatter uses. An inline run
# may change between a space and a line break only when that module says
# both sides are safe. A block edge, a visible br, and a free gap may
# reshape a run only when the inline character is safe or absent. Every
# other inline run must match byte for byte. Inside a verbatim element the
# text must match byte for byte. The gap after a br is never free, and a
# hidden element never makes a gap free.
#
# The comparison covers the raw XML declaration, the doctype and the text
# of its internal subset, the order of comments and processing instructions
# around the doctype, and comments, processing instructions, and entity
# references in the text. The guard loads the same local XHTML DTD as the
# formatter, through the catalog, and does not use the network. That parse
# is only for entities. Element and attribute namespaces come from a second
# parse that does not apply DTD defaults, so removing xmlns from html is
# visible. An undefined entity anywhere in the page is an error, and the
# message names it.
#
# libxml2 reads XML_CATALOG_FILES when the catalog is first initialized.
# Nokogiri's packaged libxml2 is linked into nokogiri.so, so
# install_local_catalog calls xmlLoadCatalog on that extension. The call
# adds this repository's catalog after an earlier parse. An empty catalog
# loaded first does not hide the later entries. A catalog entry that
# already matched the same identifier keeps that first match.
#
# Usage: ruby scripts/html_whitespace_guard.rb [--strict] BEFORE AFTER
# BEFORE and AFTER are files, or directories of .html files with the same names.

require 'fiddle'
require 'nokogiri'
require_relative 'html_inline_neighbors'

module HtmlWhitespaceGuard
  class Unsafe < StandardError
  end

  XHTML = 'http://www.w3.org/1999/xhtml'
  XMLNS = 'http://www.w3.org/2000/xmlns/'
  WS_RUN = /[ \t\n\r\f]+/
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
    doc = with_local_catalog do
      Nokogiri::XML(text) { |config| config.default_xml.strict.nonet.dtdload }
    end
    raise Unsafe, 'not well-formed XML' unless doc&.root

    reject_undefined_entities!(doc)
    # DTD defaults would put the XHTML namespace back on html. Namespaces
    # come from this parse. The DTD parse above is only for entities.
    ns_doc = Nokogiri::XML(text) { |config| config.default_xml.strict.nonet }
    raise Unsafe, 'not well-formed XML' unless ns_doc&.root

    tokens = []
    walk_document(doc, ns_doc, tokens)
    [doc, tokens, raw_declaration(text)]
  rescue Nokogiri::XML::SyntaxError => error
    message = error.message.strip
    name = message[/Entity '([^']+)' not defined/, 1]
    raise Unsafe, "undefined entity &#{name};" if name

    raise Unsafe, "not well-formed XML: #{message}"
  end

  # The catalog maps the XHTML public and system ids onto dtd/ beside this
  # repository. Relative entity files then resolve next to the DTD. NONET
  # blocks a network fetch when the catalog does not match.
  def with_local_catalog
    install_local_catalog
    path = catalog_path
    previous = ENV['XML_CATALOG_FILES']
    ENV['XML_CATALOG_FILES'] = path if path
    yield
  ensure
    if path
      if previous
        ENV['XML_CATALOG_FILES'] = previous
      else
        ENV.delete('XML_CATALOG_FILES')
      end
    end
  end

  # Set the catalog before the first DTD parse, and load it into an
  # already initialized libxml2 catalog. xmlLoadCatalog adds the file even
  # when an earlier parse initialized the catalog from a missing DTD.
  # Each call adds the file again. libxml2 keeps the first match, so a
  # repeated add does not replace the local DTD.
  def install_local_catalog
    path = catalog_path
    return unless path

    ENV['XML_CATALOG_FILES'] = path unless @catalog_installed
    load_xml_catalog(path)
    @catalog_installed = true
  end

  def load_xml_catalog(path)
    function = xml_load_catalog
    return unless function

    function.call(path)
  rescue StandardError
    nil
  end

  def xml_load_catalog
    return @xml_load_catalog if defined?(@xml_load_catalog)

    lib = nokogiri_libxml
    symbol = lib && lib['xmlLoadCatalog']
    @xml_load_catalog = symbol && Fiddle::Function.new(symbol, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  rescue StandardError
    @xml_load_catalog = nil
  end

  # Packaged libxml2 has no libxml2.so of its own. The symbols are in the
  # mapped Nokogiri extension. A separate libxml2.so is used when present.
  def nokogiri_libxml
    return @nokogiri_libxml if defined?(@nokogiri_libxml)

    @nokogiri_libxml = mapped_xml_library
  end

  def mapped_xml_library
    paths = []
    File.foreach('/proc/self/maps') do |row|
      path = row.split.last
      next unless path&.end_with?('.so')
      next unless path.include?('libxml2') || path.end_with?('nokogiri.so')

      paths << path
    end
    paths.uniq.each do |path|
      lib = Fiddle.dlopen(path)
      return lib if lib['xmlLoadCatalog']
    rescue StandardError
      next
    end
    nil
  rescue StandardError
    nil
  end

  def catalog_path
    path = File.expand_path('../dtd/catalog.xml', __dir__)
    path if File.file?(path)
  end

  def reject_undefined_entities!(doc)
    names = undefined_entity_names(doc)
    return if names.empty?

    listed = names.map { |name| "&#{name};" }.join(', ')
    raise Unsafe, "undefined entity #{listed}"
  end

  # The declaration is the raw text. Parsed version and encoding hide
  # standalone, a missing encoding, and quote or space differences.
  def raw_declaration(text)
    source = text.delete_prefix("\uFEFF")
    match = source.match(/\A<\?xml\b.*?\?>/m)
    match && match[0]
  end

  def walk_document(doc, ns_doc, tokens)
    pair_nodes(doc.children, ns_doc.children, tokens, false, false, skip_blank: true)
  end

  def pair_nodes(children, ns_children, tokens, region, inline_ancestor, skip_blank: false)
    left = listed_nodes(children, skip_blank)
    right = listed_nodes(ns_children, skip_blank)
    unless left.length == right.length
      raise Unsafe, 'namespace parse diverged'
    end

    left.each_with_index do |child, index|
      take_node(child, right[index], tokens, region, inline_ancestor)
    end
  end

  def listed_nodes(nodes, skip_blank)
    nodes.reject { |child|
      child.is_a?(Nokogiri::XML::DTD) ||
        (skip_blank && child.text? && child.content.match?(/\A[ \t\n\r\f]*\z/))
    }
  end

  def walk(element, ns_element, tokens, verbatim, inline_ancestor)
    raise Unsafe, 'namespace parse diverged' unless same_node?(element, ns_element)

    inside_inline = inline_ancestor || inline?(element)
    region = verbatim || verbatim?(element) || (block?(element) && inline_ancestor)
    first_edge = inline_edge(element, :first)
    last_edge = inline_edge(element, :last)
    tokens << start_token(element, ns_element, region, first_edge, last_edge)
    pair_nodes(element.children, ns_element.children, tokens, region, inside_inline)
    tokens << [
      :end, cached_name(element), element_kind(element), nil, region, href_of(element.namespace),
      last_edge
    ]
  end

  def take_node(node, ns_node, tokens, region, inline_ancestor)
    raise Unsafe, 'namespace parse diverged' unless same_node?(node, ns_node)

    if node.element?
      child_region = region || verbatim?(node) || (block?(node) && inline_ancestor)
      walk(node, ns_node, tokens, child_region, inline_ancestor)
    elsif node.text? || node.cdata?
      take_text(node, tokens, region, node.cdata?)
    elsif node.is_a?(Nokogiri::XML::EntityReference)
      tokens << [:entity, node.name, node.content.to_s]
    elsif node.comment?
      tokens << [:comment, node.content]
    elsif node.processing_instruction?
      tokens << [:pi, node.name, node.content]
    end
  end

  def same_node?(node, other)
    return false unless other
    if node.element?
      other.element? && other.name == node.name
    elsif node.cdata?
      other.cdata?
    elsif node.text?
      other.text? && !other.cdata?
    elsif node.is_a?(Nokogiri::XML::EntityReference)
      other.is_a?(Nokogiri::XML::EntityReference) && other.name == node.name
    elsif node.comment?
      other.comment?
    elsif node.processing_instruction?
      other.processing_instruction? && other.name == node.name
    else
      node.class == other.class
    end
  end

  def take_text(node, tokens, region, cdata)
    raw = node.content
    return if raw.empty?
    if region || cdata
      tokens << [:vtext, raw]
      return
    end
    if raw.match?(/\A[ \t\n\r\f]*\z/)
      append_ws(tokens, node, raw, nil, nil)
      return
    end
    if raw.ascii_only?
      lead = edge_pair(node, raw, :first)
      trail = edge_pair(node, raw, :last)
      if (lead.nil? || !HtmlInlineNeighbors.fixed_inline_run?(*lead)) &&
         (trail.nil? || !HtmlInlineNeighbors.fixed_inline_run?(*trail))
        emit_collapsed(tokens, raw, lead, trail)
        return
      end
    end

    parts = raw.split(/([ \t\n\r\f]+)/, -1)
    parts.each_with_index do |part, index|
      if index.even?
        tokens << [:text, part] unless part.empty?
      else
        append_ws(tokens, node, part, char_at(parts, index, -1), char_at(parts, index, 1))
      end
    end
  end

  # Statuses on one edge of an ASCII text node. nil when that edge has no
  # whitespace. The caller has already rejected a frozen edge.
  def edge_pair(node, raw, side)
    return nil unless HtmlInlineNeighbors.boundary_ws?(raw, side)

    if side == :first
      left = HtmlInlineNeighbors.neighbor_status(node, :before, self)
      right = HtmlInlineNeighbors.first_non_ws(raw) || HtmlInlineNeighbors.neighbor_status(node, :after, self)
    else
      left = HtmlInlineNeighbors.last_non_ws(raw) || HtmlInlineNeighbors.neighbor_status(node, :before, self)
      right = HtmlInlineNeighbors.neighbor_status(node, :after, self)
    end
    [left, right]
  end

  def emit_collapsed(tokens, raw, lead, trail)
    if lead.nil? && trail.nil?
      tokens << [:text, raw.match?(WS_RUN) ? raw.gsub(WS_RUN, ' ') : raw]
      return
    end

    tokens << [:ws, *lead] if lead
    core = raw.gsub(WS_RUN, ' ').strip
    tokens << [:text, core] unless core.empty?
    tokens << [:ws, *trail] if trail
  end

  def append_ws(tokens, node, run, left_inside, right_inside)
    left = left_inside || HtmlInlineNeighbors.neighbor_status(node, :before, self)
    right = right_inside || HtmlInlineNeighbors.neighbor_status(node, :after, self)
    if HtmlInlineNeighbors.fixed_inline_run?(left, right)
      tokens << [:fixed, run]
    else
      tokens << [:ws, left, right]
    end
  end

  def char_at(parts, index, direction)
    text = parts[index + direction]
    return nil if text.nil? || text.empty?

    direction.negative? ? text[-1] : text[0]
  end

  def newline_run?(run)
    run.include?("\n") || run.include?("\r")
  end

  # [:start, name, kind, attrs, region, uri, decls, container_free, first_edge, last_edge]
  # content_tokens keeps the first seven fields. The edges and container_free
  # are only for gap checks. An inline edge is the character inside the
  # element, or nil when the element is empty. A block stores nil there.
  def start_token(element, ns_element, region, first_edge, last_edge)
    [
      :start, cached_name(element), element_kind(element), attributes(element), region,
      href_of(element.namespace), namespace_decls(ns_element), container_free?(element),
      first_edge, last_edge
    ]
  end

  # The character an inline element presents to a gap. Other kinds do not
  # need one: the kind itself is the boundary.
  def inline_edge(element, side)
    return nil unless element_kind(element) == :inline

    HtmlInlineNeighbors.read_status(element, side, self)
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
    return :hidden if HtmlInlineNeighbors.hidden_element?(element)
    return :block if (bits & G_BLOCK) != 0
    return :verbatim if (bits & G_VERBATIM) != 0

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

  # Declarations from the parse that did not apply DTD defaults. The XHTML
  # DTD fixes xmlns on html, so the DTD parse cannot show that it was removed.
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

  def undefined_entity_names(doc)
    entity_warnings(doc).filter_map { |text| text[/Entity '([^']+)' not defined/, 1] }
  end

  # Drop presence-only whitespace. A frozen inline run (:fixed) stays,
  # because its bytes must match. Also drop the container flag.
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
    elsif %i[text vtext entity fixed].include?(left_here[0]) || %i[text vtext entity fixed].include?(right_here[0])
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

  # Each gap is [left, right, ws, parent, verbatim, ws_token].
  # ws_token is nil when this side has no whitespace there. Its fields are
  # the neighbor statuses the formatter and the guard both use.
  def gaps(tokens)
    found = []
    stack = []
    previous = nil
    pending = nil
    verbatim_depth = 0
    tokens.each do |token|
      if token[0] == :ws
        pending = token
        next
      end
      if previous
        found << [previous, token, !pending.nil?, stack.last, verbatim_depth.positive?, pending]
      end
      pending = nil
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
    parent = gap[3]
    ws = gap[5]
    if ws
      left_status = ws[1]
      right_status = ws[2]
    else
      left_status = token_status(left, :right)
      right_status = token_status(right, :left)
    end
    HtmlInlineNeighbors.boundary_gap_free?(
      left && left[0] == :end && left[2] == :block,
      right && right[0] == :start && right[2] == :block,
      after_br: br_edge?(left),
      container: parent && parent[7],
      left_status: left_status,
      right_status: right_status
    )
  end

  # The status a content token presents to the gap on :left or :right.
  # A block or a br is that boundary. An empty inline element has no
  # character. A hidden element contributes nothing. Anything else that is
  # not a safe character fails closed.
  def token_status(token, side)
    return nil unless token

    case token[0]
    when :text
      text = token[1].to_s
      return nil if text.empty?

      side == :right ? text[-1] : text[0]
    when :entity
      text = token[2].to_s
      char = side == :right ? HtmlInlineNeighbors.last_non_ws(text) : HtmlInlineNeighbors.first_non_ws(text)
      char || :entity
    when :end
      kind_status(token[2], token[6])
    when :start
      kind_status(token[2], token[8])
    when :vtext, :fixed
      :verbatim
    else
      nil
    end
  end

  def kind_status(kind, inner)
    case kind
    when :block then :block
    when :br then :br
    when :verbatim then :verbatim
    when :hidden then nil
    else inner
    end
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
    when :fixed
      newline_run?(token[1]) ? 'a line break' : 'a space'
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

HtmlWhitespaceGuard.install_local_catalog

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
