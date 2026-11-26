#!/usr/bin/env ruby
# Derive and check Appendix A's per-section hidden glossary word lists (issue #351).
#
# Convention (see docs/markup-tags.md):
#   - Each section that directly owns a role="parallel-text" table has one
#     alphabetically sorted <para role="display-none"> word list.
#   - A single-token compound cmavo with its own entry in dictionary/all_words.xml
#     stays one <valsi> in its dictionary spelling (as docs/markup-tags.md says
#     for doinai, .uinai, and naku); a compound cmavo with no dictionary entry
#     is split morphologically into its component cmavo.
#   - Names keep their dotted forms used in the section (or dotside .name. if
#     written bare).
#   - valid="maybe" is derived from dictionary/all_words.xml and the reviewed
#     agreement-rule exceptions file (scripts/a01-word-list-exceptions.json):
#     no dictionary entry or a listed exception gets valid="maybe"; every other
#     word links plainly.
#
# Usage:
#   ruby scripts/lint-a01-word-lists.rb [--dictionary PATH] [--exceptions PATH] chapters/a01.xml
#   ruby scripts/lint-a01-word-lists.rb --write [--dictionary PATH] [--exceptions PATH] chapters/a01.xml
require 'json'
require 'nokogiri'
require 'optparse'
require 'set'
require_relative 'chapter-lint'
require_relative 'util'

