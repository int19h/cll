# frozen_string_literal: true

require 'nokogiri'
require_relative 'html_format'

# Compare a page with the formatter's output. The two trees must match,
# except whitespace-only text at a free gap of the original tree.
# HtmlFormat.free_gap? is the only definition of a free gap.
#
# Parsing loads no DTD and uses no network. A named entity other than
# amp, lt, gt, quot, or apos is rejected, so the DTD is not required.
#
# The formatted page must also match the HTML5 contract: no XML declaration,
# the DOCTYPE <!DOCTYPE html>, void elements self-closed, and every other
# empty element written with an end tag. An XML parser cannot see that
# difference, so it is checked on the text.
module HtmlWhitespaceGuard
  class Unsafe < StandardError; end

  ALLOWED_ENTITIES = %w[amp lt gt quot apos].freeze
  HTML_DOCTYPE = '<!DOCTYPE html>'
  # HTML void elements. A self-closed tag of any other name is not XML-safe
  # for an HTML parser, and an end tag on one of these is not the contract.
  VOID_ELEMENTS = %w[
    area base br col embed hr img input link meta param source track wbr
  ].freeze
  PARSE = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET

  module_function

  def compare!(before_text, after_text, name:, strict: false)
    check_entities(before_text, name, 'original')
    check_entities(after_text, name, 'formatted')
    check_contract!(before_text, name, 'original')
    check_contract!(after_text, name, 'formatted')
    compare_prolog(before_text, after_text, name)
    before_doc = parse_side(before_text, name, 'original')
    after_doc = parse_side(after_text, name, 'formatted')
    HtmlFormat.with_memo do
      compare_children(before_doc, after_doc, name, strict)
    end
    nil
  end

  def compare_paths(before_path, after_path, strict: false)
    compare!(File.read(before_path), File.read(after_path), name: before_path, strict: strict)
  end

  def check_entities(text, name, side)
    # Byte offsets. A UTF-8 index would rescan the page for every '&'.
    scrubbed = text.gsub(/<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>/m, '').b
    index = 0
    while (mark = scrubbed.index('&', index))
      window = scrubbed.byteslice(mark, 64)
      if (match = window.match(/\A&#(?:[0-9]+|x[0-9A-Fa-f]+);/))
        index = mark + match.end(0)
      elsif (match = window.match(/\A&([A-Za-z][A-Za-z0-9.-]*);/))
        entity = match[1]
        unless ALLOWED_ENTITIES.include?(entity)
          raise Unsafe, "#{name}: named entity &#{entity}; on the #{side} side is not amp, lt, gt, quot, or apos"
        end
        index = mark + match.end(0)
      else
        snippet = window.to_s.gsub(/\s+/, ' ')[0, 24]
        raise Unsafe, "#{name}: entity reference #{snippet.inspect} on the #{side} side is not amp, lt, gt, quot, or apos"
      end
    end
  end

  def check_contract!(text, name, side)
    declaration, doctype = prolog(text, name, side)
    unless declaration.nil?
      raise Unsafe, "#{name}: XML declaration on the #{side} side"
    end
    if doctype != HTML_DOCTYPE
      shown = doctype.nil? ? 'missing' : doctype
      raise Unsafe, "#{name}: DOCTYPE on the #{side} side is #{shown}"
    end
    check_empty_elements!(text, name, side)
  end

  def check_empty_elements!(text, name, side)
    # Byte offsets. A character index on UTF-8 rescans from the start, so
    # one non-ASCII character makes a book-length page take hours. The
    # markers below are ASCII, and a UTF-8 tail byte is never one of them.
    # The void-element rules apply to XHTML elements. A br in another
    # namespace is an ordinary empty element, and the writer gives it an end tag.
    raw = text.b
    index = 0
    length = raw.bytesize
    frames = [{ element: nil, default: nil, prefixes: {} }]
    while index < length
      unless raw.getbyte(index) == 60
        index += 1
        next
      end
      if raw.byteslice(index, 4) == '<!--'.b
        finish = raw.index('-->'.b, index + 4)
        raise Unsafe, "#{name}: unclosed comment on the #{side} side" unless finish
        index = finish + 3
        next
      end
      if raw.byteslice(index, 9) == '<![CDATA['.b
        finish = raw.index(']]>'.b, index + 9)
        raise Unsafe, "#{name}: unclosed CDATA on the #{side} side" unless finish
        index = finish + 3
        next
      end
      if raw.byteslice(index, 2) == '<?'.b
        finish = raw.index('?>'.b, index + 2)
        raise Unsafe, "#{name}: unclosed processing instruction on the #{side} side" unless finish
        index = finish + 2
        next
      end
      if raw.byteslice(index, 2) == '<!'.b
        index += 1
        next
      end
      closing = raw.getbyte(index + 1) == 47
      start = closing ? index + 2 : index + 1
      qname = tag_name_at(raw, start, length)
      if qname.nil?
        index += 1
        next
      end
      local = qname.split(':').last
      cursor = start + qname.bytesize
      quote = nil
      closed = false
      ended = false
      while cursor < length
        byte = raw.getbyte(cursor)
        if quote
          quote = nil if byte == quote
          cursor += 1
        elsif byte == 34 || byte == 39
          quote = byte
          cursor += 1
        elsif byte == 62
          look = cursor - 1
          look -= 1 while look > index && ascii_space?(raw.getbyte(look))
          closed = raw.getbyte(look) == 47
          ended = true
          cursor += 1
          break
        else
          cursor += 1
        end
      end
      # A tag whose ">" is the last byte still ended. Running off the end
      # without that byte did not, even when the last byte happens to be ">".
      unless ended
        raise Unsafe, "#{name}: unclosed tag on the #{side} side"
      end
      if closing
        opened = frames.length > 1 ? frames.pop : frames.last
        element_ns = opened[:element]
      else
        raw_tag = raw.byteslice(start, cursor - start - 1).force_encoding(Encoding::UTF_8)
        unless raw_tag.valid_encoding?
          raise Unsafe, "#{name}: tag is not UTF-8 on the #{side} side"
        end
        info = element_frame(qname, raw_tag, frames.last)
        frames.push(info) unless closed
        element_ns = info[:element]
      end
      if element_ns.nil? || element_ns == XHTML_NS
        if closing && VOID_ELEMENTS.include?(local)
          raise Unsafe, "#{name}: void element #{local} has an end tag on the #{side} side"
        elsif !closing && closed && !VOID_ELEMENTS.include?(local)
          raise Unsafe, "#{name}: self-closed non-void element #{local} on the #{side} side"
        end
      end
      index = cursor
    end
  end

  # The name at this byte, or nil when the "<" is not a tag. The slice stops
  # at the first ASCII delimiter. Those bytes cannot occur inside a UTF-8
  # character, so the cut is the same as a character scan.
  def tag_name_at(raw, start, length)
    limit = start
    while limit < length
      byte = raw.getbyte(limit)
      break if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12 ||
                byte == 47 || byte == 62 || byte == 61 || byte == 34 || byte == 39
      limit += 1
    end
    return nil if limit == start
    candidate = raw.byteslice(start, limit - start).force_encoding(Encoding::UTF_8)
    return nil unless candidate.valid_encoding?
    match = candidate.match(/\A([A-Za-z_:][\w:.-]*)/)
    return nil unless match && !match[1].empty?
    match[1]
  end

  def ascii_space?(byte)
    byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
  end

  def element_frame(qname, raw, parent)
    default_ns = parent[:default]
    prefixes = parent[:prefixes].dup
    raw.scan(/xmlns(?::([A-Za-z_][\w.-]*))?\s*=\s*(["'])(.*?)\2/) do |prefix, _quote, value|
      if prefix.nil? || prefix.empty?
        default_ns = value
      else
        prefixes[prefix] = value
      end
    end
    element_ns = if (colon = qname.index(':'))
                   prefixes[qname[0, colon]]
                 else
                   default_ns
                 end
    { element: element_ns, default: default_ns, prefixes: prefixes }
  end

  def compare_prolog(before_text, after_text, name)
    before_decl, before_type = prolog(before_text, name, 'original')
    after_decl, after_type = prolog(after_text, name, 'formatted')
    if before_decl != after_decl
      raise Unsafe, "#{name}: XML declaration differs"
    end
    if before_type != after_type
      raise Unsafe, "#{name}: DOCTYPE differs"
    end
  end

  def prolog(text, name, side)
    body = text.start_with?("\uFEFF") ? text[1..] : text
    bom = text.start_with?("\uFEFF") ? "\uFEFF" : ''
    declaration = nil
    index = 0
    if body.start_with?('<?xml')
      finish = body.index('?>', 5)
      raise Unsafe, "#{name}: unclosed XML declaration on the #{side} side" unless finish
      declaration = bom + body[0, finish + 2]
      index = finish + 2
    elsif !bom.empty?
      declaration = bom
    end
    doctype = nil
    while index < body.length
      if body[index].match?(/[ \t\r\n\f]/)
        index += 1
      elsif body[index, 4] == '<!--'
        finish = body.index('-->', index + 4)
        raise Unsafe, "#{name}: unclosed comment on the #{side} side" unless finish
        index = finish + 3
      elsif body[index, 2] == '<?'
        finish = body.index('?>', index + 2)
        raise Unsafe, "#{name}: unclosed processing instruction on the #{side} side" unless finish
        index = finish + 2
      elsif body[index, 9] == '<!DOCTYPE'
        doctype = read_doctype(body, index, name, side)
        break
      else
        break
      end
    end
    [declaration, doctype]
  end

  def read_doctype(text, start, name, side)
    index = start + 9
    quote = nil
    brackets = 0
    while index < text.length
      char = text[index]
      if quote
        quote = nil if char == quote
        index += 1
      elsif text[index, 4] == '<!--'
        finish = text.index('-->', index + 4)
        raise Unsafe, "#{name}: unclosed comment in the DOCTYPE on the #{side} side" unless finish
        index = finish + 3
      elsif char == '"' || char == "'"
        quote = char
        index += 1
      elsif char == '['
        brackets += 1
        index += 1
      elsif char == ']'
        brackets -= 1
        index += 1
      elsif char == '>' && brackets <= 0
        return text[start..index]
      else
        index += 1
      end
    end
    raise Unsafe, "#{name}: unclosed DOCTYPE on the #{side} side"
  end

  def parse_side(text, name, side)
    Nokogiri::XML(text) do |config|
      config.options = PARSE
    end
  rescue Nokogiri::XML::SyntaxError => error
    message = error.message.strip
    raise Unsafe, "#{name}: parse error on the #{side} side: #{message}"
  end

  def compare_children(parent_a, parent_b, name, strict)
    sigs_a, gaps_a = HtmlFormat.split_children(parent_a)
    sigs_b, gaps_b = HtmlFormat.split_children(parent_b)
    unless sigs_a.length == sigs_b.length
      raise Unsafe, "#{name}: different nodes under #{place(parent_a)}"
    end
    flags = strict || !parent_a.element? ? nil : HtmlFormat.free_gap_flags(parent_a, sigs_a)
    last = sigs_a.length
    index = 0
    while index <= last
      unless flags && flags[index]
        unless gaps_a[index].map(&:content) == gaps_b[index].map(&:content)
          left = index.zero? ? nil : sigs_a[index - 1]
          right = index == last ? nil : sigs_a[index]
          raise Unsafe, "#{name}: whitespace changed under #{place(parent_a)} #{beside(left, right)}"
        end
      end
      index += 1
    end
    index = 0
    while index < last
      compare_node(sigs_a[index], sigs_b[index], name, strict)
      index += 1
    end
  end

  def compare_node(node_a, node_b, name, strict)
    unless node_kind(node_a) == node_kind(node_b)
      raise Unsafe, "#{name}: #{node_kind(node_a)} became #{node_kind(node_b)} under #{place(node_a.parent)}"
    end
    case node_kind(node_a)
    when :element
      compare_element(node_a, node_b, name, strict)
    when :text, :cdata
      return if node_a.content == node_b.content
      raise Unsafe, "#{name}: text differs under #{place(node_a.parent)}"
    when :comment
      return if node_a.content == node_b.content
      raise Unsafe, "#{name}: comment differs"
    when :pi
      return if node_a.name == node_b.name && node_a.content == node_b.content
      raise Unsafe, "#{name}: processing instruction differs"
    when :dtd
      return if [node_a.name, node_a.external_id, node_a.system_id] ==
                 [node_b.name, node_b.external_id, node_b.system_id]
      raise Unsafe, "#{name}: DOCTYPE differs"
    else
      raise Unsafe, "#{name}: unsupported node #{node_kind(node_a)}"
    end
  end

  def compare_element(node_a, node_b, name, strict)
    href_a = HtmlFormat.namespace_href(node_a)
    href_b = HtmlFormat.namespace_href(node_b)
    if node_a.name == node_b.name && href_a != href_b
      raise Unsafe, "#{name}: element #{node_a.name} namespace #{namespace_text(href_a)} became #{namespace_text(href_b)}"
    end
    if href_a != href_b || node_a.name != node_b.name
      raise Unsafe, "#{name}: element #{label(node_a)} became #{label(node_b)}"
    end
    unless same_namespaces?(node_a, node_b)
      raise Unsafe, "#{name}: namespace declarations differ on #{label(node_a)}"
    end
    unless same_attributes?(node_a, node_b)
      raise Unsafe, "#{name}: attributes differ on #{label(node_a)}"
    end
    compare_children(node_a, node_b, name, strict)
  end

  def same_namespaces?(node_a, node_b)
    defs_a = node_a.namespace_definitions
    defs_b = node_b.namespace_definitions
    return false unless defs_a.length == defs_b.length
    index = 0
    while index < defs_a.length
      left = defs_a[index]
      right = defs_b[index]
      return false unless left.prefix == right.prefix && left.href == right.href
      index += 1
    end
    true
  end

  def same_attributes?(node_a, node_b)
    attrs_a = node_a.attribute_nodes
    attrs_b = node_b.attribute_nodes
    return false unless attrs_a.length == attrs_b.length
    index = 0
    while index < attrs_a.length
      left = attrs_a[index]
      right = attrs_b[index]
      left_ns = left.namespace
      right_ns = right.namespace
      left_prefix = left_ns ? left_ns.prefix : nil
      right_prefix = right_ns ? right_ns.prefix : nil
      return false unless left_prefix == right_prefix && left.name == right.name && left.value == right.value
      index += 1
    end
    true
  end

  def node_kind(node)
    return :element if node.element?
    return :cdata if node.cdata?
    return :text if node.text?
    return :comment if node.comment?
    return :pi if node.processing_instruction?
    return :dtd if node.type == Nokogiri::XML::Node::DTD_NODE
    node.type
  end

  def place(node)
    return 'the document' if node.nil? || node.document?
    return 'the DOCTYPE' if node.type == Nokogiri::XML::Node::DTD_NODE
    label(node)
  end

  def label(node)
    return 'the document' if node.nil? || !node.element?
    node.name
  end

  def namespace_text(href)
    return 'no namespace' if href.nil? || href.empty?
    href
  end

  def beside(left, right)
    "between #{edge_label(left)} and #{edge_label(right)}"
  end

  def edge_label(node)
    return 'the edge' if node.nil?
    return "<#{node.name}>" if node.element?
    return 'a comment' if node.comment?
    return 'a processing instruction' if node.processing_instruction?
    'text'
  end
end

if $PROGRAM_NAME == __FILE__
  def usage
    warn 'usage: ruby scripts/html_whitespace_guard.rb [--strict] BEFORE AFTER'
    warn 'BEFORE and AFTER are two files, or two directories of .html files.'
    exit 2
  end

  args = ARGV.dup
  strict = args.first == '--strict'
  args.shift if strict
  usage unless args.length == 2
  before_arg, after_arg = args
  pairs = []
  if File.directory?(before_arg) || File.directory?(after_arg)
    usage unless File.directory?(before_arg) && File.directory?(after_arg)
    Dir.chdir(before_arg) do
      Dir.glob('**/*.html').sort.each do |relative|
        pairs << [File.join(before_arg, relative), File.join(after_arg, relative)]
      end
    end
  else
    pairs << [before_arg, after_arg]
  end
  if pairs.empty?
    warn "no .html files in #{before_arg}"
    exit 1
  end
  failed = false
  pairs.each do |before_path, after_path|
    unless File.file?(after_path)
      warn "#{before_path}: missing formatted page #{after_path}"
      failed = true
      next
    end
    HtmlWhitespaceGuard.compare_paths(before_path, after_path, strict: strict)
  rescue HtmlWhitespaceGuard::Unsafe => error
    warn error.message
    failed = true
  end
  exit(failed ? 1 : 0)
end
