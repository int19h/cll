#!/usr/bin/env ruby
# Fail on missing gloss cells and misplaced glosses for structural words.
require_relative 'chapter-lint'
require_relative 'gloss-cells'

module GlossColumns
  # Aligned examples give cu 295 empty and ten punctuation cells; [cu] is empty.
  # Terminators close structures: aligned glosses use empty cells or punctuation.
  TERMINATORS = %w[ku ku'o kei vau be'o ke'e]
  # Aligned .i cells are empty (66), a period (10), or "And" (2).
  # Keep "And" as a sentence-link gloss, including its lowercase form.
  def self.allowed?(word, gloss)
    word = word.downcase.delete('[]')
    punctuation = gloss.empty? || gloss.match?(/\A[[:punct:]…[:space:]]+\z/)
    return punctuation if word == 'cu' || TERMINATORS.include?(word)
    return punctuation || gloss.match?(/\Aand\z/i) if word == '.i'
    true
  end

  def self.cells(row)
    # Use a detached copy: the build helper replaces its input node.
    copy = row.dup
    holder = Nokogiri::XML::Node.new('holder', row.document)
    holder.add_child(copy)
    table_row_by_words(copy).element_children.map { |td| td.text.strip }
  end

  def self.failures(doc, path)
    failures = []
    doc.xpath('//interlinear-gloss').each do |ig|
      rows = ig.element_children.select { |n| %w[jbo gloss].include?(n.name) }
      rows.each_cons(2) do |jbo, gloss|
        next unless jbo.name == 'jbo' && gloss.name == 'gloss'
        a, b = cells(jbo), cells(gloss)
        reasons = []
        reasons << "#{b.size} gloss cells for #{a.size} Lojban cells" if b.size < a.size
        a.zip(b).each_with_index do |(word, value), index|
          next if value.nil? || allowed?(word, value)
          reasons << "cell #{index + 1}: #{word.inspect} cannot gloss as #{value.inspect}"
        end
        next if reasons.empty?
        width = [*(a.map(&:length)), 3].max
        pairs = [a.size, b.size].max.times.map do |i|
          "  #{(a[i] || '(missing)').ljust(width)} | #{b[i] || '(missing)'}"
        end
        failures << "#{ChapterLint.location(path, ig)}: #{reasons.join('; ')}\n#{pairs.join("\n")}"
      end
    end
    failures
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: #{$PROGRAM_NAME} chapters/*.xml" if ARGV.empty?
  failures = ARGV.flat_map { |path| GlossColumns.failures(ChapterLint.read(path), path) }
  puts failures
  exit(failures.empty? ? 0 : 1)
end
