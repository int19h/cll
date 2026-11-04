#!/usr/bin/env ruby
# Detect CGV and unreviewed vowel commas without a book build or parser install.
require_relative 'chapter-lint'
require 'json'

module WordSpellings
  ELEMENTS = %w[jbo jbophrase valsi cmevla cmavo gismu rafsi lujvo diphthong letteral].freeze
  NON_LOJBAN = %w[gloss natlang comment description ipa pronunciation].freeze
  CONSONANTS = 'bcdfgjklmnprstvxz'
  REVIEW_FILE = File.join(__dir__, 'reviewed-comma-words.json')

  # A nucleus is a syllable's vowel or diphthong. This small recognizer uses
  # camxes-std's nucleus, vowel, and diphthong rules, including their lookahead.
  # A two-letter shortcut fails on longer runs such as kiii and kuuuu.
  def self.nucleus?(core, index, memo)
    return memo[index] if memo.key?(index)
    letter = core[index]
    return memo[index] = false unless letter && letter.match?(/[aeiouy]/)
    return memo[index] = true unless nucleus?(core, index + 1, memo)
    pair = core[index, 2]
    last = pair[-1]
    memo[index] = %w[ai au ei oi].include?(pair) && core[index + 2] != last &&
                  !nucleus?(core, index + 2, memo)
  end

  def self.sequences(word)
    core = word.downcase.delete(',')
    memo = {}
    core.chars.each_index.filter_map do |index|
      next unless CONSONANTS.include?(core[index]) && core[index + 1]&.match?(/[iu]/)
      next unless nucleus?(core, index + 2, memo)
      # slinkuui and liiudiies have a full vowel before the glide. In contrast,
      # kii before a consonant is glide i + vowel i, so k fails the ban too.
      ['CGV', core[index, 3]]
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
    # Periods mark pauses between words, including beside zoi delimiters.
    # Keep optional boundary dots for diagnostics, but never join across one.
    tokens = text(node).gsub('--', ' ').delete('[]').scan(/\.?[a-zA-Z][a-zA-Z',]*\.?/)
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
        if canonical.match?(/[aeiouy],+[aeiouy]/) && !reviewed.include?(canonical)
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
