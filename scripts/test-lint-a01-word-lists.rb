#!/usr/bin/env ruby
# Self-test for scripts/lint-a01-word-lists.rb, ChapterLint.source_line,
# and hidden glossary-list index suppression across xml_preprocess.rb,
# generate_glossary.rb, docbook_to_typst.rb, and docbook_to_context.rb (issue #351).
require 'json'
require 'nokogiri'
require 'open3'
require 'tmpdir'
require_relative 'lint-a01-word-lists'

failures = []
check = lambda { |ok, msg| failures << msg unless ok }

MINI_DICT = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <dictionary>
    <direction from="lojban" to="English">
      <valsi word=".a'o" type="cmavo"><definition>hope</definition></valsi>
      <valsi word=".i" type="cmavo"><definition>sentence separator</definition></valsi>
      <valsi word=".ibabo"><definition>and then</definition></valsi>
      <valsi word=".ui" type="cmavo"><definition>happiness</definition></valsi>
      <valsi word="ba" type="cmavo"><definition>future</definition></valsi>
      <valsi word="bo" type="cmavo"><definition>short scope</definition></valsi>
      <valsi word="cai" type="cmavo"><definition>intense</definition></valsi>
      <valsi word="dai" type="cmavo"><definition>empathy</definition></valsi>
      <valsi word="do" type="cmavo"><definition>you</definition></valsi>
      <valsi word="je" type="cmavo"><definition>and</definition></valsi>
      <valsi word="klama" type="gismu"><definition>go/come</definition></valsi>
      <valsi word="la" type="cmavo"><definition>name article</definition></valsi>
      <valsi word="le" type="cmavo"><definition>the</definition></valsi>
      <valsi word="li'u" type="cmavo"><definition>end quote</definition></valsi>
      <valsi word="lu" type="cmavo"><definition>quote</definition></valsi>
      <valsi word="mi" type="cmavo"><definition>I/me</definition></valsi>
      <valsi word="ri" type="cmavo"><definition>previous sumti</definition></valsi>
      <valsi word="sai" type="cmavo"><definition>strong</definition></valsi>
      <valsi word="teris" type="cmevla"><definition>Terry</definition></valsi>
      <valsi word="ty." type="cmavo"><definition>letter t</definition></valsi>
      <valsi word="vy." type="cmavo"><definition>letter v</definition></valsi>
      <valsi word="zoi" type="cmavo"><definition>non-Lojban quote</definition></valsi>
      <valsi word="gy." type="cmavo"><definition>letter g</definition></valsi>
      <valsi word="emptydef" type="gismu"><definition>   </definition></valsi>
    </direction>
  </dictionary>
XML

