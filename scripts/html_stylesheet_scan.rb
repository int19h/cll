# frozen_string_literal: true

# Read the tags and classes that a stylesheet excludes from visible blocks,
# and the tags and classes whose whole subtree must stay verbatim.
#
# Only the subject of a selector counts: the last compound, after the last
# combinator. An ancestor in the selector is not affected by the rule.
# Each member of a selector list is separate. ::before, ::after, and ::marker
# style a generated box, so that member is skipped. Any other pseudo-element
# is a rule on the element that remains in that member: it excludes, and a
# preserving white-space value freezes that element. A member with no element
# left fails the scan, and the message names the rule. A pseudo-class still
# fails closed.
# A rule whose display value is a block, a list item, or an internal or
# block-level table box excludes nothing. Those values cannot turn a listed
# block into an inline box. inline-table can, so it still excludes.
# Every other known display value excludes, and so does every known
# visibility or content-visibility value other than visible.
# float excludes unless the winning value is none. position excludes unless
# the winning value is static or relative. relative keeps the box in the
# flow, so a gap beside it still collapses.
# all excludes at initial, inherit, unset, revert, or revert-layer: it
# resets display to inline. Any other all value is invalid and is dropped.
# white-space freezes the subject for pre, pre-wrap, pre-line, and
# break-spaces. normal and nowrap still collapse. white-space-collapse
# freezes the subject unless the winning value is collapse. The property
# is inherited, so the whole subtree is verbatim.
# An invalid value is dropped, as a browser drops it, and does not replace
# an earlier declaration. A value the scan cannot classify fails closed:
# it excludes or freezes. The scan also fails closed when it cannot read a
# construct that could hide such a rule, and the message names the rule.
module HtmlStylesheetScan
  class Unreadable < StandardError; end

  RELEVANT = %w[
    display visibility content-visibility
    white-space white-space-collapse
    float position
    all
  ].freeze
  # list-item generates a block-level principal box. table and the table-*
  # values other than inline-table generate a block-level table box or an
  # internal table box. None of them is an inline-level box, so a line break
  # beside one is not a word space. inline-table is inline-level and is absent
  # from this list.
  HARMLESS_DISPLAY = %w[
    block list-item
    table table-caption table-cell table-column table-column-group
    table-footer-group table-header-group table-row table-row-group
  ].freeze
  # These style a generated box. They do not change the gaps beside the element.
  GENERATED_PSEUDO = %w[before after marker].freeze
  WHITESPACE_EFFECT = %w[pre pre-wrap pre-line break-spaces].freeze
  # collapse is the only safe longhand. normal and nowrap are shorthand
  # keywords, so they are invalid here and must not win.
  COLLAPSE_EFFECT = %w[discard preserve preserve-breaks preserve-spaces break-spaces].freeze
  FLOAT_EFFECT = %w[left right inline-start inline-end].freeze
  POSITION_EFFECT = %w[absolute fixed sticky].freeze
  DISPLAY_EFFECT = %w[
    inline inline-block inline-flex inline-grid inline-table
    flex grid contents none flow-root
    ruby ruby-base ruby-text run-in flow
  ].freeze
  PAGE_MARGINS = %w[
    top-left-corner top-left top-center top-right top-right-corner
    bottom-left-corner bottom-left bottom-center bottom-right bottom-right-corner
    left-top left-middle left-bottom right-top right-middle right-bottom
  ].freeze
  # The last compound, then one or more trailing pseudo-elements.
  PSEUDO_SUBJECT = /\A((?:[A-Za-z][A-Za-z0-9_-]*)?(?:\.[A-Za-z_][A-Za-z0-9_-]*)*)((?:::[A-Za-z][A-Za-z0-9_-]*(?:\([^()]*\))?)+)\z/
  IDENT = /\A[a-z][a-z0-9-]*\z/
  RUNNING = /\Arunning\([a-z0-9_-]*\)\z/

  module_function

  def exclusion(css, source:)
    tags, classes, _preserve_tags, _preserve_classes = classify(css, source: source)
    [tags, classes]
  end

  # tags, classes, preserve_tags, preserve_classes
  def classify(css, source:)
    scanner = Scanner.new(css, source)
    scanner.parse
    [scanner.tags, scanner.classes, scanner.preserve_tags, scanner.preserve_classes]
  end

  class Scanner
    attr_reader :tags, :classes, :preserve_tags, :preserve_classes

    def initialize(css, source)
      @css = css
      @source = source
      @i = 0
      @n = css.length
      @tags = []
      @classes = []
      @preserve_tags = []
      @preserve_classes = []
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
      extract(selector, @tags, @classes) if excludes?(relevant)
      extract(selector, @preserve_tags, @preserve_classes) if preserves?(relevant)
    end

    # The last valid declaration of each importance wins. An invalid
    # declaration is dropped and does not replace an earlier one. An
    # !important declaration wins over one that is not.
    # visibility and content-visibility hide the subject unless the winning
    # value is exactly visible. position: relative stays in normal flow,
    # like static. The book sets it on p.status-note, and excluding that
    # subject would exclude every p.
    def excludes?(decls)
      return true if dangerous?('visibility', winning_value(decls, 'visibility'))
      return true if dangerous?('content-visibility', winning_value(decls, 'content-visibility'))
      return true if dangerous?('float', winning_value(decls, 'float'))
      return true if dangerous?('position', winning_value(decls, 'position'))
      return true if dangerous?('all', winning_value(decls, 'all'))
      return true if dangerous?('display', winning_value(decls, 'display'))
      false
    end

    # Inherited. collapse is safe for the longhand. normal and nowrap are
    # not values of white-space-collapse, so a later one of those does not
    # cancel an earlier preserving value.
    def preserves?(decls)
      dangerous?('white-space', winning_value(decls, 'white-space')) ||
        dangerous?('white-space-collapse', winning_value(decls, 'white-space-collapse'))
    end

    def dangerous?(property, value)
      return false if value.nil?
      return true if value == :unknown
      verdict = classify_value(property, value)
      verdict == :effect || verdict == :unknown
    end

    # :safe collapses or stays in flow. :effect excludes or freezes.
    # :invalid is dropped. :unknown fails closed.
    def classify_value(property, value)
      wide = css_wide_verdict(property, value)
      return wide if wide
      case property
      when 'white-space'
        return :safe if value == 'normal' || value == 'nowrap'
        return :effect if WHITESPACE_EFFECT.include?(value)
      when 'white-space-collapse'
        return :safe if value == 'collapse'
        return :effect if COLLAPSE_EFFECT.include?(value)
      when 'float'
        return :safe if value == 'none'
        return :effect if FLOAT_EFFECT.include?(value)
      when 'position'
        return :safe if value == 'static' || value == 'relative'
        return :effect if POSITION_EFFECT.include?(value) || RUNNING.match?(value)
      when 'display'
        return :safe if HARMLESS_DISPLAY.include?(value)
        return :effect if DISPLAY_EFFECT.include?(value)
      when 'visibility'
        return :safe if value == 'visible'
        return :effect if value == 'hidden' || value == 'collapse'
      when 'content-visibility'
        return :safe if value == 'visible'
        return :effect if value == 'auto' || value == 'hidden'
      when 'all'
        return :invalid if IDENT.match?(value)
        return :unknown
      else
        return :unknown
      end
      return :invalid if IDENT.match?(value)
      :unknown
    end

    # nil when value is not a CSS-wide keyword. initial and unset use the
    # property's initial value when the property is not inherited. inherit,
    # revert, and revert-layer depend on another stylesheet, so they fail
    # closed, except all, which excludes at every CSS-wide keyword.
    def css_wide_verdict(property, value)
      return nil unless value == 'initial' || value == 'inherit' || value == 'unset' ||
                        value == 'revert' || value == 'revert-layer'
      return :effect if property == 'all'
      inherited = property == 'white-space' || property == 'white-space-collapse' ||
                  property == 'visibility'
      case value
      when 'initial'
        property == 'display' ? :effect : :safe
      when 'unset'
        return :unknown if inherited
        property == 'display' ? :effect : :safe
      else
        :unknown
      end
    end

    def winning_value(decls, property)
      normal = nil
      important = nil
      decls.each do |prop, value|
        next unless prop == property
        cleaned = value.strip.gsub(/\s+/, ' ')
        flagged = !cleaned.sub!(/\s*!important\z/i, '').nil?
        cleaned = cleaned.strip.downcase
        verdict = classify_value(property, cleaned)
        next if verdict == :invalid
        chosen = verdict == :unknown ? :unknown : cleaned
        if flagged
          important = chosen
        else
          normal = chosen
        end
      end
      important || normal
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

    def extract(selector, tags, classes)
      split_selector_list(selector).each do |part|
        token = subject_token(part, selector)
        next if token.nil?
        record_compound(token, selector, tags, classes)
      end
    end

    # nil skips a member whose pseudo-elements are all generated boxes.
    # Any other pseudo-element leaves the originating element as the subject.
    def subject_token(part, selector)
      compounds = split_compounds(part)
      fail_selector!(part, selector) if compounds.empty?
      if compounds[0...-1].any? { |item| item.include?(':') }
        fail_selector!(part, selector)
      end
      token = compounds.last
      match = PSEUDO_SUBJECT.match(token)
      if match
        names = match[2].scan(/::([A-Za-z][A-Za-z0-9_-]*)/).flatten
        return nil if names.all? { |name| GENERATED_PSEUDO.include?(name.downcase) }
        fail_selector!(part, selector) if match[1].empty?
        return match[1]
      end
      fail_selector!(part, selector) if token.include?(':')
      token
    end

    def split_selector_list(selector)
      parts = []
      current = +''
      depth = 0
      selector.each_char do |char|
        if char == '('
          depth += 1
          current << char
        elsif char == ')'
          depth -= 1 if depth.positive?
          current << char
        elsif char == ',' && depth.zero?
          parts << current
          current = +''
        else
          current << char
        end
      end
      parts << current
      parts
    end

    def split_compounds(part)
      compounds = []
      current = +''
      depth = 0
      part.each_char do |char|
        if char == '('
          depth += 1
          current << char
        elsif char == ')'
          depth -= 1 if depth.positive?
          current << char
        elsif depth.zero? && (char == '>' || char == '+' || char == '~' || char.match?(/\s/))
          compounds << current unless current.empty?
          current = +''
        else
          current << char
        end
      end
      compounds << current unless current.empty?
      compounds
    end

    def fail_selector!(part, selector)
      shown_part = part.strip.gsub(/\s+/, ' ')[0, 60]
      shown_rule = selector.strip.gsub(/\s+/, ' ')[0, 80]
      fail!("a selector #{shown_part} in #{shown_rule}")
    end

    def record_compound(token, selector, tags, classes)
      rest = token
      if rest =~ /\A([A-Za-z][A-Za-z0-9_-]*)/
        tags << Regexp.last_match(1).downcase
        rest = Regexp.last_match.post_match
      end
      while rest =~ /\A\.([A-Za-z_][A-Za-z0-9_-]*)/
        classes << Regexp.last_match(1)
        rest = Regexp.last_match.post_match
      end
      fail!("a selector #{token} in #{selector.strip[0, 60]}") unless rest.empty?
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
          # ::part() and ::slotted() belong to the pseudo-element. :is() and
          # :not() still fail closed.
          if flags && paren == 1 && bracket.zero? && !text.match?(/::[A-Za-z][A-Za-z0-9_-]*\z/)
            flags[:call] = true
          end
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
          if char == ':' && peek_at(2) == '::'
            text << '::'
            @i += 2
            next
          end
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
