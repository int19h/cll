# frozen_string_literal: true

# Read the tags and classes that a stylesheet excludes from visible blocks.
#
# A rule that sets display, visibility, or content-visibility contributes
# every tag and class in its selector. The scan fails closed when it cannot
# read a construct that could hide such a rule, and the message names the rule.
module HtmlStylesheetScan
  class Unreadable < StandardError; end

  RELEVANT = %w[display visibility content-visibility].freeze
  PAGE_MARGINS = %w[
    top-left-corner top-left top-center top-right top-right-corner
    bottom-left-corner bottom-left bottom-center bottom-right bottom-right-corner
    left-top left-middle left-bottom right-top right-middle right-bottom
  ].freeze

  module_function

  def exclusion(css, source:)
    scanner = Scanner.new(css, source)
    scanner.parse
    [scanner.tags, scanner.classes]
  end

  class Scanner
    attr_reader :tags, :classes

    def initialize(css, source)
      @css = css
      @source = source
      @i = 0
      @n = css.length
      @tags = []
      @classes = []
    end

    def parse
      parse_rules(false)
      skip_noise
      fail!('an extra }') if @i < @n
    end

    private

    def parse_rules(stop_on_brace)
      loop do
        skip_noise
        return if @i >= @n
        if peek == '}'
          return if stop_on_brace
          fail!('an extra }')
        end
        if peek == '@'
          parse_at
        else
          parse_qualified
        end
      end
    end

    def parse_at
      @i += 1
      name = read_ident
      prelude, stop = read_chunk([';', '{'])
      rule = "@#{name}#{prelude}".strip.gsub(/\s+/, ' ')
      rule = rule[0, 80]
      case name
      when 'import'
        fail!(rule)
      when 'charset', 'namespace'
        fail!(rule) unless stop == ';'
        @i += 1
      when 'media', 'supports'
        fail!(rule) unless stop == '{'
        @i += 1
        parse_rules(true)
        skip_noise
        fail!("an unclosed #{rule}") unless peek == '}'
        @i += 1
      when 'page'
        fail!(rule) unless stop == '{'
        @i += 1
        parse_page(rule)
      when 'font-face'
        fail!(rule) unless stop == '{'
        @i += 1
        note_relevant_declarations(read_declarations, '@font-face')
        skip_noise
        fail!('an unclosed @font-face') unless peek == '}'
        @i += 1
      else
        fail!(rule)
      end
    end

    def parse_page(rule)
      loop do
        skip_noise
        fail!("an unclosed #{rule}") if @i >= @n
        if peek == '}'
          @i += 1
          return
        end
        if peek == '@'
          @i += 1
          name = read_ident
          prelude, stop = read_chunk([';', '{'])
          margin = "@#{name}#{prelude}".strip.gsub(/\s+/, ' ')[0, 60]
          fail!(margin) unless PAGE_MARGINS.include?(name)
          fail!(margin) unless stop == '{'
          @i += 1
          note_relevant_declarations(read_declarations, margin)
          skip_noise
          fail!("an unclosed #{margin}") unless peek == '}'
          @i += 1
        else
          prop, value, stop = read_one_declaration
          if RELEVANT.include?(prop)
            shown = value.strip.gsub(/\s+/, ' ')[0, 40]
            fail!("#{rule} { #{prop}: #{shown} }")
          end
          next unless stop == '}'
        end
      end
    end

    def parse_qualified
      flags = {}
      selector, stop = read_chunk(['{'], flags)
      fail!("a rule near #{selector.strip[0, 60]}") unless stop == '{'
      @i += 1
      decls = read_declarations
      skip_noise
      rule = selector.strip.gsub(/\s+/, ' ')
      rule = rule[0, 80]
      fail!("an unclosed rule #{rule}") unless peek == '}'
      @i += 1
      relevant = decls.select { |prop, _value| RELEVANT.include?(prop) }
      return if relevant.empty?
      if flags[:backslash] || flags[:attribute] || flags[:id] || flags[:pseudo] ||
         flags[:universal] || flags[:call] || flags[:namespace]
        fail!("#{rule} { #{relevant[0][0]} }")
      end
      relevant.each do |prop, value|
        if value_unreadable?(value)
          shown = value.strip.gsub(/\s+/, ' ')[0, 40]
          fail!("#{rule} { #{prop}: #{shown} }")
        end
      end
      extract(selector)
    end

    def note_relevant_declarations(decls, rule)
      hit = decls.find { |prop, _value| RELEVANT.include?(prop) }
      return unless hit
      fail!("#{rule} { #{hit[0]} }")
    end

    def read_declarations
      found = []
      loop do
        skip_noise
        break if @i >= @n || peek == '}'
        fail!("an at-rule near #{snippet}") if peek == '@'
        prop, value, stop = read_one_declaration
        found << [prop, value]
        break if stop == '}'
      end
      found
    end

    def read_one_declaration
      prop_text, stop = read_chunk([':', ';', '}'])
      fail!("a declaration near #{prop_text.strip[0, 50]}") unless stop == ':'
      @i += 1
      fail!("a property name near #{prop_text.strip[0, 40]}") if prop_text.include?('\\')
      value, stop = read_chunk([';', '}'])
      @i += 1 if stop == ';'
      [prop_text.strip.downcase, value, stop]
    end

    def extract(selector)
      selector.split(',').each do |part|
        part.gsub(/[>+~]/, ' ').split(/\s+/).each do |token|
          next if token.empty?
          rest = token
          if rest =~ /\A([A-Za-z][A-Za-z0-9_-]*)/
            @tags << Regexp.last_match(1).downcase
            rest = Regexp.last_match.post_match
          end
          while rest =~ /\A\.([A-Za-z_][A-Za-z0-9_-]*)/
            @classes << Regexp.last_match(1)
            rest = Regexp.last_match.post_match
          end
          fail!("a selector #{token} in #{selector.strip[0, 60]}") unless rest.empty?
        end
      end
    end

    def value_unreadable?(text)
      index = 0
      while index < text.length
        char = text[index]
        if char == '"' || char == "'"
          index += 1
          while index < text.length
            if text[index] == '\\'
              index += 2
            elsif text[index] == char
              index += 1
              break
            else
              index += 1
            end
          end
        elsif text[index, 4] =~ /\Avar\s*\(/i
          return true
        elsif char == '\\'
          return true
        else
          index += 1
        end
      end
      false
    end

    def read_chunk(stop_chars, flags = nil)
      text = +''
      paren = 0
      bracket = 0
      while @i < @n
        char = peek
        if char == '/' && peek_at(2) == '/*'
          skip_comment
          text << ' '
          next
        end
        if char == '"' || char == "'"
          text << read_string(char)
          next
        end
        if char == '\\'
          flags[:backslash] = true if flags
          text << char
          @i += 1
          if @i < @n
            text << peek
            @i += 1
          end
          next
        end
        if char == '('
          paren += 1
          flags[:call] = true if flags && paren == 1 && bracket.zero?
          text << char
          @i += 1
          next
        end
        if char == ')'
          paren -= 1 if paren.positive?
          text << char
          @i += 1
          next
        end
        if char == '['
          bracket += 1
          flags[:attribute] = true if flags
          text << char
          @i += 1
          next
        end
        if char == ']'
          bracket -= 1 if bracket.positive?
          text << char
          @i += 1
          next
        end
        if paren.zero? && bracket.zero? && stop_chars.include?(char)
          return [text, char]
        end
        if flags && paren.zero? && bracket.zero?
          flags[:id] = true if char == '#'
          flags[:pseudo] = true if char == ':'
          flags[:universal] = true if char == '*'
          flags[:namespace] = true if char == '|'
        end
        text << char
        @i += 1
      end
      fail!("the end of the stylesheet near #{text[-40, 40]}")
    end

    def read_string(quote)
      text = +''
      text << quote
      @i += 1
      while @i < @n
        char = peek
        @i += 1
        text << char
        if char == '\\'
          fail!("a string near #{text[0, 40]}") if @i >= @n
          text << peek
          @i += 1
        elsif char == quote
          return text
        elsif char == "\n"
          fail!("a string near #{text[0, 40]}")
        end
      end
      fail!("a string near #{text[0, 40]}")
    end

    def read_ident
      start = @i
      fail!("an at-rule name near #{snippet}") unless peek =~ /[A-Za-z]/
      @i += 1
      @i += 1 while @i < @n && peek =~ /[A-Za-z0-9-]/
      @css[start...@i].downcase
    end

    def skip_noise
      loop do
        return if @i >= @n
        if peek =~ /[ \t\r\n\f]/
          @i += 1
        elsif peek == '/' && peek_at(2) == '/*'
          skip_comment
        else
          return
        end
      end
    end

    def skip_comment
      start = @i
      @i += 2
      finish = @css.index('*/', @i)
      sample = @css[start, 40].to_s.gsub(/\s+/, ' ')
      fail!("a comment #{sample}") unless finish
      @i = finish + 2
    end

    def peek
      @css[@i]
    end

    def peek_at(length)
      @css[@i, length]
    end

    def snippet
      @css[@i, 24].to_s.gsub(/\s+/, ' ')
    end

    def fail!(detail)
      raise Unreadable, "#{@source}: cannot read #{detail}"
    end
  end
end
