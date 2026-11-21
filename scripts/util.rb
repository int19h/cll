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
# this sees them on whatever element carries them. The cell's own marks
# and a descendant's marks are checked separately: in a split cell
# (rule 12) each part already went through the <valsi> pass on its own,
# so only the cell's own marks unwrap the whole cell.
def cmavo_list_cell_opted_out?( cell )
  cell['glossary'] == 'false' || %w[false maybe].include?( cell['valid'].to_s )
end

def cmavo_list_descendant_opted_out?( cell )
  hit = false
  cell.traverse do |node|
    hit ||= node.element? && ( node['glossary'] == 'false' || %w[false maybe].include?( node['valid'].to_s ) )
  end
  hit
end

# A name test that ignores namespaces: the merged book parses with a
# default DocBook namespace, under which unprefixed XPath element
# names never match. Nokogiri element names never carry a prefix.
# A rafsi is never a cell word for linking (rule 9), so it is excluded
# from cell text too. An element that carries no visible text of its
# own never blocks the in-place link surgery below.
def cmavo_list_excluded_ancestor?( node, stop )
  node.ancestors.take_while { |a| a != stop }.any? do |a|
    %w[indexterm anchor rafsi].include?( a.name ) || a['role'] == 'display-none'
  end
end

def cmavo_list_transparent?( node )
  node.element? && ( %w[indexterm anchor rafsi].include?( node.name ) || node['role'] == 'display-none' )
end

# A cell's text for the linking rules: the concatenated text nodes,
# excluding indexterm, anchor and display-none subtrees (rule 11).
def cmavo_list_cell_text( cell )
  texts = []
  cell.traverse do |node|
    texts << node.text if node.text? && !cmavo_list_excluded_ancestor?( node, cell )
  end
  texts.join
end

# Visible text nodes of a cell: the same exclusions as
# cmavo_list_cell_text, as nodes.
def cmavo_list_visible_texts( cell )
  texts = []
  cell.traverse do |node|
    texts << node if node.text? && !cmavo_list_excluded_ancestor?( node, cell )
  end
  texts
end

# A split cell (rule 12): two or more <valsi>-pass link units with
# nothing between them, not even whitespace. Indexterms (which the
# <valsi> pass adds to each part), anchors and display-none subtrees do
# not count. Each part already links, or stays plain on its own marks.
def cmavo_list_split_cell?( cell )
  kids = cell.children.reject do |child|
    child.name == 'indexterm' || ( child.element? && ( child.name == 'anchor' || child['role'] == 'display-none' ) )
  end
  return false if kids.size < 2
  return false unless kids.all?( &:element? )
  kids.all? { |el| el.name == 'foreignphrase' }
end

# Whether a split part already links exactly the given word: one
# glossterm with the right target and nothing else visible. Such a part
# stays exactly as the <valsi> pass built it, so ordinary compound
# cells keep byte-identical markup.
def cmavo_list_part_linked?( part, word )
  linkend = "valsi-#{slugify(word)}"
  elements = []
  part.children.each do |child|
    next if child.text? && child.text =~ /\A\s+\z/
    return false unless child.element?
    elements << child
  end
  return false unless elements.size == 1
  term = elements.first
  term.name == 'glossterm' && term['linkend'] == linkend && cmavo_list_cell_text( term ) == word
end

# A cell contributes its word to the glossary list unless the cell (or a
# <valsi> inside it) is marked valid="false" or valid="maybe", the way
# such a <valsi> never does. A glossary="false" mark only stops the
# link; the entry is still collected, as for a <valsi>.
def cmavo_list_collectable?( cell )
  return false if %w[false maybe].include?( cell['valid'].to_s )
  hit = false
  cell.traverse do |node|
    next unless node.element? && node.name == 'valsi'
    next if cmavo_list_display_none_ancestor?( node, cell )
    hit ||= %w[false maybe].include?( node['valid'].to_s )
  end
  !hit
end

