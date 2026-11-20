def find_lojban_words( tree )
  tree.xpath('//valsi').select { |x| x.attributes['valid'].to_s != 'false' }
end

# The glossary entries a preprocessed document defines, by ID, for the
# cmavo-list link gate: a cell word links only when its entry is really
# there, spelled the same or differing only in outer pause dots.
def glossary_entries( doc )
  entries = {}
  doc.css('glossentry').each do |entry|
    id = entry['xml:id']
    term = entry.at('glossterm')
    # Only the headword text itself: the term also holds the
    # pronunciation button with the entry's slug.
    entries[id] = term.xpath('./text()').map(&:text).join.strip if id && term
  end
  entries
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

# A cmavo-list cell names its word as plain text. Only two shapes link:
# one bare word (<cmavo>mi</cmavo>, a compound such as roinai), or exactly
# one bracketed word (<gismu>[jundi]</gismu>); everything else (empty
# cells, "-----", phrases with spaces, "[cmavo: mi]") stays plain text
# and contributes no word. Returns [brackets, word] for a linkable cell,
# nil otherwise.
def cmavo_list_cell_word( text )
  trimmed = text.strip
  return [ '[', Regexp.last_match(1), ']' ] if trimmed =~ %r{\A\[([.a-zA-Z']+)\]\z}
  return [ '', trimmed, '' ] if trimmed =~ %r{\A[.a-zA-Z']+\z}
  nil
end

# The cell's spelling with outer pause dots removed, for the rule 6
# target check: two spellings that reduce to the same bare form differ
# only in outer pause dots.
def bare_spelling( word )
  word.sub( %r{\A\.+}, '' ).sub( %r{\.+\z}, '' )
end

# A cell (or a <valsi> inside it) marked glossary="false", valid="false"
# or valid="maybe" never links, as a <valsi> with those marks never
# does. The marks survive the <valsi> pass (convert! keeps them), so
# this sees them on whatever element carries them.
def cmavo_list_opted_out?( cell )
  return true if cell['glossary'] == 'false' || %w[false maybe].include?( cell['valid'].to_s )
  cell.xpath('.//*').any? do |el|
    el['glossary'] == 'false' || %w[false maybe].include?( el['valid'].to_s )
  end
end

# A cell contributes its word to the glossary list unless the cell (or a
# <valsi> inside it) is marked valid="false" or valid="maybe", the way
# such a <valsi> never does. A glossary="false" mark only stops the
# link; the entry is still collected, as for a <valsi>.
def cmavo_list_collectable?( cell )
  return false if %w[false maybe].include?( cell['valid'].to_s )
  cell.xpath('.//valsi').none? { |v| %w[false maybe].include?( v['valid'].to_s ) }
end

# The words of linkable cmavo-list cells, for the glossary: the same
# selection xml_preprocess.rb links with, minus the valid="false" and
# valid="maybe" opt-outs. Cells the dictionary lacks get no entry, and
# xml_preprocess.rb leaves them unlinked.
def find_cmavo_list_words( tree )
  words = []
  tree.xpath('//cmavo-entry').each do |entry|
    entry.element_children.each do |cell|
      next unless %w[cmavo gismu].include?( cell.name )
      next unless cmavo_list_collectable?( cell )
      parsed = cmavo_list_cell_word( cell.text )
      words << parsed[1] if parsed
    end
  end
  words
end

# The glossterm link xml_preprocess.rb wraps a linked word in, the same
# markup a <valsi> gets. No index entry: tables must not grow the index.
def glossary_link( parent, word )
  document = parent.document
  foreign = Nokogiri::XML::Node.new( 'foreignphrase', document )
  foreign['xml:lang'] = 'jbo'
  term = Nokogiri::XML::Node.new( 'glossterm', document )
  term['role'] = 'valsi'
  term['linkend'] = "valsi-#{slugify(word)}"
  term.content = word
  foreign.add_child( term )
  parent.add_child( foreign )
end

# Drop the <valsi>-pass markup inside a cell that stays plain, keeping
# its text: the foreignphrase link and the indexterm a <valsi> there
# grew. Indexterms are removed first so their headword never joins the
# cell's text.
def unwrap_cmavo_cell!( cell )
  cell.xpath('.//indexterm').remove
  cell.element_children.each do |el|
    el.replace( Nokogiri::XML::Text.new( el.text, cell.document ) )
  end
end

# Link one cmavo-list cell's word to the glossary when this document
# defines its entry spelled the same or differing only in outer pause
# dots (so "kiha" never takes "ki'a"'s entry), keeping the brackets of
# [word] as plain text. A cell of any other shape, an opted-out cell, a
# compound the dictionary lacks, or a word with no entry stays plain
# text. A <valsi> already inside counts as the cell's text under the
# same rules and never makes a second, nested link. Returns the unlinked
# word, or nil when the cell linked or was never linkable.
def link_cmavo_list_cell!( cell, entries )
  if cmavo_list_opted_out?( cell )
    unwrap_cmavo_cell!( cell )
    return nil
  end
  cell.xpath('.//indexterm').remove
  parsed = cmavo_list_cell_word( cell.text )
  unless parsed
    unwrap_cmavo_cell!( cell )
    return nil
  end
  pre, word, post = parsed
  headword = entries["valsi-#{slugify(word)}"]
  unless headword && bare_spelling( headword ) == bare_spelling( word )
    unwrap_cmavo_cell!( cell )
    return word
  end
  cell.children.remove
  cell.add_child( Nokogiri::XML::Text.new( pre, cell.document ) ) unless pre.empty?
  glossary_link( cell, word )
  cell.add_child( Nokogiri::XML::Text.new( post, cell.document ) ) unless post.empty?
  nil
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
