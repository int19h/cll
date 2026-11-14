# frozen_string_literal: true

# Read the tags and classes that a stylesheet excludes from visible blocks,
# and the tags and classes whose whole subtree must stay verbatim.
#
# Only the subject of a selector counts: the last compound, after the last
# combinator. An ancestor in the selector is not affected by the rule.
# Each member of a selector list is separate. ::before, ::after, and ::marker
# style a generated box, so that member is skipped. Any other pseudo-element
# on a relevant rule fails the scan, and the message names the rule. A
# pseudo-class still fails closed. :empty is the exception: the element has
# no text, so the rule cannot change a gap, and the subject is skipped.
# An ancestor that uses :empty still fails closed.
# For each relevant property, only the values in SAFE_VALUE are safe. Every
# other well-formed value is unsafe: it excludes the subject, and for
# white-space or white-space-collapse it also freezes the subtree. That
# includes a keyword the list does not name, and every value of all.
# A declaration is dropped only when its value is clearly malformed, such
# as an empty value or unbalanced brackets. A dropped declaration does not
# replace an earlier one. The scan also fails closed when it cannot read a
# construct that could hide a rule, and the message names the rule.
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
  # Any other pseudo-element fails the scan.
  GENERATED_PSEUDO = %w[before after marker].freeze
  # Known-safe values, shared with the inline style check in HtmlFormat.
  # A well-formed value that is not listed is unsafe. all has no safe value:
  # every CSS-wide keyword resets display to inline.
  SAFE_VALUE = {
    'white-space' => %w[normal nowrap].freeze,
    'white-space-collapse' => %w[collapse].freeze,
    'float' => %w[none].freeze,
    'position' => %w[static relative].freeze,
    'display' => HARMLESS_DISPLAY,
    'visibility' => %w[visible].freeze,
    'content-visibility' => %w[visible].freeze,
    'all' => [].freeze
  }.freeze
  PAGE_MARGINS = %w[
    top-left-corner top-left top-center top-right top-right-corner
    bottom-left-corner bottom-left bottom-center bottom-right bottom-right-corner
    left-top left-middle left-bottom right-top right-middle right-bottom
  ].freeze
  # The last compound, then one or more trailing pseudo-elements.
  PSEUDO_SUBJECT = /\A((?:[A-Za-z][A-Za-z0-9_-]*)?(?:\.[A-Za-z_][A-Za-z0-9_-]*)*)((?:::[A-Za-z][A-Za-z0-9_-]*(?:\([^()]*\))?)+)\z/

  module_function

  # :safe when value is listed for property. :drop when the value cannot be
  # a CSS value (empty, or brackets that do not balance outside strings).
  # :unsafe for every other value, including a keyword that is not listed.
  def value_verdict(property, value)
    return :drop if malformed_value?(value)
    listed = SAFE_VALUE[property]
    return :unsafe if listed.nil?
    listed.include?(value) ? :safe : :unsafe
  end

  def malformed_value?(value)
    return true if value.nil? || value.empty?
    round = 0
    square = 0
    curly = 0
    index = 0
    while index < value.length
      char = value[index]
      if char == '"' || char == "'"
        index += 1
        while index < value.length
          if value[index] == '\\'
            index += 2
            next
          end
          break if value[index] == char
          index += 1
        end
        return true if index >= value.length
        index += 1
        next
      end
      case char
      when '('
        round += 1
      when ')'
        return true if round.zero?
        round -= 1
      when '['
        square += 1
      when ']'
        return true if square.zero?
        square -= 1
      when '{'
        curly += 1
      when '}'
        return true if curly.zero?
        curly -= 1
      end
      index += 1
    end
    round != 0 || square != 0 || curly != 0
  end

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
      reject_disallowed_pseudos(selector, rule)
      extract(selector, @tags, @classes) if excludes?(relevant)
      extract(selector, @preserve_tags, @preserve_classes) if preserves?(relevant)
    end

    # The last well-formed declaration of each importance wins. A malformed
    # value is dropped and does not replace an earlier one. An !important
    # declaration wins over one that is not. Unsafe means the value is not
    # in SAFE_VALUE. position: relative stays in normal flow, like static.
    # The book sets it on p.status-note, and excluding that subject would
    # exclude every p.
    def excludes?(decls)
      %w[visibility content-visibility float position all display].any? do |property|
        winning_value(decls, property) == :unsafe
      end
    end

    # Inherited. Only normal and nowrap are safe for the shorthand, and
    # only collapse is safe for the longhand. Any other well-formed value
    # freezes the subject.
    def preserves?(decls)
      winning_value(decls, 'white-space') == :unsafe ||
        winning_value(decls, 'white-space-collapse') == :unsafe
    end

    # :safe, :unsafe, or nil when every declaration of this property was
    # malformed. HtmlStylesheetScan.value_verdict is the shared table.
    def winning_value(decls, property)
      normal = nil
      important = nil
      decls.each do |prop, value|
        next unless prop == property
        cleaned = value.strip.gsub(/\s+/, ' ')
        flagged = !cleaned.sub!(/\s*!important\z/i, '').nil?
        cleaned = cleaned.strip.downcase
        verdict = HtmlStylesheetScan.value_verdict(property, cleaned)
        next if verdict == :drop
        if flagged
          important = verdict
        else
          normal = verdict
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

    # A relevant rule that uses any pseudo-element other than ::before,
    # ::after, or ::marker cannot be scanned. The message names the rule.
    def reject_disallowed_pseudos(selector, rule)
      split_selector_list(selector).each do |part|
        split_compounds(part).each do |token|
          next unless token.include?('::')
          next if generated_pseudo_only?(token)
          fail!(rule)
        end
      end
    end

    # nil skips a member whose pseudo-elements are all generated boxes.
    def subject_token(part, selector)
      compounds = split_compounds(part)
      fail_selector!(part, selector) if compounds.empty?
      if compounds[0...-1].any? { |item| item.include?(':') }
        fail_selector!(part, selector)
      end
      token = compounds.last
      return nil if generated_pseudo_only?(token)
      return nil if empty_pseudo_only?(token)
      fail_selector!(part, selector) if token.include?(':')
      token
    end

    # :empty matches no element that contains text. Dropping the subject
    # keeps the element in normal block layout. Any other pseudo stays.
    def empty_pseudo_only?(token)
      stripped = token.sub(/:empty\z/, '')
      return false if stripped == token || stripped.empty? || stripped.include?(':')
      true
    end

    def generated_pseudo_only?(token)
      match = PSEUDO_SUBJECT.match(token)
      return false unless match
      names = match[2].scan(/::([A-Za-z][A-Za-z0-9_-]*)/).flatten
      !names.empty? && names.all? { |name| GENERATED_PSEUDO.include?(name.downcase) }
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
          # :empty does not mark the rule unreadable. :emptyfoo still does.
          if char == ':' && @css[@i, 6] == ':empty'
            nxt = @css[@i + 6]
            if nxt.nil? || nxt !~ /[A-Za-z0-9_-]/
              text << ':empty'
              @i += 6
              next
            end
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