# True when an ancestor of node up to (but excluding) stop carries
# role="display-none".
def cmavo_list_display_none_ancestor?( node, stop )
  node.ancestors.take_while { |a| a != stop }.any? { |a| a['role'] == 'display-none' }
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
      parsed = cmavo_list_cell_word( cmavo_list_cell_text( cell ) )
      words << parsed[1] if parsed
    end
  end
  words
end

# The glossterm link xml_preprocess.rb wraps a linked word in, the same
# markup a <valsi> gets. No index entry: tables must not grow the index.
def build_glossary_link( document, word )
  foreign = Nokogiri::XML::Node.new( 'foreignphrase', document )
  foreign['xml:lang'] = 'jbo'
  term = Nokogiri::XML::Node.new( 'glossterm', document )
  term['role'] = 'valsi'
  term['linkend'] = "valsi-#{slugify(word)}"
  term.content = word
  foreign.add_child( term )
  foreign
end

# Replace the cell's word with its glossary link in place, keeping every
# other child (brackets stay as plain text around the link, anchors and
# hidden spans stay where they are). Returns false when a kept element
# sits inside the word span, which never happens in the book.
def link_cmavo_word_in_place!( cell, word )
  texts = cmavo_list_visible_texts( cell )
  full = texts.map(&:text).join
  start = full.index( word )
  return false unless start
  finish = start + word.length
  offset = 0
  first = first_cut = last = last_cut = nil
  texts.each do |text|
    stop = offset + text.text.length
    first, first_cut = text, start - offset if !first && start < stop
    if !last && finish <= stop
      last, last_cut = text, finish - offset
      break
    end
    offset = stop
  end
  return false unless first && last
  # Any kept element strictly inside the span aborts the link, as does
  # a span that does not run through siblings. Transparent elements
  # (indexterm, anchor, rafsi, display-none) carry no visible text of
  # their own and never block the link.
  if first != last
    node = first.next_sibling
    while node && node != last
      return false if node.element? && !cmavo_list_transparent?( node )
      node = node.next_sibling
    end
    return false unless node == last
  end
  link = build_glossary_link( cell.document, word )
  if first == last
    before = first.text[0...first_cut]
    after = first.text[last_cut..-1]
    first.content = before
    first.add_next_sibling( link )
    link.add_next_sibling( Nokogiri::XML::Text.new( after, cell.document ) ) unless after.empty?
    first.remove if before.empty?
  else
    middles = []
    node = first.next_sibling
    while node && node != last
      sibling = node.next_sibling
      middles << node if node.text?
      node = sibling
    end
    first.content = first.text[0...first_cut]
    last.content = last.text[last_cut..-1]
    middles.each( &:remove )
    if first.text.empty?
      first.add_next_sibling( link )
      first.remove
    else
      first.add_next_sibling( link )
    end
    if last.text.empty?
      last.remove
    end
  end
  true
end

# Drop the <valsi>-pass markup inside a cell that stays plain, keeping
# its text: the foreignphrase link and the indexterm a <valsi> there
# grew. Indexterms are removed first so their headword never joins the
# cell's text. Display-none subtrees are left alone so hidden text stays
# hidden.
def cmavo_list_remove_named!( cell, name )
  found = []
  cell.traverse { |node| found << node if node.element? && node.name == name }
  found.each( &:remove )
end

# Drop the <valsi>-pass markup inside a cell or part that stays plain,
# splicing each pass-produced wrapper (foreignphrase, glossterm, valsi)
# out and leaving its children in place. Indexterms go first so their
# headwords never join the text; display-none subtrees are left alone so
# hidden text stays hidden. Anchors and display-none spans survive in
# place; everything else becomes plain text in document order.
def unwrap_cmavo_cell!( cell )
  cmavo_list_remove_named!( cell, 'indexterm' )
  loop do
    target = nil
    cell.traverse do |node|
      next if node == cell
      next unless node.element? && %w[foreignphrase glossterm valsi].include?( node.name )
      next if cmavo_list_display_none_ancestor?( node, cell )
      target = node
      break
    end
    break unless target
    kids = target.children.to_a
    if kids.empty?
      target.remove
    else
      kids.each { |kid| target.add_previous_sibling( kid ) }
      target.remove
    end
  end
