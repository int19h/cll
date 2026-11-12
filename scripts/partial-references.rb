# Point every cross-reference whose target is absent at an element that is
# present. A partial build omits chapters and appendices, and the validator
# rejects a linkend that names nothing. Editing the attribute values in place
# keeps the chapter text, entities, and spacing as they were written. Parsing
# the book and saving it again expands the DocBook DTD and breaks preprocessing.
require 'set'

path = ARGV.fetch(0)
xml = File.read(path)

ids = Set.new
xml.scan(/\bxml:id\s*=\s*(["'])([^"']+)\1/) { ids << Regexp.last_match(2) }
abort "#{path}: partial build has no xml:id to stand in for an omitted reference" if ids.empty?

fallback = nil
xml.scan(/<(?:chapter|appendix|preface|article)\b[^>]*\bxml:id\s*=\s*(["'])([^"']+)\1/) do
  id = Regexp.last_match(2)
  if ids.include?(id)
    fallback = id
    break
  end
end
fallback ||= ids.first

# linkends shares a prefix with linkend, so the longer name has to come first.
idref = %w[linkends linkend endterm otherterm startref zone arearefs]
idrefs = %w[linkends zone arearefs]
xml.gsub!(/\b(#{idref.join('|')})(\s*=\s*)(["'])([^"']*)\3/) do
  name = Regexp.last_match(1)
  spacing = Regexp.last_match(2)
  quote = Regexp.last_match(3)
  value = Regexp.last_match(4)
  rewritten = if idrefs.include?(name)
    value.split(/\s+/).map { |token| ids.include?(token) ? token : fallback }.join(' ')
  elsif ids.include?(value)
    value
  else
    fallback
  end
  %(#{name}#{spacing}#{quote}#{rewritten}#{quote})
end

File.write(path, xml)
