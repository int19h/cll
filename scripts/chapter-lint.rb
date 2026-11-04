# Local XML input for chapter lints. Never fetch external entities.
require 'nokogiri'

module ChapterLint
  ROOT = File.expand_path('..', __dir__)
  ENTITIES = Dir["#{ROOT}/{dtd,xml}/*.ent"].sort.flat_map do |path|
    File.read(path).scan(/<!ENTITY\s+[A-Za-z][\w.-]*\s+"[^"]*"\s*>/)
  end.join("\n")

  def self.read(path)
    text = File.read(path).sub(/\A<\?xml.*?\?>/m, '')
    doc = Nokogiri::XML("<!DOCTYPE chapter [\n#{ENTITIES}\n]>\n#{text}") do |c|
      c.strict.noent.nonet
    end
    doc.remove_namespaces!
    doc
  end

  def self.location(path, node)
    chapter = node.ancestors.find { |n| %w[chapter appendix].include?(n.name) }
    chapter ||= node.document.root
    example = node.ancestors('example').first
    number = example ? chapter.xpath('.//example').to_a.index(example).to_i + 1 : nil
    ch = File.basename(path, '.xml').sub(/^0+/, '')
    "#{path}: example #{number ? "#{ch}.#{number}" : '(unnumbered)'} (#{example&.[]('id') || 'no example ID'})"
  end
end
