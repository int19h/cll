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
