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
# hidden element never makes a gap free. An uncertain element freezes the
# runs on both sides, the same way a verbatim element does.
#
# The comparison covers the raw XML declaration, the doctype and the text
# of its internal subset, the order of comments and processing instructions
# around the doctype, and comments, processing instructions, and entity
# references in the text. The guard loads the same local XHTML DTD as the
# formatter, through the catalog, and does not use the network. That parse
# is only for entities. The XHTML DTD fixes the namespace on html. When the
# root tag in the text declares the same namespace the DTD tree shows, the
# walk uses that tree and does not open a second parser. A different root
# tag, or a tag the scan cannot read, uses a streaming read for every
# element. That read does not build a second tree. An undefined entity
# anywhere in the page is an error, and the message names it.
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
  # Mutable whitespace shares one object. A fixed run keeps its own bytes.
  WS_TOKEN = [:ws].freeze
  # Most elements declare no namespace. One frozen list stands for all of them.
  EMPTY_DECLS = [].freeze
  # The root tag of a book page is in the first few hundred bytes. A longer
  # prolog falls back to the pull parser instead of scanning the whole page.
  ROOT_SCAN_LIMIT = 65_536
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
    # The fixed xmlns on html is the DTD default that can hide a change.
    # A matching root tag means the DTD tree already shows the source
    # namespaces, so the walk does not build a sketch. A different tag uses
    # the pull parser, which stops before any descendant is expanded.
    cursor = namespace_cursor_for(text, doc)
    tokens = []
    walk_document(doc, cursor, tokens)
    raise Unsafe, 'namespace parse diverged' if cursor && !cursor.done?
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

  # Namespaces and a structural sketch from a pull parser. No second tree.
  class NsCursor
    def initialize(shape, records)
      @shape = shape.freeze
      @records = records.freeze
      @si = 0
      @ri = 0
    end

    def done?
      @si == @shape.length && @ri == @records.length
    end

    def expect(kind)
      got = @shape[@si]
      @si += 1
      raise Unsafe, 'namespace parse diverged' unless got == kind
    end

    def take_record
      record = @records[@ri]
      @ri += 1
      raise Unsafe, 'namespace parse diverged' unless record

      record
    end
  end

  # Same node order as a document that was not given the external DTD.
  # Blank text is skipped only at the top level. An empty element has no
  # end event, so the sketch supplies one. Node types are libxml2's.
  #
  # This uses libxml's pull parser directly. Nokogiri's Reader#namespaces
  # expands the current element and every descendant, which keeps a second
  # tree alive. Attribute reads do not. The reader is freed before the
  # method returns, and before the token walk.
  def with_namespace_reader(text)
    options = Nokogiri::XML::ParseOptions.new.default_xml.strict.nonet.to_i
    reader = nil
    reader = libxml_fn(
      'xmlReaderForMemory',
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
      Fiddle::TYPE_VOIDP
    ).call(text, text.bytesize, nil, nil, options)
    raise Unsafe, 'not well-formed XML' if reader_null?(reader)

    silence_reader(reader)
    yield reader
  ensure
    libxml_fn('xmlFreeTextReader', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID).call(reader) if reader && !reader_null?(reader)
  end

  # nil when the root tag matches the DTD tree. The pull parser runs only
  # when the tag differs, or when the scan cannot read it.
  def namespace_cursor_for(text, doc)
    dtd = dtd_namespace_record(doc.root)
    source = source_root_namespace(text)
    source = read_root_namespace(text) if source.nil?
    return nil if source == dtd

    namespace_cursor(text)
  end

  # The root start tag, read from the text. nil when the prolog is too
  # large or the tag is not a plain quoted start tag. The caller then uses
  # the pull parser. A match avoids opening that parser on an ordinary page.
  def source_root_namespace(text)
    source = text.delete_prefix("\uFEFF")
    limit = [source.length, ROOT_SCAN_LIMIT].min
    index = 0
    if source.start_with?('<?xml')
      index = source.index('?>', index)
      return nil unless index && index < limit

      index += 2
    end
    while index < limit
      index += 1 while index < limit && xml_space?(source[index])
      break if index >= limit

      if starts_at?(source, index, '<!--')
        index = source.index('-->', index)
        return nil unless index && index < limit

        index += 3
      elsif starts_at?(source, index, '<?')
        index = source.index('?>', index)
        return nil unless index && index < limit

        index += 2
      elsif starts_at?(source, index, '<!DOCTYPE')
        index = skip_doctype(source, index, limit)
        return nil unless index
      elsif source[index] == '<'
        return root_tag_namespace(source, index, limit)
      else
        return nil
      end
    end
    nil
  end

  def starts_at?(source, index, text)
    source[index, text.length] == text
  end

  def xml_space?(char)
    char == ' ' || char == "\n" || char == "\t" || char == "\r" || char == "\f"
  end

  def skip_doctype(source, index, limit)
    quote = nil
    depth = 0
    while index < limit
      char = source[index]
      if quote
        quote = nil if char == quote
      elsif char == '"' || char == "'"
        quote = char
      elsif char == '['
        depth += 1
      elsif char == ']'
        depth -= 1
      elsif char == '>' && depth.zero?
        return index + 1
      end
      index += 1
    end
    nil
  end

  # [uri, decls] for the root element, or nil when the tag is not plain.
  def root_tag_namespace(source, index, limit)
    return nil unless source[index] == '<'

    index += 1
    name_at = index
    index += 1 while index < limit && !xml_space?(source[index]) && source[index] != '>' && source[index] != '/'
    return nil if index == name_at || index >= limit

    name = source[name_at...index]
    return nil if name.include?('<') || name.include?('&')

    decls = []
    while index < limit
      index += 1 while index < limit && xml_space?(source[index])
      break if index >= limit || source[index] == '>' || source[index] == '/'

      name_at = index
      index += 1 while index < limit && source[index] != '=' && !xml_space?(source[index]) && source[index] != '>' && source[index] != '/'
      attr = source[name_at...index]
      return nil if attr.empty?
      index += 1 while index < limit && xml_space?(source[index])
      return nil if index >= limit || source[index] != '='

      index += 1
      index += 1 while index < limit && xml_space?(source[index])
      return nil if index >= limit

      quote = source[index]
      return nil unless quote == '"' || quote == "'"

      value_at = index + 1
      index = source.index(quote, value_at)
      return nil unless index && index < limit

      value = source[value_at...index]
      return nil if value.include?('&') || value.include?('<')

      index += 1
      if attr == 'xmlns'
        decls << [nil, value]
      elsif attr.start_with?('xmlns:') && attr.length > 6
        decls << [attr.delete_prefix('xmlns:'), value]
      end
    end
    return nil if index >= limit

    prefix, = name.split(':', 2) if name.include?(':')
    found = prefix ? decls.find { |declared, _href| declared == prefix } : decls.find { |declared, _href| declared.nil? }
    uri = found && found[1]
    listed = decls.empty? ? EMPTY_DECLS : decls.map { |declared, href| [shared_string(declared), shared_string(href)] }
    namespace_record(shared_string(uri), listed)
  end

  # The root only. Used when the text scan cannot read the root tag.
  # The reader is freed before the caller walks the document.
  def read_root_namespace(text)
    with_namespace_reader(text) do |reader|
      read = libxml_fn('xmlTextReaderRead', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      node_type = libxml_fn('xmlTextReaderNodeType', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      ns_uri = libxml_fn('xmlTextReaderConstNamespaceUri', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      while read.call(reader) == 1
        next unless node_type.call(reader) == 1

        return namespace_record(
          shared_string(reader_cstr(ns_uri.call(reader))),
          reader_attribute_decls(reader)
        )
      end
      raise Unsafe, 'not well-formed XML'
    end
  end

  def read_namespaces(text)
    shape = []
    records = []
    status = nil
    with_namespace_reader(text) do |reader|
      read = libxml_fn('xmlTextReaderRead', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      node_type = libxml_fn('xmlTextReaderNodeType', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      depth = libxml_fn('xmlTextReaderDepth', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      local_name = libxml_fn('xmlTextReaderConstLocalName', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      const_name = libxml_fn('xmlTextReaderConstName', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      ns_uri = libxml_fn('xmlTextReaderConstNamespaceUri', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      empty_element = libxml_fn('xmlTextReaderIsEmptyElement', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      const_value = libxml_fn('xmlTextReaderConstValue', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      while (status = read.call(reader)) == 1
        case node_type.call(reader)
        when 1
          shape << :element << shared_string(reader_cstr(local_name.call(reader)))
          records << namespace_record(
            shared_string(reader_cstr(ns_uri.call(reader))),
            reader_attribute_decls(reader)
          )
          shape << :end if empty_element.call(reader) == 1
        when 15
          shape << :end
        when 4
          shape << :cdata
        when 3, 13, 14
          if depth.call(reader).zero?
            value = reader_cstr(const_value.call(reader)).to_s
            next if value.match?(/\A[ \t\n\r\f]*\z/)
          end
          shape << :text
        when 5
          shape << :entity << reader_cstr(const_name.call(reader))
        when 8
          shape << :comment
        when 7
          shape << :pi << reader_cstr(local_name.call(reader))
        when 9, 10, 16, 17
          next
        else
          shape << :other
        end
      end
    end
    raise Unsafe, 'not well-formed XML' unless status&.zero?

    [shape, records]
  end

  # One record object for every element that only inherits a namespace.
  # The tokens keep the href and the declaration list, and compare them by value.
  def namespace_record(uri, decls)
    return [uri, decls] unless decls.equal?(EMPTY_DECLS)

    (@plain_ns ||= {})[uri] ||= [uri, EMPTY_DECLS].freeze
  end

  def reader_attribute_decls(reader)
    fns = attribute_reader_fns
    count = fns[:count].call(reader)
    return EMPTY_DECLS if count.to_i <= 0

    decls = nil
    moved = false
    count.to_i.times do |index|
      next unless fns[:move].call(reader, index) == 1

      moved = true
      name = reader_cstr(fns[:name].call(reader))
      next unless name == 'xmlns' || (name && name.start_with?('xmlns:'))

      prefix = name == 'xmlns' ? nil : name.delete_prefix('xmlns:')
      (decls ||= []) << [shared_string(prefix), shared_string(reader_cstr(fns[:value].call(reader)))]
    end
    fns[:back].call(reader) if moved
    decls || EMPTY_DECLS
  end

  def attribute_reader_fns
    @attribute_reader_fns ||= {
      count: libxml_fn('xmlTextReaderAttributeCount', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT),
      move: libxml_fn('xmlTextReaderMoveToAttributeNo', [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT),
      name: libxml_fn('xmlTextReaderConstName', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP),
      value: libxml_fn('xmlTextReaderConstValue', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP),
      back: libxml_fn('xmlTextReaderMoveToElement', [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
    }
  end

  def reader_cstr(ptr)
    return nil if reader_null?(ptr)

    pointer = ptr.is_a?(Fiddle::Pointer) ? ptr : Fiddle::Pointer.new(ptr.to_i)
    return nil if pointer.null?

    pointer.to_s
  end

  # The namespace read does not load the DTD, so an entity that the DTD
  # defines is unknown here. The DTD parse already reported real errors.
  # A handler keeps those warnings off stderr. The closure has to stay
  # alive for the process, or libxml calls a freed address.
  def silence_reader(reader)
    @reader_error_handler ||= Fiddle::Closure::BlockCaller.new(
      Fiddle::TYPE_VOID,
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP]
    ) { |*| }
    @reader_structured_handler ||= Fiddle::Closure::BlockCaller.new(
      Fiddle::TYPE_VOID,
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
    ) { |*| }
    libxml_fn(
      'xmlTextReaderSetErrorHandler',
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
      Fiddle::TYPE_VOID
    ).call(reader, @reader_error_handler, nil)
    libxml_fn(
      'xmlTextReaderSetStructuredErrorHandler',
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
      Fiddle::TYPE_VOID
    ).call(reader, @reader_structured_handler, nil)
  end

  def reader_null?(ptr)
    ptr.nil? || (ptr.respond_to?(:null?) && ptr.null?) || (ptr.is_a?(Integer) && ptr.zero?)
  end

  def libxml_fn(name, args, result)
    @libxml_fns ||= {}
    @libxml_fns[[name, args, result]] ||= begin
      symbol = nokogiri_libxml && nokogiri_libxml[name]
      raise Unsafe, 'namespace reader is unavailable' unless symbol

      Fiddle::Function.new(symbol, args, result)
    end
  end

  def namespace_cursor(text)
    shape, records = read_namespaces(text)
    NsCursor.new(shape, records)
  end

  def walk_document(doc, cursor, tokens)
    walk_children(doc.children, cursor, tokens, false, false, skip_blank: true)
  end

  def walk_children(children, cursor, tokens, region, inline_ancestor, skip_blank: false)
    children.each do |child|
      next if child.is_a?(Nokogiri::XML::DTD)
      next if skip_blank && child.text? && child.content.match?(/\A[ \t\n\r\f]*\z/)

      take_node(child, cursor, tokens, region, inline_ancestor)
    end
  end

  def walk(element, cursor, tokens, verbatim, inline_ancestor)
    note(cursor, :element)
    name = cached_name(element)
    note(cursor, name)
    record = cursor ? cursor.take_record : dtd_namespace_record(element)
    inside_inline = inline_ancestor || inline?(element)
    region = verbatim || verbatim?(element) || (block?(element) && inline_ancestor)
    kind = element_kind(element)
    tokens << start_token(element, record, region, kind)
    walk_children(element.children, cursor, tokens, region, inside_inline)
    note(cursor, :end)
    tokens << [:end, name, kind, nil, region, record[0]]
  end

  def take_node(node, cursor, tokens, region, inline_ancestor)
    if node.element?
      child_region = region || verbatim?(node) || (block?(node) && inline_ancestor)
      walk(node, cursor, tokens, child_region, inline_ancestor)
    elsif node.cdata?
      note(cursor, :cdata)
      take_text(node, tokens, region, true)
    elsif node.text?
      note(cursor, :text)
      take_text(node, tokens, region, false)
    elsif node.is_a?(Nokogiri::XML::EntityReference)
      note(cursor, :entity)
      note(cursor, node.name)
      tokens << [:entity, node.name, node.content.to_s]
    elsif node.comment?
      note(cursor, :comment)
      tokens << [:comment, node.content]
    elsif node.processing_instruction?
      note(cursor, :pi)
      note(cursor, node.name)
      tokens << [:pi, node.name, node.content]
    else
      note(cursor, :other)
    end
  end

  def note(cursor, kind)
    cursor.expect(kind) if cursor
  end

  def take_text(node, tokens, region, cdata)
    raw = node.content
    return if raw.empty?
    # A verbatim region stays one opaque string. CDATA outside one is still
    # characters, so a neighbor can see them. Treating it as verbatim would
    # freeze runs that are only next to ordinary text.
    if region
      tokens << [:vtext, raw]
      return
    end
    if cdata
      tokens << [:cdata, raw]
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

    tokens << WS_TOKEN if lead
    core = raw.gsub(WS_RUN, ' ').strip
    tokens << [:text, core] unless core.empty?
    tokens << WS_TOKEN if trail
  end

  def append_ws(tokens, node, run, left_inside, right_inside)
    left = left_inside || HtmlInlineNeighbors.neighbor_status(node, :before, self)
    right = right_inside || HtmlInlineNeighbors.neighbor_status(node, :after, self)
    if HtmlInlineNeighbors.fixed_inline_run?(left, right)
      tokens << [:fixed, run]
    else
      tokens << WS_TOKEN
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

  # [:start, name, kind, attrs, region, uri, decls, container_free]
  # content_tokens keeps the first seven fields. container_free is only for
  # gap checks. record is [href, decls]. Inline edges are not stored. A page
  # has one start token per element, and a gap asks for an edge only when
  # whitespace appeared or disappeared there.
  def start_token(element, record, region, kind)
    [
      :start, cached_name(element), kind, attributes(element), region,
      record[0], record[1], container_free?(element)
    ]
  end

  # The status the first or last child token presents. nil means look past.
  # A hidden element is skipped as a whole. An uncertain element, a verbatim
  # element, a block, and a br stop the walk. An inline element is entered.
  def token_edge(tokens, from, to, side)
    step = side == :first ? 1 : -1
    index = side == :first ? from : to - 1
    while index >= from && index < to
      token = tokens[index]
      case token[0]
      when :ws, :fixed, :comment, :pi
        index += step
      when :text
        text = token[1]
        char = step.positive? ? text[0] : text[-1]
        return char if char
        index += step
      when :cdata
        text = token[1]
        char = step.positive? ? HtmlInlineNeighbors.first_non_ws(text) : HtmlInlineNeighbors.last_non_ws(text)
        return char if char
        return (step.positive? ? text[0] : text[-1]) unless text.empty?
        index += step
      when :vtext
        return :verbatim
      when :entity
        text = token[2].to_s
        char = step.positive? ? HtmlInlineNeighbors.first_non_ws(text) : HtmlInlineNeighbors.last_non_ws(text)
        return char if char
        index += step
      when :start
        if step.negative?
          index += step
        else
          kind = token[2]
          if kind == :hidden
            index = skip_forward(tokens, index)
          elsif kind == :inline || kind.nil?
            index += 1
          else
            return kind
          end
        end
      when :end
        if step.positive?
          index += step
        else
          kind = token[2]
          if kind == :hidden
            index = skip_backward(tokens, index)
          elsif kind == :inline || kind.nil?
            index -= 1
          else
            return kind
          end
        end
      else
        index += step
      end
    end
    nil
  end

  def skip_forward(tokens, index)
    depth = 0
    limit = tokens.length
    i = index
    while i < limit
      case tokens[i][0]
      when :start
        depth += 1
      when :end
        depth -= 1
        return i + 1 if depth.zero?
      end
      i += 1
    end
    limit
  end

  def skip_backward(tokens, index)
    depth = 0
    i = index
    while i >= 0
      case tokens[i][0]
      when :end
        depth += 1
      when :start
        depth -= 1
        return i - 1 if depth.zero?
      end
      i -= 1
    end
    -1
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
    # Hidden and uncertain come before br and block. A hidden br is not a
    # br boundary, and an hr or an h3 is not a visible block.
    return :hidden if HtmlInlineNeighbors.hidden_element?(element)
    return :uncertain if HtmlInlineNeighbors.uncertain_element?(element)
    return :br if (bits & G_BR) != 0
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

  # Declarations on this element. Empty lists share one object so a page of
  # ordinary elements does not allocate a list per element.
  def namespace_decls(element)
    defs = element.namespace_definitions
    return EMPTY_DECLS if defs.empty?

    defs.map { |ns| [shared_string(ns.prefix), href_of(ns)] }
  end

  def dtd_namespace_record(element)
    namespace_record(href_of(element.namespace), namespace_decls(element))
  end

  def attributes(element)
    element.attribute_nodes.map { |attr|
      href = href_of(attr.namespace)
      next if href == XMLNS
      [href, attr.name, attr.value]
    }.compact
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
    elsif %i[text vtext cdata entity fixed].include?(left_here[0]) || %i[text vtext cdata entity fixed].include?(right_here[0])
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
      next if !strict && free_gap?(gap, left_tokens)
      verb = other[2] ? 'ADDED  ' : 'REMOVED'
      problems << "#{verb} between #{label(gap[0])} and #{label(gap[1])}"
    end
    problems
  end

  # Each gap is [left, right, present, parent, verbatim, left_index, right_index].
  # Statuses are computed only when a gap's presence differs. A shared :ws
  # token carries none.
  def gaps(tokens)
    found = []
    stack = []
    previous = nil
    prev_index = nil
    pending = false
    verbatim_depth = 0
    tokens.each_with_index do |token, index|
      if token[0] == :ws
        pending = true
        next
      end
      if previous
        found << [previous, token, pending, stack.last, verbatim_depth.positive?, prev_index, index]
      end
      pending = false
      previous = token
      prev_index = index
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

  def free_gap?(gap, tokens)
    return false if gap[4]

    left = gap[0]
    right = gap[1]
    parent = gap[3]
    left_status = token_status(tokens, gap[5], :right)
    right_status = token_status(tokens, gap[6], :left)
    left_status = left_neighbor_status(tokens, gap[5]) if left_status.nil?
    right_status = right_neighbor_status(tokens, gap[6]) if right_status.nil?
    HtmlInlineNeighbors.boundary_gap_free?(
      left && left[0] == :end && left[2] == :block,
      right && right[0] == :start && right[2] == :block,
      after_br: br_edge?(left),
      container: parent && parent[7],
      left_status: left_status,
      right_status: right_status
    )
  end

  # Status of the content token at index, looking through a hidden element
  # or an empty inline. Those are not boundaries. The walk skips the whole
  # element, so text inside a hidden element is not a neighbor.
  def left_neighbor_status(tokens, index)
    i = index
    while i >= 0
      token = tokens[i]
      if token[0] == :ws
        i -= 1
        next
      end
      status = token_status(tokens, i, :right)
      return status unless status.nil?
      i = token[0] == :end && (token[2] == :hidden || token[2] == :inline) ? skip_backward(tokens, i) : i - 1
    end
    nil
  end

  def right_neighbor_status(tokens, index)
    i = index
    limit = tokens.length
    while i < limit
      token = tokens[i]
      if token[0] == :ws
        i += 1
        next
      end
      status = token_status(tokens, i, :left)
      return status unless status.nil?
      i = token[0] == :start && (token[2] == :hidden || token[2] == :inline) ? skip_forward(tokens, i) : i + 1
    end
    nil
  end

  # The status a content token presents to the gap on :left or :right.
  # A block or a br is that boundary. An empty inline element has no
  # character. A hidden element contributes nothing. Anything else that is
  # not a safe character fails closed.
  def token_status(tokens, index, side)
    token = tokens[index]
    return nil unless token

    case token[0]
    when :text
      text = token[1].to_s
      return nil if text.empty?

      side == :right ? text[-1] : text[0]
    when :cdata
      text = token[1].to_s
      return nil if text.empty?

      char = side == :right ? HtmlInlineNeighbors.last_non_ws(text) : HtmlInlineNeighbors.first_non_ws(text)
      return char if char

      side == :right ? text[-1] : text[0]
    when :entity
      text = token[2].to_s
      char = side == :right ? HtmlInlineNeighbors.last_non_ws(text) : HtmlInlineNeighbors.first_non_ws(text)
      char || :entity
    when :start, :end
      element_status(tokens, index)
    when :vtext, :fixed
      :verbatim
    else
      nil
    end
  end

  # What an element presents to a gap beside it. A block, a br, a verbatim
  # element, and an uncertain element are that boundary. A hidden element
  # presents nothing. An inline element presents the child status on the
  # side that faces the gap, and an empty inline presents nothing.
  def element_status(tokens, index)
    token = tokens[index]
    case token[2]
    when :block, :br, :verbatim, :uncertain
      token[2]
    when :hidden
      nil
    else
      if token[0] == :start
        finish = skip_forward(tokens, index)
        token_edge(tokens, index + 1, finish - 1, :first)
      else
        start = skip_backward(tokens, index)
        token_edge(tokens, start + 2, index, :last)
      end
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
    when :text, :vtext, :cdata
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
