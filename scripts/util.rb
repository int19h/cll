def find_lojban_words( tree )
  tree.xpath('//valsi').select { |x| x.attributes['valid'].to_s != 'false' }
end

def slugify( text )
  text.gsub( %r{'}, 'h' ).gsub( %r{[^a-zA-Z0-9]}, '_' ).gsub( %r{_+$}, '' ).gsub( %r{^_+}, '' )
end

# A jbophrase such as "ke ... ke'e" or "be ... bei ... be'o" names a frame:
# single words separated by ellipses.  Returns the parts, alternating word
# and separator ("ke", " ... ", "ke'e"), or nil when the text is not a frame.
FRAME_SEPARATOR = %r{(\s*(?:\.\.\.|…)\s*)}

def jbophrase_frame( text )
  parts = text.strip.split( FRAME_SEPARATOR, -1 )
  return nil if parts.length < 3
  words = parts.each_slice(2).map(&:first)
  return nil unless words.all? { |w| w =~ %r{\A[.a-zA-Z',]+\z} }
  parts
end

# The words of every frame-shaped jbophrase, for the glossary.
def find_frame_words( tree )
  tree.xpath('//jbophrase').reject { |x| [ 'false', 'maybe' ].include? x.attributes['valid'].to_s }.flat_map do |node|
    parts = jbophrase_frame( node.text )
    parts ? parts.each_slice(2).map(&:first) : []
  end
end

# Keep legacy slugs stable. Colliding spellings share one glossary entry.
def glossary_word_groups(words)
  words.uniq.sort_by { |word| [slugify(word).downcase, word] }.group_by { |word| slugify(word) }
end

# The HTML5 page contract (issue #209). Online pages and PDF input use
# :html. ePub content pages use :epub. The function does not indent.
XHTML_NS = 'http://www.w3.org/1999/xhtml'
CONTENT_TYPE = 'text/html; charset=utf-8'

def contract_content_type_meta?(element)
  return false unless element&.element? && element.name == 'meta'
  return false unless element.namespace&.href == XHTML_NS
  element['http-equiv'] == 'Content-Type' && element['content'] == CONTENT_TYPE &&
    (element['charset'].nil? || element['charset'].empty?)
end

# Leave a meta that already matches the contract where it is, so a second
# write does not move it. Any other encoding meta is removed. libxml adds
# its own meta, with an uppercase charset, when the tree has none.
def ensure_contract_meta!(doc, head)
  require 'nokogiri'
  unless head.namespace&.href == XHTML_NS
    raise 'head is not in the XHTML namespace'
  end
  metas = head.xpath('h:meta[@http-equiv or @charset]', 'h' => XHTML_NS).to_a
  keeper = nil
  metas.each do |element|
    if keeper.nil? && contract_content_type_meta?(element)
      keeper = element
    else
      element.remove
    end
  end
  return if keeper && head.element_children.first == keeper
  keeper&.remove
  meta = Nokogiri::XML::Node.new('meta', doc)
  meta.namespace = head.namespace
  meta['http-equiv'] = 'Content-Type'
  meta['content'] = CONTENT_TYPE
  head.prepend_child(meta)
end

def serialize_page(doc, mode: :html)
  require 'nokogiri'
  mode = mode.to_sym
  raise ArgumentError, 'mode must be :html or :epub' unless %i[html epub].include?(mode)
  head = doc.at_xpath('/h:html/h:head', 'h' => XHTML_NS)
  raise 'page has no head' unless head
  if mode == :html
    ensure_contract_meta!(doc, head)
  else
    head.xpath('h:meta[@http-equiv or @charset]', 'h' => XHTML_NS).each(&:remove)
  end
  # to_xml on the document ignores AS_XHTML when the DOCTYPE is <!DOCTYPE html>.
  # The root element follows the XHTML empty-element rules.
  opts = Nokogiri::XML::Node::SaveOptions::AS_XHTML
  body = doc.root.to_xml(save_with: opts, encoding: 'UTF-8')
  if mode == :epub
    body = body.sub(%r{<meta http-equiv="Content-Type"[^>]*/>}, '')
    raise 'unexpected http-equiv meta' if body.include?('http-equiv="Content-Type"')
    return %(<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n#{body}\n)
  end
  "<!DOCTYPE html>\n#{body}\n"
end