# 1. Unit tests for cmavo compound splitting (including CVCy lujvo safety).
{
  '.ijebo' => %w[i je bo],
  '.uicai' => %w[ui cai],
  "a'osaidai" => %w[a'o sai dai],
  'lety.' => %w[le ty],
  'vy.ri' => %w[vy ri],
  'bacyde\'i' => nil, # CVCy lujvo must never split as ba + cy + de'i
  'cnidu\'e' => nil,  # lujvo with consonant cluster
  'klama' => nil,     # gismu
  '.alis.' => nil,    # cmevla
  'teris.' => nil,    # cmevla
  'ba' => nil,        # single cmavo, not a compound
}.each do |token, want|
  got = A01WordLists.split_cmavo_compound(token)
  check.(got == want, "split_cmavo_compound(#{token.inspect}) = #{got.inspect}, expected #{want.inspect}")
end

# 1b. --help documents the compound-cmavo convention explicitly.
help_out, help_err, help_st = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'), '--help')
check.(help_st.success? && help_out.include?('Compound cmavo') && help_out.include?('doinai') && help_out.include?('a01-word-list-exceptions.json'),
       "--help missing convention text: #{help_out}#{help_err}")

Dir.mktmpdir('cll-a01-test-') do |dir|
  dict_path = File.join(dir, 'dict.xml')
  File.write(dict_path, MINI_DICT)
  dict = A01WordLists.load_dictionary(dict_path)

  empty_exc_path = File.join(dir, 'exc-empty.json')
  File.write(empty_exc_path, JSON.generate({ 'rule' => 'test', 'sections' => {} }))
  klama_exc_path = File.join(dir, 'exc-klama.json')
  File.write(klama_exc_path, JSON.generate({
    'rule' => 'test',
    'sections' => { 'sec-one' => { 'klama' => 'test disagreement with dictionary' } }
  }))

  # 2. Derivation & --write & lint round-trip, including:
  #    - thead + tbody Lojban column (ignoring English column)
  #    - compound cmavo with dict entry kept (.ibabo), without entry split (.ijebo, .uicai, a'osaidai, lety., vy.ri)
  #    - CVCy lujvo (bacyde'i) and consonant-cluster brivla (cnidu'e) kept intact as valid="maybe"
  #    - cmevla: teris. linked, .alis./alis -> .alis. maybe, bare dinas -> .dinas. maybe, .maikl.turni'anskis. maybe
  #    - zoi quote skips non-Lojban payload while keeping zoi and gy.
  #    - valid="maybe" derived from dictionary + reviewed exceptions (NOT carried forward blindly)
  fixture = <<~XML
    <appendix xml:id="volume-chrestomathy">
      <title><anchor xml:id="a01" />Chrestomathy</title>
      <section xml:id="sec-one">
        <title><anchor xml:id="s1" />One</title>
        <para role="display-none">
          <valsi valid="maybe">ba</valsi>
          <valsi>stale</valsi>
        </para>
        <informaltable role="parallel-text">
          <thead><tr><th>la teris. .ibabo</th><th>English title words ignored</th></tr></thead>
          <tbody>
            <tr><td>.ijebo .uicai a'osaidai lety. vy.ri</td><td>English body ignored</td></tr>
            <tr><td>ba klama bacyde'i cnidu'e la .alis. alis la dinas la .maikl.turni'anskis.</td><td>More English</td></tr>
            <tr><td>zoi gy. hello world .gy.</td><td>Quote</td></tr>
          </tbody>
        </informaltable>
      </section>
      <section xml:id="sec-two">
        <title><anchor xml:id="s2" />Two</title>
        <informaltable role="noborder parallel-text">
          <tbody><tr><td>ba klama</td><td>Will go</td></tr></tbody>
        </informaltable>
      </section>
    </appendix>
  XML
  a01_path = File.join(dir, 'a01.xml')
  File.write(a01_path, fixture)

  # F1 check: reported line numbers must match real 1-based source lines (not shifted by DOCTYPE prefix).
  # In fixture above: line 5 is <para role="display-none">, line 6 is <valsi valid="maybe">ba</valsi>,
  # line 7 is <valsi>stale</valsi>, line 18 is <section xml:id="sec-two">.
  errs_before = A01WordLists.lint_file(a01_path, dict, A01WordLists.load_exceptions(klama_exc_path))
  check.(errs_before.any? { |e| e.start_with?("#{a01_path}:7:") && e.include?('stale') },
         "F1: expected 'stale' reported at line 7, got: #{errs_before.inspect}")
  check.(errs_before.any? { |e| e.start_with?("#{a01_path}:6:") && e.include?('"ba"') && e.include?('must not carry valid="maybe"') },
         "F1/F2: expected stray valid=\"maybe\" on 'ba' at line 6, got: #{errs_before.inspect}")
  check.(errs_before.any? { |e| e.start_with?("#{a01_path}:18:") && e.include?('sec-two') && e.include?('no hidden word list') },
         "F1: expected missing list for sec-two at line 18, got: #{errs_before.inspect}")

  # F1 also works with single-line and multi-line <?xml ... ?> declarations.
  xml_decl_path = File.join(dir, 'with-decl.xml')
  File.write(xml_decl_path, "<?xml version=\"1.0\"\n encoding=\"UTF-8\"?>\n" + fixture)
  errs_decl = A01WordLists.lint_file(xml_decl_path, dict, {})
  check.(errs_decl.any? { |e| e.start_with?("#{xml_decl_path}:9:") && e.include?('stale') },
         "F1: multi-line <?xml?> offset wrong (expected line 9), got: #{errs_decl.inspect}")

  # Run --write via CLI with klama in reviewed exceptions (ba is NOT in exceptions, so its stray maybe must be cleared).
  _out, err, st = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'),
                                 '--write', '--dictionary', dict_path, '--exceptions', klama_exc_path, a01_path)
  check.(st.success?, "--write failed: #{err}")

  written = File.read(a01_path)
  check.(written.include?('<anchor xml:id="a01" />'), '--write altered unrelated markup outside hidden lists')

  # Lint must now pass with klama_exc_path, and FAIL with empty_exc_path (because klama has valid="maybe" without being listed).
  errs_after = A01WordLists.lint_file(a01_path, dict, A01WordLists.load_exceptions(klama_exc_path))
  check.(errs_after.empty?, "lint failed after --write: #{errs_after.inspect}")
  errs_no_exc = A01WordLists.lint_file(a01_path, dict, {})
  check.(errs_no_exc.any? { |e| e.include?('"klama"') && e.include?('must not carry valid="maybe"') },
         "F2: lint accepted unlisted valid=\"maybe\" on klama: #{errs_no_exc.inspect}")

  # Verify exact entries in sec-one and sec-two.
  doc = ChapterLint.read(a01_path)
  s1_entries = doc.xpath('//section[@id="sec-one"]/para[@role="display-none"]/valsi').map { |v| [v.text, v['valid']] }
  want_s1 = [
    [".a'o", nil],
    ['.alis.', 'maybe'],
    ['.dinas.', 'maybe'],
    ['.i', nil],
    ['.ibabo', nil],
    [".maikl.turni'anskis.", 'maybe'],
    ['.ui', nil],
    ['ba', nil], # stray valid="maybe" cleared!
    ["bacyde'i", 'maybe'],
    ['bo', nil],
    ['cai', nil],
    ["cnidu'e", 'maybe'],
    ['dai', nil],
    ['gy.', nil],
    ['je', nil],
    ['klama', 'maybe'], # derived from reviewed exceptions!
    ['la', nil],
    ['le', nil],
    ['ri', nil],
    ['sai', nil],
    ['teris.', nil],
    ['ty.', nil],
    ['vy.', nil],
    ['zoi', nil],
  ]
  check.(s1_entries == want_s1, "sec-one entries mismatch:\n  got:  #{s1_entries.inspect}\n  want: #{want_s1.inspect}")

  s2_entries = doc.xpath('//section[@id="sec-two"]/para[@role="display-none"]/valsi').map { |v| [v.text, v['valid']] }
  check.(s2_entries == [['ba', nil], ['klama', nil]], "sec-two entries mismatch: #{s2_entries.inspect}")

  # Running --write a second time is byte-for-byte idempotent.
  _out2, err2, st2 = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'),
                                    '--write', '--dictionary', dict_path, '--exceptions', klama_exc_path, a01_path)
  check.(st2.success? && File.read(a01_path) == written, "--write was not idempotent: #{err2}")

  # 2b. F2 real-dictionary test: copy chapters/a01.xml and dictionary/all_words.xml, add an entry for cabnicte.
  #     Lint MUST fail on the stale valid="maybe", and --write MUST drop valid="maybe" from cabnicte.
  real_a01_copy = File.join(dir, 'a01-real-copy.xml')
  File.write(real_a01_copy, File.read(File.join(ChapterLint::ROOT, 'chapters/a01.xml')))
  cabnicte_dict_path = File.join(dir, 'dict-plus-cabnicte.xml')
  real_dict_xml = File.read(A01WordLists::DEFAULT_DICTIONARY)
  injected = real_dict_xml.sub('</direction>', "  <valsi word=\"cabnicte\" type=\"lujvo\"><definition>tonight</definition></valsi>\n  </direction>")
  File.write(cabnicte_dict_path, injected)

  _lo, le, lst = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'),
                                '--dictionary', cabnicte_dict_path, real_a01_copy)
  check.(!lst.success? && le.include?('"cabnicte"') && le.include?('must not carry valid="maybe"'),
         "F2: lint did not fail when dictionary gained cabnicte: rc=#{lst.exitstatus} err=#{le}")

  _wo, we, wst = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'),
                                '--write', '--dictionary', cabnicte_dict_path, real_a01_copy)
  check.(wst.success? && File.read(real_a01_copy).include?('<valsi>cabnicte</valsi>') &&
         !File.read(real_a01_copy).include?('<valsi valid="maybe">cabnicte</valsi>'),
         "F2: --write did not remove valid=\"maybe\" from cabnicte after dict update: #{we}")

  # Reverse direction (entry disappears from dictionary): lint MUST fail on missing valid="maybe", --write MUST add it.
  _lo2, le2, lst2 = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'), real_a01_copy)
  check.(!lst2.success? && le2.include?('"cabnicte"') && le2.include?('must carry valid="maybe"'),
         "F2: lint did not fail when dictionary lost cabnicte: rc=#{lst2.exitstatus} err=#{le2}")

  _wo2, we2, wst2 = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'), '--write', real_a01_copy)
  check.(wst2.success? && File.read(real_a01_copy).include?('<valsi valid="maybe">cabnicte</valsi>'),
         "F2: --write did not restore valid=\"maybe\" when cabnicte disappeared: #{we2}")

  # Stale/unnecessary exceptions are rejected by lint.
  stale_exc = {
    'sec-two' => { 'notused' => 'bad', 'ba' => 'good' },
    'sec-missing' => { 'ba' => 'bad' },
  }
  errs_stale_exc = A01WordLists.lint_file(a01_path, dict, stale_exc)
  check.(errs_stale_exc.any? { |e| e.include?('notused') && e.include?('does not use') },
         "F2: lint missed unused exception word: #{errs_stale_exc.inspect}")
  check.(errs_stale_exc.any? { |e| e.include?('sec-missing') && e.include?('unknown or non-parallel-text') },
         "F2: lint missed unknown exception section: #{errs_stale_exc.inspect}")
  undef_exc = { 'sec-one' => { "cnidu'e" => 'already undefined' } }
  errs_undef_exc = A01WordLists.lint_file(a01_path, dict, undef_exc)
  check.(errs_undef_exc.any? { |e| e.include?("cnidu'e") && e.include?('already lacks a dictionary entry') },
         "F2: lint missed exception on already-undefined word: #{errs_undef_exc.inspect}")

  # 3. F3: Nested sections (both outer-with-table + inner subsections, and outer-container-without-table + inner subsections,
  #    plus XML comments containing deceptive <section>, </section>, and <para role="display-none"> tags).
  nested_with_outer = <<~XML
    <appendix xml:id="volume-chrestomathy">
      <title>Chrestomathy</title>
      <!-- <section xml:id="fake"><title>Fake</title></section> -->
      <section xml:id="outer">
        <title>Outer</title>
        <!-- <para role="display-none"><valsi>fake</valsi></para> </section> -->
        <informaltable role="parallel-text">
          <tbody><tr><td>mi</td><td>I</td></tr></tbody>
        </informaltable>
        <section xml:id="inner-one">
          <title>Inner One</title>
          <informaltable role="parallel-text">
            <tbody><tr><td>do</td><td>you</td></tr></tbody>
          </informaltable>
        </section>
        <section xml:id="inner-two">
          <title>Inner Two</title>
          <informaltable role="parallel-text">
            <tbody><tr><td>klama</td><td>go</td></tr></tbody>
          </informaltable>
        </section>
      </section>
    </appendix>
  XML
  nested_path = File.join(dir, 'nested-outer.xml')
  File.write(nested_path, nested_with_outer)

  _no, ne, nst = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'),
                                '--write', '--dictionary', dict_path, '--exceptions', empty_exc_path, nested_path)
  check.(nst.success?, "F3: --write failed on nested sections (outer+inner): #{ne}")
  nested_doc = ChapterLint.read(nested_path)
  outer_words = nested_doc.xpath('//section[@id="outer"]/para[@role="display-none"]/valsi').map(&:text)
  in1_words = nested_doc.xpath('//section[@id="inner-one"]/para[@role="display-none"]/valsi').map(&:text)
  in2_words = nested_doc.xpath('//section[@id="inner-two"]/para[@role="display-none"]/valsi').map(&:text)
  check.(outer_words == ['mi'] && in1_words == ['do'] && in2_words == ['klama'],
         "F3: nested lists wrong: outer=#{outer_words.inspect} in1=#{in1_words.inspect} in2=#{in2_words.inspect}")
  nested_once = File.read(nested_path)
  _no2, ne2, nst2 = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'),
                                   '--write', '--dictionary', dict_path, '--exceptions', empty_exc_path, nested_path)
  check.(nst2.success? && File.read(nested_path) == nested_once, "F3: --write on nested sections not idempotent: #{ne2}")

  # Container outer section (NO table of its own) wrapping two subsections with tables.
  nested_container = <<~XML
    <appendix xml:id="volume-chrestomathy">
      <title>Chrestomathy</title>
      <section xml:id="part-one">
        <title>Part One</title>
        <para>Intro only.</para>
        <section xml:id="sub-a">
          <title>Sub A</title>
          <informaltable role="parallel-text">
            <tbody><tr><td>mi ba</td><td>I will</td></tr></tbody>
          </informaltable>
        </section>
        <section xml:id="sub-b">
          <title>Sub B</title>
          <informaltable role="parallel-text">
            <tbody><tr><td>do klama</td><td>You go</td></tr></tbody>
          </informaltable>
        </section>
      </section>
    </appendix>
  XML
  container_path = File.join(dir, 'nested-container.xml')
  File.write(container_path, nested_container)
  _co, ce, cst = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'),
                                '--write', '--dictionary', dict_path, '--exceptions', empty_exc_path, container_path)
  check.(cst.success?, "F3: --write failed on container+subsections: #{ce}")
  cdoc = ChapterLint.read(container_path)
  check.(cdoc.xpath('//section[@id="part-one"]/para[@role="display-none"]').empty?,
         'F3: container section without direct table wrongly received a hidden word list')
  check.(cdoc.xpath('//section[@id="sub-a"]/para[@role="display-none"]/valsi').map(&:text) == %w[ba mi],
         'F3: sub-a list wrong')
  check.(cdoc.xpath('//section[@id="sub-b"]/para[@role="display-none"]/valsi').map(&:text) == %w[do klama],
         'F3: sub-b list wrong')

  # 4. Negative lint cases.
  negative_cases = {
    'missing-maybe-on-undef' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><valsi>cnidu\'e</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>cnidu\'e</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'must carry valid="maybe"',
    ],
    'stray-maybe-on-defined' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><valsi valid="maybe">klama</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>klama</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'must not carry valid="maybe"',
    ],
    'valid-false-rejected' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><valsi valid="false">klama</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>klama</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'valid="false"',
    ],
    'duplicate-word' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><valsi>klama</valsi><valsi>klama</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>klama</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'duplicates',
    ],
    'unsorted' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><valsi>klama</valsi><valsi>ba</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>ba klama</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'not sorted',
    ],
    'duplicate-hidden-para' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><valsi>ba</valsi></para>' \
      '<para role="display-none"><valsi>klama</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>ba klama</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      '2 hidden word lists',
    ],
    'stray-hidden-para-outside-section' => [
      '<appendix xml:id="volume-chrestomathy">' \
      '<para role="display-none"><valsi>ba</valsi></para>' \
      '<section xml:id="s"><title>T</title><para>No table.</para></section></appendix>',
      'outside a section',
    ],
    'stray-hidden-para-in-container-section' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="outer"><title>O</title>' \
      '<para role="display-none"><valsi>ba</valsi></para>' \
      '<section xml:id="inner"><title>I</title><para role="display-none"><valsi>ba</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>ba</td><td>x</td></tr></tbody></informaltable>' \
      '</section></section></appendix>',
      'outside a section with a parallel-text table',
    ],
    'unowned-parallel-table' => [
      '<appendix xml:id="volume-chrestomathy">' \
      '<informaltable role="parallel-text"><tbody><tr><td>ba</td><td>x</td></tr></tbody></informaltable>' \
      '</appendix>',
      'outside any <section>',
    ],
    'nbsp-not-role-separator' => [
      "<appendix xml:id=\"volume-chrestomathy\"><section xml:id=\"s\"><title>T</title>" \
      "<para role=\"display-none\u00a0extra\"><valsi>ba</valsi></para>" \
      '<informaltable role="parallel-text"><tbody><tr><td>ba</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'no hidden word list',
    ],
    'non-valsi-child' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><cmevla>.alis.</cmevla><valsi>ba</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>ba</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'unexpected <cmevla>',
    ],
  }
  negative_cases.each do |name, (xml, want_substr)|
    p = File.join(dir, "#{name}.xml")
    File.write(p, xml)
    errs = A01WordLists.lint_file(p, dict, {})
    check.(errs.any? { |e| e.include?(want_substr) }, "case #{name} did not report #{want_substr.inspect}: #{errs.inspect}")
  end

  # 5. Preprocessing + glossary + Typst + ConTeXt tests: hidden glossary lists
  #    must produce glossary links and glossary entries, and ZERO indexterms,
  #    while visible <valsi>, <jbophrase> frames, and <veljvo> keep their indexterms.
  book_xml = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <book xmlns:xlink="http://www.w3.org/1999/xlink">
      <info><title>Mini</title></info>
      <chapter xml:id="ch1">
        <title>Visible</title>
        <para>Visible word <valsi>klama</valsi> and frame <jbophrase>lu ... li'u</jbophrase>.</para>
        <lujvo-making><jbo>klama</jbo><veljvo>ba klama</veljvo></lujvo-making>
      </chapter>
      <appendix xml:id="volume-chrestomathy">
        <title>Chrestomathy</title>
        <section xml:id="sec-a">
          <title>Passage</title>
          <para role="display-none">
            <valsi>ba</valsi>
            <valsi>klama</valsi>
            <valsi valid="maybe">cnidu'e</valsi>
          </para>
          <para role=" extra display-none ">
            <valsi>je</valsi>
            <jbophrase>lu ... li'u</jbophrase>
          </para>
          <para><valsi role="display-none">bo</valsi></para>
          <lujvo-making role="display-none"><jbo>klama</jbo><veljvo>je bo</veljvo></lujvo-making>
        </section>
      </appendix>
      <index type="lojban-word"><title>Lojban Words Index</title></index>
    </book>
  XML
  pre_path = File.join(dir, 'cll_preglossary.xml')
  File.write(pre_path, book_xml)

  gloss_out, gloss_err, gloss_st = Open3.capture3('ruby', File.join(__dir__, 'generate_glossary.rb'), '-t', '-b', dir)
  check.(gloss_st.success?, "generate_glossary.rb failed: #{gloss_err}")
  %w[valsi-ba valsi-je valsi-bo valsi-klama valsi-lu valsi-lihu].each do |id|
    check.(gloss_out.include?(%Q{xml:id="#{id}"}), "glossary missing hidden/frame entry #{id}")
  end
  check.(!gloss_out.include?('valsi-cniduhe'), 'glossary unexpectedly emitted valid="maybe" entry')

  pp_out, pp_err, pp_st = Open3.capture3('ruby', File.join(__dir__, 'xml_preprocess.rb'), pre_path)
  check.(pp_st.success?, "xml_preprocess.rb failed: #{pp_err}")
  pp_doc = Nokogiri::XML(pp_out)
  pp_doc.remove_namespaces!

  hidden_links = pp_doc.xpath('//appendix//para[contains(@role,"display-none")]//glossterm/@linkend').map(&:value)
  check.(hidden_links.include?('valsi-ba') && hidden_links.include?('valsi-klama') && hidden_links.include?('valsi-je'),
         "hidden glossary links missing: #{hidden_links.inspect}")

  a01_indexterms = pp_doc.xpath('//appendix//indexterm')
  check.(a01_indexterms.empty?, "hidden elements emitted indexterms: #{a01_indexterms.map(&:to_xml).inspect}")

  vis_words = pp_doc.xpath('//chapter//indexterm[@type="lojban-word"]/primary').map(&:text)
  check.(vis_words == ['klama', 'lu', "li'u"], "visible lojban-word indexterms wrong: #{vis_words.inspect}")
  vis_phrases = pp_doc.xpath('//chapter//indexterm[@type="lojban-phrase"]/primary').map(&:text)
  check.(vis_phrases.include?("lu ... li'u") && vis_phrases.include?('ba klama'),
         "visible lojban-phrase indexterms wrong: #{vis_phrases.inspect}")

  sub_path = File.join(dir, 'sub.xml')
  File.write(sub_path, '<?xml version="1.0"?><book><chapter><title>T</title><para role="not-display-none"><valsi>klama</valsi></para></chapter></book>')
  sub_out, sub_err, sub_st = Open3.capture3('ruby', File.join(__dir__, 'xml_preprocess.rb'), sub_path)
  check.(sub_st.success?, "xml_preprocess.rb failed on not-display-none: #{sub_err}")
  sub_doc = Nokogiri::XML(sub_out)
  sub_doc.remove_namespaces!
  check.(sub_doc.xpath('//indexterm[@type="lojban-word"]/primary').map(&:text) == ['klama'],
         'role="not-display-none" wrongly suppressed indexterm')

  pp_path = File.join(dir, 'preprocessed.xml')
  File.write(pp_path, pp_out)
  typst_path = File.join(dir, 'out.typ')
  _tout, terr, tst = Open3.capture3('ruby', File.join(__dir__, 'docbook_to_typst.rb'), '--allow-missing-references', pp_path, typst_path)
  check.(tst.success?, "docbook_to_typst.rb failed: #{terr}")
  typst_src = File.read(typst_path)
  check.(typst_src.include?('[\"lojban-word\",\"klama\"]'), 'Typst missed visible klama index entry')
  %w[ba je bo].each do |w|
    check.(!typst_src.include?(%Q{[\\"lojban-word\\",\\"#{w}\\"]}), "Typst emitted hidden index entry for #{w}")
  end

  ctx_path = File.join(dir, 'out.tex')
  ctx_rep = File.join(dir, 'out.json')
  _cout, cerr, cst = Open3.capture3('ruby', File.join(__dir__, 'docbook_to_context.rb'), pp_path, ctx_path, ctx_rep)
  check.(cst.success?, "docbook_to_context.rb failed: #{cerr}")
  ctx_src = File.read(ctx_path)
  check.(ctx_src.include?('\CLLlojban[{klama}]{klama}'), 'ConTeXt missed visible klama index entry')
  %w[ba je bo].each do |w|
    check.(!ctx_src.include?("\\CLLlojban[{#{w}}]{#{w}}"), "ConTeXt emitted hidden index entry for #{w}")
  end
end

if failures.empty?
  puts 'test-lint-a01-word-lists: all checks passed'
else
  puts 'test-lint-a01-word-lists: FAIL'
  failures.each { |f| puts "  #{f}" }
  exit 1
end
