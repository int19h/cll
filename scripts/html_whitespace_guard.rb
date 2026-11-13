# frozen_string_literal: true

# Compare two XHTML texts and refuse an unsafe whitespace change (issue #207).
#
# The guard parses each text on its own. It does not call the formatter.
# A whitespace run may appear or disappear only at a free gap. While the
# guard builds tokens, HtmlInlineNeighbors decides whether a run is fixed
# and which characters count as safe. That is the same module the
# formatter uses, including fixed_inline_run? and boundary_gap_free?.
# The statuses that later accept or refuse a gap are a second walk, over
# the guard's own tokens (token_edge, left_neighbor_status,
# right_neighbor_status). That walk has to stay at least as strict as the
# shared one. A whitespace-only CDATA section is an unsafe character here,
# and an empty entity is :entity. Both refuse a change the shared walk can
# allow. The guard must not accept a change the formatter keeps.
# An inline run may change between a space and a line break only when the
# shared module says both sides are safe. A block edge, a visible br, and
# a free gap may reshape a run only when the inline character is safe or
# absent. Every other inline run must match byte for byte. Inside a
# verbatim element the text must match byte for byte. The gap after a br
# is never free, and a hidden element never makes a gap free. An uncertain
# element freezes the runs on both sides, the same way a verbatim element
# does.
#
# The comparison covers the raw XML declaration, the doctype and the text
# of its internal subset, the order of comments and processing instructions
# around the doctype, and comments, processing instructions, and entity
# references in the text. The guard loads the same local XHTML DTD as the
# formatter, through the catalog, and does not use the network. That parse
# is only for entities. The XHTML DTD fixes the namespace on every html
# element, including one nested inside another namespace. Every element is
# therefore compared with a byte scan that does not load the DTD and does
# not build a second tree. The scan does not apply that fixed xmlns. An undefined entity anywhere in the page
# is an error, and the message names it.
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
  # Character references and these names are expanded in namespace values.
  # Any other name has to be declared in the document's internal subset.
  PREDEFINED_ENTITIES = {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'apos' => "'",
    'quot' => '"'
  }.freeze
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
    # The DTD fixes xmlns on every html element. The byte scan does not
    # load that DTD, so a nested html keeps the namespace of its parent.
    cursor = namespace_cursor_for(text)
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

  # Element names and namespace records, in document order. Text, comments,
  # and entity references are not stored: the token walk checks element
  # names as it goes, and a mismatch or a leftover element is a divergence.
  class NsCursor
    def initialize(flat)
      @flat = flat
      @i = 0
      @depth = 0
      @want_name = false
      @record = nil
    end

    def done?
      @i == @flat.length && @depth == 0 && !@want_name && @record.nil?
    end

    def expect(kind)
      if @want_name
        @want_name = false
        raise Unsafe, 'namespace parse diverged' unless kind == @flat[@i]

        @record = @flat[@i + 1]
        @i += 2
        return
      end
      case kind
      when :element
        raise Unsafe, 'namespace parse diverged' if @i >= @flat.length

        @want_name = true
        @depth += 1
      when :end
        @depth -= 1
        raise Unsafe, 'namespace parse diverged' if @depth < 0
      end
    end

    def take_record
      record = @record
      @record = nil
      raise Unsafe, 'namespace parse diverged' unless record

      record
    end
  end

  # Every element, from a parse that does not load the DTD. A nil cursor
  # would fall back to the DTD tree and hide a nested html, so the caller
  # always receives one. The sketch is finished before the token walk.
  def namespace_cursor_for(text)
    namespace_cursor(text)
  end

  def ascii_word?(raw, start, word)
    return false unless raw.bytesize >= start + word.bytesize

    word.each_byte.with_index.all? { |expected, offset|
      found = raw.getbyte(start + offset)
      found && (found | 0x20) == (expected | 0x20)
    }
  end

  def skip_doctype(raw, start)
    i = start + 9
    length = raw.bytesize
    while i < length
      byte = raw.getbyte(i)
      if byte == 0x5B
        return subset_end(raw, i + 1)
      elsif byte == 0x3E
        return i + 1
      elsif byte == 0x22 || byte == 0x27
        stop = raw.index(byte.chr, i + 1)
        return length unless stop

        i = stop + 1
      elsif byte == 0x3C && raw.byteslice(i + 1, 3) == '!--'
        stop = raw.index('-->', i + 4)
        return length unless stop

        i = stop + 3
      else
        i += 1
      end
    end
    length
  end

  # Position after the doctype's closing '>'. The subset ends at ']>'
  # outside a quote, a comment, or a processing instruction.
  def subset_end(raw, start)
    i = start
    length = raw.bytesize
    while i < length
      byte = raw.getbyte(i)
      if byte == 0x5D && raw.getbyte(i + 1) == 0x3E
        return i + 2
      elsif byte == 0x22 || byte == 0x27
        stop = raw.index(byte.chr, i + 1)
        return length unless stop

        i = stop + 1
      elsif byte == 0x3C && raw.byteslice(i + 1, 3) == '!--'
        stop = raw.index('-->', i + 4)
        return length unless stop

        i = stop + 3
      elsif byte == 0x3C && raw.getbyte(i + 1) == 0x3F
        stop = raw.index('?>', i + 2)
        return length unless stop

        i = stop + 2
      else
        i += 1
      end
    end
    length
  end

  def tag_boundary?(byte)
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C ||
      byte == 0x3E || byte == 0x2F
  end

  def tag_space?(byte)
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
  end

  # XML Namespaces binds this prefix in every document. A tag that declares
  # a prefix copies the map before it adds that binding.
  def base_prefixes
    @base_prefixes ||= { 'xml' => 'http://www.w3.org/XML/1998/namespace' }.freeze
  end

  def intern_local_name(raw, at, len)
    raise Unsafe, 'namespace parse diverged' if len <= 0

    if len <= 7
      key = 0
      n = 0
      while n < len
        key = (key << 8) | raw.getbyte(at + n)
        n += 1
      end
      return (@short_names ||= {})[key] ||= raw.byteslice(at, len).force_encoding(Encoding::UTF_8)
    end
    shared_string(raw.byteslice(at, len).force_encoding(Encoding::UTF_8))
  end

  def name_byte?(byte)
    return false if byte.nil?

    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
      (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x2D || byte == 0x2E ||
      byte == 0x3A || byte >= 0x80
  end

  def skip_ascii_space(raw, pos, limit)
    while pos < limit && tag_space?(raw.getbyte(pos))
      pos += 1
    end
    pos
  end

  def internal_entity_map(raw)
    map = {}
    i = 0
    while (i = raw.index('<!ENTITY', i))
      j = skip_ascii_space(raw, i + 8, raw.bytesize)
      if raw.getbyte(j) == 0x25
        i = declaration_end(raw, j)
        next
      end
      name_at = j
      j += 1 while name_byte?(raw.getbyte(j))
      raise Unsafe, 'namespace parse diverged' if j == name_at

      name = raw.byteslice(name_at, j - name_at).force_encoding(Encoding::UTF_8)
      j = skip_ascii_space(raw, j, raw.bytesize)
      quote = raw.getbyte(j)
      if quote == 0x22 || quote == 0x27
        close = raw.index(quote.chr, j + 1)
        raise Unsafe, 'namespace parse diverged' unless close

        map[name] = raw.byteslice(j + 1, close - j - 1).force_encoding(Encoding::UTF_8)
        i = declaration_end(raw, close + 1)
      else
        i = declaration_end(raw, j)
      end
    end
    map
  end

  def declaration_end(raw, pos)
    length = raw.bytesize
    while pos < length
      byte = raw.getbyte(pos)
      if byte == 0x3E
        return pos + 1
      elsif byte == 0x22 || byte == 0x27
        close = raw.index(byte.chr, pos + 1)
        return length unless close

        pos = close + 1
      else
        pos += 1
      end
    end
    length
  end

  def decode_attr_bytes(raw, from, to, entities)
    i = from
    while i < to
      byte = raw.getbyte(i)
      if byte == 0x26 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        binary = decode_attr_slow(raw, from, to, entities, [])
        return shared_string(binary.force_encoding(Encoding::UTF_8))
      end
      i += 1
    end
    shared_string(raw.byteslice(from, to - from).force_encoding(Encoding::UTF_8))
  end

  def decode_attr_slow(raw, from, to, entities, seen)
    out = String.new(encoding: Encoding::ASCII_8BIT)
    i = from
    while i < to
      byte = raw.getbyte(i)
      if byte == 0x26
        semi = raw.index(';'.b, i + 1)
        raise Unsafe, 'namespace parse diverged' unless semi && semi < to

        token = raw.byteslice(i + 1, semi - i - 1).force_encoding(Encoding::UTF_8)
        if token.start_with?('#')
          code = token.start_with?('#x', '#X') ? Integer(token[2..], 16) : Integer(token[1..], 10)
          append_codepoint(out, code)
        else
          out << expand_entity_bytes(token, entities, seen)
        end
        i = semi + 1
      elsif byte == 0x0D
        out << 0x20
        i += 1
        i += 1 if i < to && raw.getbyte(i) == 0x0A
      elsif byte == 0x0A || byte == 0x09
        out << 0x20
        i += 1
      else
        start = i
        i += 1
        while i < to
          nxt = raw.getbyte(i)
          break if nxt == 0x26 || nxt == 0x09 || nxt == 0x0A || nxt == 0x0D

          i += 1
        end
        out << raw.byteslice(start, i - start)
      end
    end
    out
  rescue ArgumentError
    raise Unsafe, 'namespace parse diverged'
  end

  def append_codepoint(out, code)
    if code < 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)
      raise Unsafe, 'namespace parse diverged'
    end

    out << code.chr(Encoding::UTF_8).b
  end

  def expand_entity_bytes(name, entities, seen)
    raise Unsafe, 'namespace parse diverged' if seen.include?(name) || seen.length > 32

    if entities&.key?(name)
      body = entities[name].b
      return decode_attr_slow(body, 0, body.bytesize, entities, seen + [name])
    end
    predefined = PREDEFINED_ENTITIES[name]
    raise Unsafe, 'namespace parse diverged' unless predefined

    predefined.b
  end

  def xmlns_attribute_prefix(raw, at, len)
    return :no if len < 5
    return :no unless raw.getbyte(at) == 0x78 && raw.byteslice(at, 5) == 'xmlns'

    return nil if len == 5
    return :no unless raw.getbyte(at + 5) == 0x3A && len > 6

    shared_string(raw.byteslice(at + 6, len - 6).force_encoding(Encoding::UTF_8))
  end

  def tag_finish(raw, start)
    pos = start + 1
    length = raw.bytesize
    while pos < length
      gt = raw.index('>', pos)
      return nil unless gt

      dq = raw.index('"', pos)
      sq = raw.index("'", pos)
      dq = length if dq.nil? || dq > gt
      sq = length if sq.nil? || sq > gt
      return gt if dq == length && sq == length

      qat = dq < sq ? dq : sq
      close = raw.index(dq < sq ? '"' : "'", qat + 1)
      return nil unless close

      pos = close + 1
    end
    nil
  end

  # Flat [local name, namespace record, ...]. The external DTD is not applied,
  # so a nested html keeps its parent's namespace. Tags that declare nothing
  # and use no prefix skip attribute parsing. xmlns offsets are collected once
  # so that search stays inside the tag.
  def scan_element_namespaces(raw)
    raw = raw.b
    entities = raw.include?('<!ENTITY') ? internal_entity_map(raw) : nil
    xmlns_at = []
    mark = 0
    while (mark = raw.index('xmlns', mark))
      xmlns_at << mark
      mark += 5
    end
    xmlns_i = 0
    flat = []
    scopes = []
    uri = nil
    prefixes = base_prefixes
    depth = 0
    length = raw.bytesize
    i = 0
    while (i = raw.index('<', i))
      kind = raw.getbyte(i + 1)
      if kind == 0x21
        if raw.byteslice(i + 2, 2) == '--'
          stop = raw.index('-->', i + 4)
          i = stop ? stop + 3 : length
        elsif raw.byteslice(i + 2, 7) == '[CDATA['
          stop = raw.index(']]>', i + 9)
          i = stop ? stop + 3 : length
        elsif ascii_word?(raw, i + 2, 'DOCTYPE')
          i = skip_doctype(raw, i)
        else
          stop = raw.index('>', i + 2)
          i = stop ? stop + 1 : length
        end
      elsif kind == 0x3F
        stop = raw.index('?>', i + 2)
        i = stop ? stop + 2 : length
      elsif kind == 0x2F
        depth -= 1
        raise Unsafe, 'namespace parse diverged' if depth < 0

        while (top = scopes.last) && top[0] == depth
          _, uri, prefixes = scopes.pop
        end
        stop = raw.index('>', i + 2)
        i = stop ? stop + 1 : length
      elsif kind.nil?
        break
      else
        finish = tag_finish(raw, i)
        raise Unsafe, 'namespace parse diverged' unless finish

        xmlns_i += 1 while xmlns_i < xmlns_at.length && xmlns_at[xmlns_i] < i
        has_xmlns = xmlns_i < xmlns_at.length && xmlns_at[xmlns_i] < finish
        name_at = i + 1
        pos = name_at
        colon = nil
        while pos < finish
          byte = raw.getbyte(pos)
          break if tag_boundary?(byte)

          colon = pos if byte == 0x3A && colon.nil?
          pos += 1
        end
        if colon || has_xmlns
          i, uri, prefixes, depth = append_declared_element(
            raw, i, length, entities, flat, scopes, uri, prefixes, depth
          )
        else
          local = intern_local_name(raw, name_at, pos - name_at)
          edge = finish - 1
          edge -= 1 while edge > i && tag_space?(raw.getbyte(edge))
          empty = raw.getbyte(edge) == 0x2F
          flat << local << namespace_record(uri, EMPTY_DECLS)
          depth += 1 unless empty
          i = finish + 1
        end
      end
    end
    raise Unsafe, 'namespace parse diverged' if depth != 0 || !scopes.empty?

    flat
  end

  def append_declared_element(raw, i, length, entities, flat, scopes, uri, prefixes, depth)
    name_at = i + 1
    pos = name_at
    colon = nil
    while pos < length
      byte = raw.getbyte(pos)
      break if tag_boundary?(byte)

      colon = pos if byte == 0x3A && colon.nil?
      pos += 1
    end
    if colon
      prefix = shared_string(raw.byteslice(name_at, colon - name_at).force_encoding(Encoding::UTF_8))
      local = intern_local_name(raw, colon + 1, pos - colon - 1)
    else
      prefix = nil
      local = intern_local_name(raw, name_at, pos - name_at)
    end
    decls = nil
    empty = false
    while pos < length
      byte = raw.getbyte(pos)
      if tag_space?(byte)
        pos += 1
        next
      end
      break if byte == 0x3E
      if byte == 0x2F
        empty = true
        pos += 1
        next
      end
      attr_at = pos
      pos += 1 while pos < length && !tag_boundary?(raw.getbyte(pos)) && raw.getbyte(pos) != 0x3D
      attr_prefix = xmlns_attribute_prefix(raw, attr_at, pos - attr_at)
      pos = skip_ascii_space(raw, pos, length)
      value_from = nil
      value_to = nil
      if raw.getbyte(pos) == 0x3D
        pos = skip_ascii_space(raw, pos + 1, length)
        quote = raw.getbyte(pos)
        raise Unsafe, 'namespace parse diverged' unless quote == 0x22 || quote == 0x27

        close = raw.index(quote.chr, pos + 1)
        raise Unsafe, 'namespace parse diverged' unless close

        value_from = pos + 1
        value_to = close
        pos = close + 1
      end
      next if attr_prefix == :no

      raise Unsafe, 'namespace parse diverged' unless value_from

      decls ||= []
      decls << [attr_prefix, decode_attr_bytes(raw, value_from, value_to, entities)]
    end
    raise Unsafe, 'namespace parse diverged' unless pos < length && raw.getbyte(pos) == 0x3E

    element_uri, next_uri, next_prefixes = bound_namespace(prefix, uri, prefixes, decls)
    flat << local << namespace_record(element_uri, decls || EMPTY_DECLS)
    unless empty
      if decls
        scopes << [depth, uri, prefixes]
        uri = next_uri
        prefixes = next_prefixes
      end
      depth += 1
    end
    [pos + 1, uri, prefixes, depth]
  end

  def bound_namespace(prefix, uri, prefixes, decls)
    next_uri = uri
    next_prefixes = prefixes
    if decls
      copied = false
      decls.each do |decl_prefix, value|
        if decl_prefix.nil?
          next_uri = value.empty? ? nil : value
        else
          unless copied
            next_prefixes = prefixes.dup
            copied = true
          end
          next_prefixes[decl_prefix] = value
        end
      end
    end
    element_uri = if prefix
                    raise Unsafe, 'namespace parse diverged' unless next_prefixes.key?(prefix)

                    found = next_prefixes[prefix]
                    found.respond_to?(:empty?) && found.empty? ? nil : found
                  else
                    next_uri
                  end
    [element_uri, next_uri, next_prefixes]
  end

  # Namespaces the DTD parse added, compared with the file's own parse.
  # The formatter's serializer writes those defaults out, so a later
  # comparison of two serialized trees does not see them.
  def compare_dtd_namespaces!(source, doc, name:)
    flat = scan_element_namespaces(source.b)
    index = 0
    each_element_preorder(doc) do |element|
      if index >= flat.length || flat[index] != element.name || !same_namespace?(flat[index + 1], element)
        raise Unsafe, "#{name}: CHANGED namespace of <#{element.name}>"
      end
      index += 2
    end
    return if index == flat.length

    raise Unsafe, "#{name}: CHANGED namespace of the document"
  end

  # The common element has no declarations. Comparing it does not allocate.
  def same_namespace?(record, element)
    href = element.namespace&.href
    definitions = element.namespace_definitions
    if definitions.empty?
      record[0] == href && record[1].equal?(EMPTY_DECLS)
    else
      decls = definitions.map { |namespace| [namespace.prefix, namespace.href] }
      record == [href, decls]
    end
  end

  def each_element_preorder(node, &block)
    node.children.each do |child|
      next unless child.element?

      yield child
      each_element_preorder(child, &block)
    end
  end

  def dom_namespace(element)
    definitions = element.namespace_definitions
    decls = if definitions.empty?
              EMPTY_DECLS
            else
              definitions.map { |namespace| [namespace.prefix, namespace.href] }
            end
    [element.namespace&.href, decls]
  end


  # One record object for every element that only inherits a namespace.
  # The tokens keep the href and the declaration list, and compare them by value.
  def namespace_record(uri, decls)
    return [uri, decls] unless decls.equal?(EMPTY_DECLS)

    (@plain_ns ||= {})[uri] ||= [uri, EMPTY_DECLS].freeze
  end

  def namespace_cursor(text)
    NsCursor.new(scan_element_namespaces(text.b))
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
    raise Unsafe, 'namespace parse diverged' unless cursor

    note(cursor, :element)
    name = cached_name(element)
    note(cursor, name)
    record = cursor.take_record
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
