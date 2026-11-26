#!/usr/bin/env ruby
# Derive and check Appendix A's per-section hidden glossary word lists (issue #351).
#
# Usage:
#   ruby scripts/lint-a01-word-lists.rb [--dictionary PATH] chapters/a01.xml
#   ruby scripts/lint-a01-word-lists.rb --write [--dictionary PATH] chapters/a01.xml
require 'nokogiri'
require 'optparse'
require 'set'
require_relative 'chapter-lint'
require_relative 'util'

module A01WordLists
  DEFAULT_DICTIONARY = File.expand_path('../dictionary/all_words.xml', __dir__)
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

  # Extract Lojban tokens from the first column of all parallel-text tables in a section,
  # skipping non-Lojban payloads of zoi / la'o quotes (while keeping their Lojban delimiters).
  def self.section_tokens(section)
    tables = section.xpath('.//informaltable').select { |t| has_xml_role?(t, 'parallel-text') }
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

  # Derive the expected sorted list of [word, has_dict_entry] pairs for one section.
  def self.derive_section_words(section, dict_by_bare)
    raw_tokens = section_tokens(section)

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

  def self.hidden_paras(node)
    node.xpath('.//para').select { |p| has_xml_role?(p, 'display-none') }
  end

  def self.section_id(section)
    section['id'] || section['xml:id'] || '(unnamed section)'
  end

  # Lint one chapter file (expected to be chapters/a01.xml or a fixture appendix).
  def self.lint_file(path, dict_by_bare)
    doc = ChapterLint.read(path)
    errors = []

    sections = doc.xpath('//section')
    parallel_sections = sections.select do |sec|
      sec.xpath('.//informaltable').any? { |t| has_xml_role?(t, 'parallel-text') }
    end

    # Reject display-none paragraphs outside sections that carry a parallel-text table.
    all_hidden = hidden_paras(doc)
    owned_hidden = parallel_sections.flat_map { |sec| hidden_paras(sec) }
    (all_hidden - owned_hidden).each do |para|
      errors << "#{path}:#{para.line}: <para role=\"display-none\"> appears outside a section with a parallel-text table"
    end

    parallel_sections.each do |sec|
      sid = section_id(sec)
      lists = hidden_paras(sec)
      if lists.empty?
        errors << "#{path}:#{sec.line}: section #{sid} has a parallel-text table but no hidden word list (<para role=\"display-none\">)"
        next
      elsif lists.size > 1
        errors << "#{path}:#{lists[1].line}: section #{sid} has #{lists.size} hidden word lists (expected 1)"
        next
      end

      list = lists.first
      list.children.each do |child|
        if child.element? && child.name != 'valsi'
          errors << "#{path}:#{child.line}: section #{sid} hidden word list contains unexpected <#{child.name}>"
        elsif child.text? && !child.text.strip.empty?
          errors << "#{path}:#{list.line}: section #{sid} hidden word list contains stray text #{child.text.strip.inspect}"
        end
      end

      actual_nodes = list.element_children.select { |c| c.name == 'valsi' }
      actual_words = actual_nodes.map(&:text)

      seen = Set.new
      actual_nodes.each do |v|
        if seen.include?(v.text)
          errors << "#{path}:#{v.line}: section #{sid} hidden word list duplicates #{v.text.inspect}"
        end
        seen << v.text
      end

      if actual_words != actual_words.sort
        errors << "#{path}:#{list.line}: section #{sid} hidden word list is not sorted alphabetically"
      end

      expected = derive_section_words(sec, dict_by_bare)
      expected_map = expected.to_h
      actual_map = actual_nodes.each_with_object({}) { |v, h| h[v.text] ||= v }

      (expected_map.keys - actual_map.keys).sort.each do |word|
        hint = expected_map[word] ? '' : ' (with valid="maybe")'
        errors << "#{path}:#{list.line}: section #{sid} hidden word list is missing #{word.inspect}#{hint}"
      end

      (actual_map.keys - expected_map.keys).sort.each do |word|
        v = actual_map[word]
        errors << "#{path}:#{v.line}: section #{sid} hidden word list has unused or non-canonical word #{word.inspect}"
      end

      actual_nodes.each do |v|
        word = v.text
        next unless expected_map.key?(word)
        valid_attr = v['valid']
        has_entry = expected_map[word]
        if valid_attr == 'false'
          errors << "#{path}:#{v.line}: section #{sid} hidden word list marks #{word.inspect} valid=\"false\" (use valid=\"maybe\" or omit)"
        elsif !valid_attr.nil? && valid_attr != 'maybe'
          errors << "#{path}:#{v.line}: section #{sid} hidden word list has unexpected valid=#{valid_attr.inspect} on #{word.inspect}"
        elsif !has_entry && valid_attr != 'maybe'
          errors << "#{path}:#{v.line}: section #{sid} hidden word list entry #{word.inspect} has no dictionary entry and must carry valid=\"maybe\""
        end
      end
    end

    errors
  end

  def self.format_list(expected, existing_maybes, indent)
    inner = "#{indent}  "
    lines = ["#{indent}<para role=\"display-none\">"]
    expected.each do |word, has_entry|
      maybe = !has_entry || existing_maybes.include?(word)
      attr = maybe ? ' valid="maybe"' : ''
      lines << "#{inner}<valsi#{attr}>#{word}</valsi>"
    end
    lines << "#{indent}</para>"
    lines.join("\n")
  end

  # Rewrite the hidden word lists of path in place, preserving all other XML formatting
  # and keeping any existing valid="maybe" set on dictionary-backed words (agreement rule).
  def self.rewrite_file(path, dict_by_bare)
    source = File.read(path, encoding: 'UTF-8')
    doc = ChapterLint.read(path)

    # Map section xml:id -> { expected: [...], existing_maybes: Set }
    section_data = {}
    doc.xpath('//section').each do |sec|
      next unless sec.xpath('.//informaltable').any? { |t| has_xml_role?(t, 'parallel-text') }
      sid = sec['id'] || sec['xml:id']
      raise "#{path}:#{sec.line}: parallel-text section has no xml:id" unless sid
      expected = derive_section_words(sec, dict_by_bare)
      existing_maybes = Set.new
      hidden_paras(sec).each do |p|
        p.xpath('./valsi[@valid="maybe"]').each { |v| existing_maybes << v.text }
      end
      section_data[sid] = { expected: expected, existing_maybes: existing_maybes }
    end

    # Operate section by section on the raw XML text so everything outside
    # <para role="display-none"> stays byte-for-byte unchanged.
    section_re = %r{(<section\b[^>]*\bxml:id="([^"]+)"[^>]*>)(.*?)(</section>)}m
    updated = source.gsub(section_re) do
      open_tag = Regexp.last_match(1)
      sid = Regexp.last_match(2)
      body = Regexp.last_match(3)
      close_tag = Regexp.last_match(4)
      data = section_data[sid]
      next "#{open_tag}#{body}#{close_tag}" unless data

      # Determine child indentation from <title> inside the section.
      indent = body[/\n([ \t]*)<title\b/, 1] || '    '
      list_xml = format_list(data[:expected], data[:existing_maybes], indent)

      # Remove any existing hidden list(s) in this section (matching XML whitespace token).
      para_re = %r{[ \t]*<para\b[^>]*\brole="(?:[^"]*[ \t\r\n])?display-none(?:[ \t\r\n][^"]*)?"[^>]*>.*?</para>[ \t]*\n?}m
      had_list = body.match?(para_re)
      if had_list
        first = true
        new_body = body.gsub(para_re) do
          if first
            first = false
            "#{list_xml}\n"
          else
            ''
          end
        end
      else
        # Insert directly after the section's <title>...</title> line.
        unless body.match?(%r{(<title\b.*?</title>[ \t]*\n)}m)
          raise "#{path}: section #{sid} has no <title> element"
        end
        new_body = body.sub(%r{(<title\b.*?</title>[ \t]*\n)}m, "\\1#{list_xml}\n")
      end

      "#{open_tag}#{new_body}#{close_tag}"
    end

    File.write(path, updated, encoding: 'UTF-8') if updated != source
    updated != source
  end
end

if $PROGRAM_NAME == __FILE__
  options = { write: false, dictionary: A01WordLists::DEFAULT_DICTIONARY }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [--write] [--dictionary PATH] FILE..."
    opts.on('--write', 'Regenerate each parallel-text section\'s hidden word list in place') do
      options[:write] = true
    end
    opts.on('--dictionary PATH', 'Path to Jbovlaste dictionary XML (default: dictionary/all_words.xml)') do |p|
      options[:dictionary] = p
    end
  end
  parser.parse!
  abort parser.banner if ARGV.empty?

  dict = A01WordLists.load_dictionary(options[:dictionary])
  if options[:write]
    ARGV.each do |path|
      changed = A01WordLists.rewrite_file(path, dict)
      warn "#{path}: #{changed ? 'updated' : 'already up to date'}"
    end
    errors = ARGV.flat_map { |path| A01WordLists.lint_file(path, dict) }
    unless errors.empty?
      warn errors.join("\n")
      exit 1
    end
    exit 0
  else
    errors = ARGV.flat_map { |path| A01WordLists.lint_file(path, dict) }
    unless errors.empty?
      warn errors.join("\n")
      warn "\nRun `ruby scripts/lint-a01-word-lists.rb --write #{ARGV.join(' ')}` to regenerate the hidden word lists."
      exit 1
    end
    exit 0
  end
end
