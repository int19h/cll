#!/usr/bin/env ruby
# Detect CGV and unreviewed vowel commas without a book build or parser install.
require_relative 'chapter-lint'
require 'json'

module WordSpellings
  ELEMENTS = %w[jbo jbophrase valsi cmevla cmavo gismu rafsi lujvo diphthong letteral].freeze
  NON_LOJBAN = %w[gloss natlang comment description ipa pronunciation].freeze
  CONSONANTS = 'bcdfgjklmnprstvxz'
  REVIEW_FILE = File.join(__dir__, 'reviewed-comma-words.json')

  def self.sequences(word)
    core = word.downcase.delete(',')
    core.to_enum(:scan, /[#{CONSONANTS}][iu][aeiouy]/).filter_map do
      match = Regexp.last_match
      # In slinkuui, ku is followed by ui. The first u is a full vowel.
      # The same rule permits nu.iork, liiudiies, and xali.uyd.
      next if match[0][2].match?(/[iu]/) && core[match.end(0)]&.match?(/[aeiouy]/)
      # kii before a consonant is glide i + vowel i, so k fails the ban too.
      ['CGV', match[0]]
    end
  end

  def self.elements(doc)
    doc.xpath(ELEMENTS.map { |name| "//#{name}" }.join('|')).reject do |node|
      node.ancestors.any? { |a| ELEMENTS.include?(a.name) } ||
        ([node] + node.ancestors.to_a).any? do |a|
          %w[false maybe].include?(a['valid']) || NON_LOJBAN.include?(a.name)
        end
    end
  end

  def self.text(node)
    return ' ' if %w[false maybe].include?(node['valid']) || NON_LOJBAN.include?(node.name)
    return node.text if node.text? || node.cdata?
    return '' if node.comment?
    value = node.children.map { |child| text(child) }.join
    %w[cmavo sumti selbri].include?(node.name) ? " #{value} " : value
  end

  def self.words(node, state = {})
    tokens = text(node).gsub('--', ' ').delete('[]').scan(/\.?[a-zA-Z][a-zA-Z',.]*/)
    tokens.filter_map do |word|
      core = word.downcase.sub(/\A\.+/, '').sub(/\.+\z/, '')
      if state[:delimiter_next]
        state[:quote] = core.delete(',')
        state.delete(:delimiter_next)
        word # The opening delimiter is Lojban too.
      elsif state[:quote]
        if core.delete(',') == state[:quote]
          state.delete(:quote)
          word # Check the closing delimiter as well.
        end
      else
        if state.delete(:zo)
          # A word quoted with zo cannot start a zoi quote.
        elsif core == "lo'u"
          state[:lohu] = true
        elsif core == "le'u"
          state.delete(:lohu)
        elsif !state[:lohu]
          state[:zo] = true if core == 'zo'
          state[:delimiter_next] = true if %w[zoi la'o].include?(core)
        end
        word
      end
    end
  end

  def self.reviewed_words
    JSON.parse(File.read(REVIEW_FILE)).fetch('words').keys
  end

  def self.failures(doc, path, reviewed = reviewed_words)
    states = {}
    elements(doc).flat_map do |node|
      # A foreign quote can span jbo rows within an example or a table.
      scope = node.ancestors.find { |a| %w[example informaltable].include?(a.name) } || node
      state = node.name == 'jbo' ? (states[scope.path] ||= {}) : {}
      words(node, state).flat_map do |word|
        messages = sequences(word).map { |kind, sequence| "#{kind} #{sequence.inspect} after comma removal" }
        canonical = word.downcase.sub(/\A\.+/, '').sub(/\.+\z/, '')
        if canonical.match?(/[aeiouy],[aeiouy]/) && !reviewed.include?(canonical)
          messages << 'unreviewed comma between vowels'
        end
        messages.map do |message|
          "#{ChapterLint.location(path, node)}: <#{node.name}> #{word.inspect}: #{message}"
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: #{$PROGRAM_NAME} chapters/*.xml" if ARGV.empty?
  failures = ARGV.flat_map { |path| WordSpellings.failures(ChapterLint.read(path), path) }
  puts failures
  exit(failures.empty? ? 0 : 1)
end