end

# Link one cmavo-list cell's word to the glossary when this document
# defines its entry spelled the same or differing only in outer pause
# dots (so "kiha" never takes "ki'a"'s entry), keeping the brackets of
# [word] as plain text. A split cell (rule 12) keeps its separately
# linked parts, without indexterms and without a report. A cell of any
# other shape, an opted-out cell, or a word with no entry stays plain
# text. A <valsi> already inside counts as the cell's text under the
# same rules and never makes a second, nested link. Returns the unlinked
# word, or nil when the cell linked or was never linkable.
# A split cell's parts, in order: the child foreignphrase elements,
# skipping indexterms, anchors and display-none subtrees.
def cmavo_list_split_parts( cell )
  kids = cell.children.reject do |child|
    child.name == 'indexterm' || ( child.element? && ( child.name == 'anchor' || child['role'] == 'display-none' ) )
  end
  kids.select { |child| child.element? && child.name == 'foreignphrase' }
end

# Link one part of a split compound cell (rule 12): rules 6, 10 and 11
# apply to each part on its own. An opted-out part stays plain; a part
# whose visible text is not one dictionary word stays plain; a part
# with no dictionary entry stays plain and is reported, so the build
# never emits a link to a missing target. Returns the unlinked word, or
# nil when the part linked or stayed plain on purpose.
def link_cmavo_split_part!( part, entries )
  if cmavo_list_cell_opted_out?( part ) || cmavo_list_descendant_opted_out?( part )
    unwrap_cmavo_cell!( part )
    return nil
  end
  word = cmavo_list_cell_text( part ).strip
  unless word =~ %r{\A[.a-zA-Z']+\z}
    unwrap_cmavo_cell!( part )
    return nil
  end
  headword = entries["valsi-#{slugify(word)}"]
  unless headword && bare_spelling( headword ) == bare_spelling( word )
    unwrap_cmavo_cell!( part )
    return word
  end
  cmavo_list_remove_named!( part, 'indexterm' )
  return nil if cmavo_list_part_linked?( part, word )
  unwrap_cmavo_cell!( part )
  return word unless link_cmavo_word_in_place!( part, word )
  nil
end

def cmavo_list_has_rafsi?( cell )
  hit = false
  cell.traverse { |node| hit ||= node.element? && node.name == 'rafsi' }
  hit
end

def link_cmavo_list_cell!( cell, entries )
  # Rule 9: a rafsi never gets a glossary link. Leave the cell's text
  # alone (unwrapping only <valsi>-pass markup) so the rafsi pass still
  # sees its own element.
  if cmavo_list_has_rafsi?( cell )
    unwrap_cmavo_cell!( cell )
    return nil
  end
  if cmavo_list_cell_opted_out?( cell )
    unwrap_cmavo_cell!( cell )
    return nil
  end
  if cmavo_list_split_cell?( cell )
    missing = cmavo_list_split_parts( cell ).map { |part| link_cmavo_split_part!( part, entries ) }.compact
    return missing unless missing.empty?
    return nil
  end
  if cmavo_list_descendant_opted_out?( cell )
    unwrap_cmavo_cell!( cell )
    return nil
  end
  cmavo_list_remove_named!( cell, 'indexterm' )
  parsed = cmavo_list_cell_word( cmavo_list_cell_text( cell ) )
  unless parsed
    unwrap_cmavo_cell!( cell )
    return nil
  end
  _pre, word, _post = parsed
  headword = entries["valsi-#{slugify(word)}"]
  unless headword && bare_spelling( headword ) == bare_spelling( word )
    unwrap_cmavo_cell!( cell )
    return word
  end
  unwrap_cmavo_cell!( cell )
  return word unless link_cmavo_word_in_place!( cell, word )
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