module A01WordLists
  DEFAULT_DICTIONARY = File.expand_path('../dictionary/all_words.xml', __dir__)
  DEFAULT_EXCEPTIONS = File.expand_path('a01-word-list-exceptions.json', __dir__)
  CONSONANT_RE = /[bcdfgjklmnprstvxz]/
  XML_WS_RE = /[ \t\r\n]+/

  # Split an XML attribute token list on XML 1.0 S whitespace only (excludes NBSP).
  def self.xml_tokens(value)
    value.to_s.split(XML_WS_RE).reject(&:empty?)
  end

  def self.has_xml_role?(node, token)
    node.element? && xml_tokens(node['role']).include?(token)
  end

  # Load dictionary/all_words.xml using the same non-empty definition and
  # outer-pause-dot rules as scripts/generate_glossary.rb.
  def self.load_dictionary(path = DEFAULT_DICTIONARY)
    doc = Nokogiri::XML(File.open(path)) { |c| c.strict.nonet }
    defined = Set.new
    doc.xpath('//valsi').each do |entry|
      defn = entry.xpath('.//definition').text.strip
      defined << entry['word'] unless defn.empty?
    end
    defined.group_by { |word| bare_spelling(word) }
  end

  # Load reviewed agreement-rule exceptions: { section_id => { word => reason } }.
  def self.load_exceptions(path = DEFAULT_EXCEPTIONS)
    data = JSON.parse(File.read(path, encoding: 'UTF-8'))
    sections = data.fetch('sections')
    raise "#{path}: \"sections\" must be a JSON object" unless sections.is_a?(Hash)
    sections.each_with_object({}) do |(sid, words), out|
      raise "#{path}: section #{sid.inspect} must map to a JSON object" unless words.is_a?(Hash)
      words.each do |word, reason|
        unless reason.is_a?(String) && !reason.strip.empty?
          raise "#{path}: exception #{sid}/#{word} must have a non-empty reason string"
        end
      end
      out[sid] = words
    end
  end

  # Canonical dictionary spelling matching word (exact or differing only in
  # outer pause dots, with identical slug), or nil when none exists.
  def self.dictionary_spelling(word, dict_by_bare)
    slug = slugify(word)
    cands = dict_by_bare.fetch(bare_spelling(word), []).select { |c| slugify(c) == slug }
    return nil if cands.empty?
    cands.include?(word) ? word : cands.sort.first
  end

  # True when every non-empty dot-separated segment ends in a consonant
  # (cmevla, including multi-word names like ".maikl.turni'anskis.").
  def self.cmevla_token?(token)
    bare = bare_spelling(token).downcase
    return false if bare.empty?
    segs = bare.split('.')
    return false if segs.any?(&:empty?)
    segs.all? { |seg| seg.delete(',').match?(/[bcdfgjklmnprstvxz]\z/) }
  end

  # Split one dot-free segment into simple Lojban cmavo units per PEG
  # morphology (no consonant clusters, no CGV, Cy/y only before a pause so
  # CVCy lujvo like bacyde'i are never split as cmavo). Returns nil if the
  # segment is not a sequence of valid cmavo.
  def self.split_cmavo_segment(segment)
    core = segment.downcase.delete(',')
    return nil if core.empty?
    return nil if core.match?(/[bcdfgjklmnprstvxz]\z/)
    return nil if core.match?(/[bcdfgjklmnprstvxz]{2}/)

    units = []
    i = 0
    while i < core.length
      start = i
      has_c = false
      if core[i].match?(CONSONANT_RE)
        has_c = true
        i += 1
        if core[i] == 'y'
          i += 1 while core[i] == 'y'
          # A Cy cmavo must end at a pause; otherwise CV+Cy+... is a CVCy lujvo.
          return nil unless i == core.length
          units << core[start...i]
          next
        end
      elsif !units.empty?
        return nil
      elsif core[i] == 'y'
        while i < core.length && (core[i] == 'y' || (core[i] == "'" && core[i + 1] == 'y'))
          i += 1
        end
        return nil unless i == core.length
        units << core[start...i]
        next
      end

      vstart = i
      while i < core.length
        if core[i].match?(/[aeiou]/)
          i += 1
        elsif core[i] == "'" && core[i + 1]&.match?(/[aeiouy]/)
          i += 2
        else
          break
        end
      end
      vbody = core[vstart...i]
      return nil if vbody.empty? || vbody.start_with?("'") || vbody.end_with?("'") || vbody.include?("''")
      return nil if vbody.include?('y') && i != core.length

      syls = vbody.split("'")
      valid = syls.each_with_index.all? do |syl, idx|
        if idx == 0 && !has_c
          syl.match?(/\A(?:[iu](?:ai|ei|oi|au|[aeiou])|ai|ei|oi|au|[aeiou])\z/)
        else
          syl.match?(/\A(?:ai|ei|oi|au|[aeiouy])\z/)
        end
      end
      return nil unless valid

      units << core[start...i]
    end
    units
  end

  # Split a compound cmavo (possibly with internal pause dots like vy.ri)
  # into its simple cmavo units, or return nil if not a cmavo compound.
  def self.split_cmavo_compound(token)
    return nil if token.sub(/\.+\z/, '').match?(/[bcdfgjklmnprstvxz]\z/i)
    bare = bare_spelling(token)
    return nil if bare.empty?
    segments = bare.split('.')
    return nil if segments.any?(&:empty?)
    parts = []
    segments.each do |seg|
      units = split_cmavo_segment(seg)
      return nil unless units
      parts.concat(units)
    end
    parts.size > 1 ? parts : nil
  end

  # Visible text of a table cell, skipping indexterm, anchor, and display-none subtrees.
  def self.cell_text(cell)
    texts = []
    cell.traverse do |node|
      next unless node.text?
      excluded = node.ancestors.take_while { |a| a != cell }.any? do |a|
        %w[indexterm anchor].include?(a.name) || has_xml_role?(a, 'display-none')
      end
      texts << node.text unless excluded
    end
    texts.join
  end

  # Extract Lojban tokens from the first column of the given parallel-text tables,
  # skipping non-Lojban payloads of zoi / la'o quotes (while keeping their Lojban delimiters).
  def self.tables_tokens(tables)
    raw = []
    tables.each do |table|
      table.xpath('./thead/tr | ./tbody/tr | ./tr').each do |row|
        first_cell = row.element_children.first
        next unless first_cell
        raw.concat(cell_text(first_cell).strip.split(/\s+/))
      end
    end

    state = {}
    raw.filter_map do |tok|
      next if tok.empty?
      tok = tok.downcase
      core = bare_spelling(tok)
      if state[:delimiter_next]
        state[:quote] = core.delete(',')
        state.delete(:delimiter_next)
        tok
      elsif state[:quote]
        if core.delete(',') == state[:quote]
          state.delete(:quote)
          tok
        end
      else
        if state.delete(:zo)
          # Quoted word cannot open a zoi/la'o quote, but is itself a Lojban word.
        elsif core == "lo'u"
          state[:lohu] = true
        elsif core == "le'u"
          state.delete(:lohu)
        elsif !state[:lohu]
          state[:zo] = true if core == 'zo'
          state[:delimiter_next] = true if %w[zoi la'o].include?(core)
        end
        tok
      end
    end
  end

  # Derive the expected sorted list of [word, has_dict_entry] pairs for one section's
  # directly-owned parallel-text tables.
  def self.derive_section_words(tables, dict_by_bare)
    raw_tokens = tables_tokens(tables)

    # Split mixed dot-joined tokens (such as "la.teris.") whose segments are not all cmevla,
    # while keeping multi-word cmevla (such as ".maikl.turni'anskis.") intact.
    tokens = raw_tokens.flat_map do |tok|
      bare = bare_spelling(tok)
      if bare.include?('.') && !cmevla_token?(tok) && !dictionary_spelling(tok, dict_by_bare)
        segs = bare.split('.').reject(&:empty?)
        if segs.any? { |s| s.delete(',').match?(/[bcdfgjklmnprstvxz]\z/) }
          segs.map { |s| s.delete(',').match?(/[bcdfgjklmnprstvxz]\z/) ? ".#{s}." : s }
        else
          [tok]
        end
      else
        [tok]
      end
    end

    cmevla_spellings = Hash.new { |h, k| h[k] = [] }
    tokens.each do |tok|
      cmevla_spellings[bare_spelling(tok)] << tok if cmevla_token?(tok)
    end

    entries = {}
    tokens.each do |tok|
      if cmevla_token?(tok)
        bare = bare_spelling(tok)
        seen = cmevla_spellings[bare].uniq
        dotted = seen.select { |s| s.start_with?('.') || s.end_with?('.') }
        chosen = if dotted.any?
                   dotted.max_by { |s| [(s.start_with?('.') ? 1 : 0) + (s.end_with?('.') ? 1 : 0), s] }
                 else
                   ".#{bare}."
                 end
        entries[chosen] = !dictionary_spelling(chosen, dict_by_bare).nil?
      elsif (canonical = dictionary_spelling(tok, dict_by_bare))
        entries[canonical] = true
      elsif (parts = split_cmavo_compound(tok))
        parts.each do |part|
          if (canonical = dictionary_spelling(part, dict_by_bare))
            entries[canonical] = true
          else
            entries[part] = false
          end
        end
      else
        entries[bare_spelling(tok)] = false
      end
    end

    entries.sort_by { |word, _| word }
  end

  def self.section_id(section)
    section['id'] || section['xml:id'] || '(unnamed section)'
  end

  # Nearest enclosing <section> ancestor (ancestor::section[1]), or nil.
  def self.nearest_section(node)
    node.ancestors.find { |a| a.element? && a.name == 'section' }
  end

  # Group parallel-text tables and display-none paragraphs by their nearest enclosing <section>.
  def self.group_by_nearest_section(doc)
    tables_by_section = Hash.new { |h, k| h[k] = [] }
    unowned_tables = []
    doc.xpath('//informaltable').each do |table|
      next unless has_xml_role?(table, 'parallel-text')
      owner = nearest_section(table)
      if owner
        tables_by_section[owner] << table
      else
        unowned_tables << table
      end
    end

    lists_by_section = Hash.new { |h, k| h[k] = [] }
    unowned_lists = []
    doc.xpath('//para').each do |para|
      next unless has_xml_role?(para, 'display-none')
      owner = nearest_section(para)
      if owner
        lists_by_section[owner] << para
      else
        unowned_lists << para
      end
    end

    [tables_by_section, unowned_tables, lists_by_section, unowned_lists]
  end

  # Lint one chapter file (expected to be chapters/a01.xml or a fixture appendix).
  def self.lint_file(path, dict_by_bare, exceptions = {})
    doc = ChapterLint.read(path)
    errors = []

    tables_by_section, unowned_tables, lists_by_section, unowned_lists = group_by_nearest_section(doc)

    unowned_tables.each do |table|
      errors << "#{path}:#{ChapterLint.source_line(table)}: parallel-text <informaltable> appears outside any <section>"
    end

    unowned_lists.each do |para|
      errors << "#{path}:#{ChapterLint.source_line(para)}: <para role=\"display-none\"> appears outside a section with a parallel-text table"
    end

    parallel_sections = doc.xpath('//section').select { |sec| !tables_by_section[sec].empty? }
    parallel_set = parallel_sections.to_set

    lists_by_section.each do |sec, paras|
      next if parallel_set.include?(sec)
      paras.each do |para|
        errors << "#{path}:#{ChapterLint.source_line(para)}: <para role=\"display-none\"> appears outside a section with a parallel-text table"
      end
    end

    parallel_ids = Set.new
    parallel_sections.each do |sec|
      sid = section_id(sec)
      parallel_ids << sid
      sec_exceptions = exceptions.fetch(sid, {})
      expected = derive_section_words(tables_by_section[sec], dict_by_bare)
      expected_map = expected.to_h

      # Validate reviewed exceptions for this section.
      sec_exceptions.each_key do |word|
        if !expected_map.key?(word)
          errors << "#{path}:#{ChapterLint.source_line(sec)}: exceptions list names #{word.inspect} for section #{sid}, which does not use that word"
        elsif !expected_map[word]
          errors << "#{path}:#{ChapterLint.source_line(sec)}: exceptions list names #{word.inspect} for section #{sid}, which already lacks a dictionary entry"
        end
      end

      lists = lists_by_section[sec]
      if lists.empty?
        errors << "#{path}:#{ChapterLint.source_line(sec)}: section #{sid} has a parallel-text table but no hidden word list (<para role=\"display-none\">)"
        next
      elsif lists.size > 1
        errors << "#{path}:#{ChapterLint.source_line(lists[1])}: section #{sid} has #{lists.size} hidden word lists (expected 1)"
        next
      end

      list = lists.first
      list_line = ChapterLint.source_line(list)
      list.children.each do |child|
        if child.element? && child.name != 'valsi'
          errors << "#{path}:#{ChapterLint.source_line(child)}: section #{sid} hidden word list contains unexpected <#{child.name}>"
        elsif child.text? && !child.text.strip.empty?
          errors << "#{path}:#{list_line}: section #{sid} hidden word list contains stray text #{child.text.strip.inspect}"
        end
      end

      actual_nodes = list.element_children.select { |c| c.name == 'valsi' }
      actual_words = actual_nodes.map(&:text)

      seen = Set.new
      actual_nodes.each do |v|
        if seen.include?(v.text)
          errors << "#{path}:#{ChapterLint.source_line(v)}: section #{sid} hidden word list duplicates #{v.text.inspect}"
        end
        seen << v.text
      end

      if actual_words != actual_words.sort
        errors << "#{path}:#{list_line}: section #{sid} hidden word list is not sorted alphabetically"
      end

      actual_map = actual_nodes.each_with_object({}) { |v, h| h[v.text] ||= v }

      (expected_map.keys - actual_map.keys).sort.each do |word|
        want_maybe = !expected_map[word] || sec_exceptions.key?(word)
        hint = want_maybe ? ' (with valid="maybe")' : ''
        errors << "#{path}:#{list_line}: section #{sid} hidden word list is missing #{word.inspect}#{hint}"
      end

      (actual_map.keys - expected_map.keys).sort.each do |word|
        v = actual_map[word]
        errors << "#{path}:#{ChapterLint.source_line(v)}: section #{sid} hidden word list has unused or non-canonical word #{word.inspect}"
      end

      actual_nodes.each do |v|
        word = v.text
        next unless expected_map.key?(word)
        vline = ChapterLint.source_line(v)
        valid_attr = v['valid']
        has_entry = expected_map[word]
        is_exception = sec_exceptions.key?(word)
        want_maybe = !has_entry || is_exception
        if valid_attr == 'false'
          errors << "#{path}:#{vline}: section #{sid} hidden word list marks #{word.inspect} valid=\"false\" (use valid=\"maybe\" or omit)"
        elsif !valid_attr.nil? && valid_attr != 'maybe'
          errors << "#{path}:#{vline}: section #{sid} hidden word list has unexpected valid=#{valid_attr.inspect} on #{word.inspect}"
        elsif want_maybe && valid_attr != 'maybe'
          if !has_entry
            errors << "#{path}:#{vline}: section #{sid} hidden word list entry #{word.inspect} has no dictionary entry and must carry valid=\"maybe\""
          else
            errors << "#{path}:#{vline}: section #{sid} hidden word list entry #{word.inspect} is a reviewed agreement-rule exception and must carry valid=\"maybe\""
          end
        elsif !want_maybe && valid_attr == 'maybe'
          errors << "#{path}:#{vline}: section #{sid} hidden word list entry #{word.inspect} has a dictionary entry and is not in the reviewed exceptions list, so it must not carry valid=\"maybe\""
        end
      end
    end

    exceptions.each_key do |sid|
      next if parallel_ids.include?(sid)
      errors << "#{path}:1: exceptions list names unknown or non-parallel-text section #{sid.inspect}"
    end

    errors
  end

  def self.format_list(expected, sec_exceptions, indent)
    inner = "#{indent}  "
    lines = ["#{indent}<para role=\"display-none\">"]
    expected.each do |word, has_entry|
      maybe = !has_entry || sec_exceptions.key?(word)
      attr = maybe ? ' valid="maybe"' : ''
      lines << "#{inner}<valsi#{attr}>#{word}</valsi>"
    end
    lines << "#{indent}</para>"
    lines.join("\n")
  end

  # Parse a start tag's attributes into a hash { attr_name => raw_value }.
  def self.parse_tag_attrs(attr_str)
    attrs = {}
    attr_str.scan(/([A-Za-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/) do |k, dq, sq|
      attrs[k] = dq.nil? ? sq : dq
    end
    attrs
  end

  # Balanced-tag scanner over raw XML source that records every <section> in
  # document preorder, its direct-child <title> end offset and indentation,
  # and the exact source spans of every <para role="...display-none..."> whose
  # nearest enclosing <section> is that section. Skips comments, CDATA, and PIs.
  SectionSpan = Struct.new(:open_start, :open_end, :first_title_end, :indent, :hidden_para_spans, keyword_init: true)

  def self.scan_sections(source)
    sections = []
    section_stack = []
    # Track open <title> or hidden <para> only when directly owned by top of section_stack.
    open_title = nil   # { section: SectionSpan, depth: Integer, indent: String }
    open_hidden = nil  # { section: SectionSpan, start: Integer, depth: Integer }
    elem_depth = 0
    sec_depths = []    # elem_depth at each open <section>

    pos = 0
    len = source.length
    while pos < len
      lt = source.index('<', pos)
      break unless lt

      if source[lt, 4] == '<!--'
        close = source.index('-->', lt + 4)
        raise 'Unterminated XML comment' unless close
        pos = close + 3
        next
      elsif source[lt, 9] == '<![CDATA['
        close = source.index(']]>', lt + 9)
        raise 'Unterminated CDATA section' unless close
        pos = close + 3
        next
      elsif source[lt, 2] == '<?'
        close = source.index('?>', lt + 2)
        raise 'Unterminated processing instruction' unless close
        pos = close + 2
        next
      elsif source[lt, 2] == '<!'
        # DOCTYPE or declaration (handle optional internal subset [...])
        i = lt + 2
        in_bracket = false
        quote = nil
        while i < len
          ch = source[i]
          if quote
            quote = nil if ch == quote
          elsif ch == '"' || ch == "'"
            quote = ch
          elsif ch == '['
            in_bracket = true
          elsif ch == ']'
            in_bracket = false
          elsif ch == '>' && !in_bracket
            break
          end
          i += 1
        end
        pos = i + 1
        next
      end

      # Find matching '>' outside attribute quotes.
      i = lt + 1
      quote = nil
      while i < len
        ch = source[i]
        if quote
          quote = nil if ch == quote
        elsif ch == '"' || ch == "'"
          quote = ch
        elsif ch == '>'
          break
        end
        i += 1
      end
      raise 'Unterminated XML tag' unless i < len
      tag_end = i + 1
      tag_body = source[(lt + 1)...i]

      if tag_body.start_with?('/')
        raw_name = tag_body[1..].strip
        local = raw_name.include?(':') ? raw_name.split(':', 2).last : raw_name
        if open_hidden && elem_depth == open_hidden[:depth] && local == 'para'
          span_end = tag_end
          if source[span_end..] =~ /\A[ \t]*\r?\n/
            span_end += Regexp.last_match(0).length
          end
          open_hidden[:section].hidden_para_spans << [open_hidden[:start], span_end]
          open_hidden = nil
        end
        if open_title && elem_depth == open_title[:depth] && local == 'title'
          t_end = tag_end
          if source[t_end..] =~ /\A[ \t]*\r?\n/
            t_end += Regexp.last_match(0).length
          end
          open_title[:section].first_title_end ||= t_end
          open_title[:section].indent ||= open_title[:indent]
          open_title = nil
        end
        if !sec_depths.empty? && elem_depth == sec_depths.last && local == 'section'
          sec_depths.pop
          section_stack.pop
        end
        elem_depth -= 1
      else
        self_closing = tag_body.end_with?('/')
        inner = self_closing ? tag_body[0...-1] : tag_body
        m = inner.match(/\A([A-Za-z_:][\w:.-]*)(.*)\z/m)
        unless m
          pos = tag_end
          next
        end
        raw_name = m[1]
        attr_str = m[2]
        local = raw_name.include?(':') ? raw_name.split(':', 2).last : raw_name

        elem_depth += 1 unless self_closing

        if local == 'section'
          line_start = (source.rindex("\n", lt) || -1) + 1
          sec_indent = source[line_start...lt][/\A[ \t]*/]
          frame = SectionSpan.new(
            open_start: lt,
            open_end: tag_end,
            first_title_end: nil,
            indent: nil,
            hidden_para_spans: []
          )
          sections << frame
          unless self_closing
            section_stack << frame
            sec_depths << elem_depth
          end
          frame.indent = "#{sec_indent}  " if self_closing
        elsif local == 'title' && !section_stack.empty? && !open_title
          # Direct child <title> of the current innermost <section>.
          parent_depth = sec_depths.last
          is_direct = self_closing ? (elem_depth == parent_depth) : (elem_depth == parent_depth + 1)
          if is_direct && section_stack.last.first_title_end.nil?
            line_start = (source.rindex("\n", lt) || -1) + 1
            title_indent = source[line_start...lt]
            title_indent = title_indent.match?(/\A[ \t]*\z/) ? title_indent : '    '
            if self_closing
              t_end = tag_end
              t_end += Regexp.last_match(0).length if source[t_end..] =~ /\A[ \t]*\r?\n/
              section_stack.last.first_title_end = t_end
              section_stack.last.indent = title_indent
            else
              open_title = { section: section_stack.last, depth: elem_depth, indent: title_indent }
            end
          end
        elsif local == 'para' && !section_stack.empty? && !open_hidden
          attrs = parse_tag_attrs(attr_str)
          if xml_tokens(attrs['role']).include?('display-none')
            line_start = (source.rindex("\n", lt) || -1) + 1
            span_start = source[line_start...lt].match?(/\A[ \t]*\z/) ? line_start : lt
            if self_closing
              span_end = tag_end
              span_end += Regexp.last_match(0).length if source[span_end..] =~ /\A[ \t]*\r?\n/
              section_stack.last.hidden_para_spans << [span_start, span_end]
            else
              open_hidden = { section: section_stack.last, start: span_start, depth: elem_depth }
            end
          end
        end
      end

      pos = tag_end
    end

    sections
  end

  # Rewrite the hidden word lists of path in place, preserving all other XML formatting.
  # Every valid="maybe" mark is derived purely from dictionary/all_words.xml and exceptions.
  def self.rewrite_file(path, dict_by_bare, exceptions = {})
    source = File.read(path, encoding: 'UTF-8')
    doc = ChapterLint.read(path)
    tables_by_section, unowned_tables, _lists_by_section, _unowned_lists = group_by_nearest_section(doc)

    unless unowned_tables.empty?
      t = unowned_tables.first
      raise "#{path}:#{ChapterLint.source_line(t)}: parallel-text <informaltable> appears outside any <section>"
    end

    doc_sections = doc.xpath('//section').to_a
    spans = scan_sections(source)
    unless doc_sections.size == spans.size
      raise "#{path}: section count mismatch between XML parser (#{doc_sections.size}) and source scanner (#{spans.size})"
    end

    edits = []
    doc_sections.each_with_index do |sec, idx|
      tables = tables_by_section[sec]
      next if tables.empty?

      sid = section_id(sec)
      sec_exceptions = exceptions.fetch(sid, {})
      expected = derive_section_words(tables, dict_by_bare)
      frame = spans[idx]
      indent = frame.indent || '    '
      list_xml = format_list(expected, sec_exceptions, indent)

      if !frame.hidden_para_spans.empty?
        first_start, first_end = frame.hidden_para_spans.first
        edits << [first_start, first_end, "#{list_xml}\n"]
        frame.hidden_para_spans.drop(1).each do |dup_start, dup_end|
          edits << [dup_start, dup_end, '']
        end
      else
        unless frame.first_title_end
          raise "#{path}:#{ChapterLint.source_line(sec)}: section #{sid} has no direct <title> element"
        end
        edits << [frame.first_title_end, frame.first_title_end, "#{list_xml}\n"]
      end
    end

    # Verify edits are non-overlapping and splice in reverse source order.
    sorted = edits.sort_by { |s, e, _| [s, e] }
    sorted.each_cons(2) do |(_s1, e1, _), (s2, _e2, _)|
      raise "#{path}: overlapping edit spans (#{e1} > #{s2})" if e1 > s2
    end

    updated = source.dup
    sorted.reverse_each do |s, e, replacement|
      updated[s...e] = replacement
    end

    File.write(path, updated, encoding: 'UTF-8') if updated != source
    updated != source
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    write: false,
    dictionary: A01WordLists::DEFAULT_DICTIONARY,
    exceptions: A01WordLists::DEFAULT_EXCEPTIONS
  }
  parser = OptionParser.new do |opts|
    opts.banner = <<~BANNER
      Usage: #{$PROGRAM_NAME} [--write] [--dictionary PATH] [--exceptions PATH] FILE...

      Derive and check Appendix A's per-section hidden glossary word lists.

      Convention:
        - Each section owning a role="parallel-text" table has one alphabetically
          sorted <para role="display-none"> list holding the words in its Lojban
          column (<thead> and <tbody>).
        - Compound cmavo: a single-token compound with its own entry in
          dictionary/all_words.xml stays one word in its dictionary spelling
          (matching docs/markup-tags.md's rule for doinai, .uinai, and naku);
          a compound with no dictionary entry is split morphologically into its
          component cmavo.
        - Names keep their dotted form from the section (or dotside .name. if
          written bare).
        - valid="maybe" is derived from dictionary/all_words.xml and the reviewed
          exceptions list (scripts/a01-word-list-exceptions.json): words with no
          dictionary entry and listed agreement-rule exceptions carry valid="maybe";
          every other word links plainly.

      Options:
    BANNER
    opts.on('--write', 'Regenerate each parallel-text section\'s hidden word list in place') do
      options[:write] = true
    end
    opts.on('--dictionary PATH', 'Path to Jbovlaste dictionary XML (default: dictionary/all_words.xml)') do |p|
      options[:dictionary] = p
    end
    opts.on('--exceptions PATH', 'Path to reviewed agreement-rule exceptions JSON (default: scripts/a01-word-list-exceptions.json)') do |p|
      options[:exceptions] = p
    end
  end
  parser.parse!
  abort parser.banner if ARGV.empty?

  dict = A01WordLists.load_dictionary(options[:dictionary])
  exceptions = A01WordLists.load_exceptions(options[:exceptions])
  if options[:write]
    ARGV.each do |path|
      changed = A01WordLists.rewrite_file(path, dict, exceptions)
      warn "#{path}: #{changed ? 'updated' : 'already up to date'}"
    end
    errors = ARGV.flat_map { |path| A01WordLists.lint_file(path, dict, exceptions) }
    unless errors.empty?
      warn errors.join("\n")
      exit 1
    end
    exit 0
  else
    errors = ARGV.flat_map { |path| A01WordLists.lint_file(path, dict, exceptions) }
    unless errors.empty?
      warn errors.join("\n")
      warn "\nRun `ruby scripts/lint-a01-word-lists.rb --write #{ARGV.join(' ')}` to regenerate the hidden word lists."
      exit 1
    end
    exit 0
  end
end
