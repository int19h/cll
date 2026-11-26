# Local XML input for chapter lints. Never fetch external entities.
require 'nokogiri'

module ChapterLint
  ROOT = File.expand_path('..', __dir__)
  ENTITIES = Dir["#{ROOT}/{dtd,xml}/*.ent"].sort.flat_map do |path|
    File.read(path).scan(/<!ENTITY\s+[A-Za-z][\w.-]*\s+"[^"]*"\s*>/)
  end.join("\n")
  PREFIX = "<!DOCTYPE chapter [\n#{ENTITIES}\n]>\n".freeze
  PREFIX_LINES = PREFIX.count("\n")

  def self.parse_string(raw)
    removed_lines = 0
    text = raw.sub(/\A<\?xml.*?\?>/m) do |decl|
      removed_lines = decl.count("\n")
      ''
    end
    doc = Nokogiri::XML("#{PREFIX}#{text}") do |c|
      c.strict.noent.nonet
    end
    doc.remove_namespaces!
    offset = PREFIX_LINES - removed_lines
    doc.define_singleton_method(:chapter_lint_line_offset) { offset }
    doc
  end

  def self.read(path)
    parse_string(File.read(path, encoding: 'UTF-8'))
  end

  # Map a Nokogiri node's line number back to the 1-based line in the source file.
  def self.source_line(node)
    offset = node.document.respond_to?(:chapter_lint_line_offset) ? node.document.chapter_lint_line_offset : 0
    node.line - offset
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
