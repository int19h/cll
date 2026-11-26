#!/usr/bin/env ruby
# Self-test for scripts/lint-a01-word-lists.rb and hidden glossary-list index
# suppression across xml_preprocess.rb, generate_glossary.rb, docbook_to_typst.rb,
# and docbook_to_context.rb (issue #351).
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
      <valsi word="je" type="cmavo"><definition>and</definition></valsi>
      <valsi word="klama" type="gismu"><definition>go/come</definition></valsi>
      <valsi word="la" type="cmavo"><definition>name article</definition></valsi>
      <valsi word="le" type="cmavo"><definition>the</definition></valsi>
      <valsi word="li'u" type="cmavo"><definition>end quote</definition></valsi>
      <valsi word="lu" type="cmavo"><definition>quote</definition></valsi>
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

Dir.mktmpdir('cll-a01-test-') do |dir|
  dict_path = File.join(dir, 'dict.xml')
  File.write(dict_path, MINI_DICT)
  dict = A01WordLists.load_dictionary(dict_path)

  # 2. Derivation & --write & lint round-trip, including:
  #    - thead + tbody Lojban column (ignoring English column)
  #    - compound cmavo with dict entry kept (.ibabo), without entry split (.ijebo, .uicai, a'osaidai, lety., vy.ri)
  #    - CVCy lujvo (bacyde'i) and consonant-cluster brivla (cnidu'e) kept intact as valid="maybe"
  #    - cmevla: teris. linked, .alis./alis -> .alis. maybe, bare dinas -> .dinas. maybe, .maikl.turni'anskis. maybe
  #    - zoi quote skips non-Lojban payload while keeping zoi and gy.
  #    - existing valid="maybe" on a dictionary-backed word (klama) preserved by --write (agreement rule)
  fixture = <<~XML
    <appendix xml:id="volume-chrestomathy">
      <title><anchor xml:id="a01" />Chrestomathy</title>
      <section xml:id="sec-one">
        <title><anchor xml:id="s1" />One</title>
        <para role="display-none">
          <valsi valid="maybe">klama</valsi>
          <valsi>stale</valsi>
        </para>
        <informaltable role="parallel-text">
          <thead><tr><th>la teris. .ibabo</th><th>English title words ignored</th></tr></thead>
          <tbody>
            <tr><td>.ijebo .uicai a'osaidai lety. vy.ri</td><td>English body ignored</td></tr>
            <tr><td>klama bacyde'i cnidu'e la .alis. alis la dinas la .maikl.turni'anskis.</td><td>More English</td></tr>
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

  # Before --write: lint must fail (sec-one has stale + missing; sec-two has no list).
  errs_before = A01WordLists.lint_file(a01_path, dict)
  check.(errs_before.any? { |e| e.include?('sec-one') && e.include?('stale') },
         "lint missed unused word 'stale': #{errs_before.inspect}")
  check.(errs_before.any? { |e| e.include?('sec-one') && e.include?('bacyde\'i') },
         "lint missed CVCy lujvo bacyde'i: #{errs_before.inspect}")
  check.(errs_before.any? { |e| e.include?('sec-two') && e.include?('no hidden word list') },
         "lint missed missing list in sec-two: #{errs_before.inspect}")

  # Run --write via CLI.
  _out, err, st = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'), '--write', '--dictionary', dict_path, a01_path)
  check.(st.success?, "--write failed: #{err}")

  written = File.read(a01_path)
  check.(written.include?('<anchor xml:id="a01" />'), '--write altered unrelated markup outside hidden lists')

  # Lint must now pass.
  errs_after = A01WordLists.lint_file(a01_path, dict)
  check.(errs_after.empty?, "lint failed after --write: #{errs_after.inspect}")

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
    ["bacyde'i", 'maybe'],
    ['bo', nil],
    ['cai', nil],
    ["cnidu'e", 'maybe'],
    ['dai', nil],
    ['gy.', nil],
    ['je', nil],
    ['klama', 'maybe'], # agreement-rule maybe preserved!
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
  _out2, err2, st2 = Open3.capture3('ruby', File.join(__dir__, 'lint-a01-word-lists.rb'), '--write', '--dictionary', dict_path, a01_path)
  check.(st2.success? && File.read(a01_path) == written, "--write was not idempotent: #{err2}")

  # 3. Negative lint cases.
  negative_cases = {
    'missing-maybe-on-undef' => [
      '<appendix xml:id="volume-chrestomathy"><section xml:id="s"><title>T</title>' \
      '<para role="display-none"><valsi>cnidu\'e</valsi></para>' \
      '<informaltable role="parallel-text"><tbody><tr><td>cnidu\'e</td><td>x</td></tr></tbody></informaltable>' \
      '</section></appendix>',
      'must carry valid="maybe"',
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
    errs = A01WordLists.lint_file(p, dict)
    check.(errs.any? { |e| e.include?(want_substr) }, "case #{name} did not report #{want_substr.inspect}: #{errs.inspect}")
  end

  # 4. Preprocessing + glossary + Typst + ConTeXt tests: hidden glossary lists
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

  # Glossary still collects hidden <valsi> (ba, je, bo, klama) and skips valid="maybe" (cnidu'e).
  gloss_out, gloss_err, gloss_st = Open3.capture3('ruby', File.join(__dir__, 'generate_glossary.rb'), '-t', '-b', dir)
  check.(gloss_st.success?, "generate_glossary.rb failed: #{gloss_err}")
  %w[valsi-ba valsi-je valsi-bo valsi-klama valsi-lu valsi-lihu].each do |id|
    check.(gloss_out.include?(%Q{xml:id="#{id}"}), "glossary missing hidden/frame entry #{id}")
  end
  check.(!gloss_out.include?('valsi-cniduhe'), 'glossary unexpectedly emitted valid="maybe" entry')

  # Preprocess and check indexterms & glossterms.
  pp_out, pp_err, pp_st = Open3.capture3('ruby', File.join(__dir__, 'xml_preprocess.rb'), pre_path)
  check.(pp_st.success?, "xml_preprocess.rb failed: #{pp_err}")
  pp_doc = Nokogiri::XML(pp_out)
  pp_doc.remove_namespaces!

  # All hidden <valsi> without valid="maybe" keep their <glossterm> links.
  hidden_links = pp_doc.xpath('//appendix//para[contains(@role,"display-none")]//glossterm/@linkend').map(&:value)
  check.(hidden_links.include?('valsi-ba') && hidden_links.include?('valsi-klama') && hidden_links.include?('valsi-je'),
         "hidden glossary links missing: #{hidden_links.inspect}")

  # ZERO indexterms anywhere inside Appendix A (all valsi/jbophrase/veljvo there were display-none).
  a01_indexterms = pp_doc.xpath('//appendix//indexterm')
  check.(a01_indexterms.empty?, "hidden elements emitted indexterms: #{a01_indexterms.map(&:to_xml).inspect}")

  # Visible chapter still gets its lojban-word and lojban-phrase indexterms.
  vis_words = pp_doc.xpath('//chapter//indexterm[@type="lojban-word"]/primary').map(&:text)
  check.(vis_words == ['klama', 'lu', "li'u"], "visible lojban-word indexterms wrong: #{vis_words.inspect}")
  vis_phrases = pp_doc.xpath('//chapter//indexterm[@type="lojban-phrase"]/primary').map(&:text)
  check.(vis_phrases.include?("lu ... li'u") && vis_phrases.include?('ba klama'),
         "visible lojban-phrase indexterms wrong: #{vis_phrases.inspect}")

  # Substring role "not-display-none" is NOT hidden and still emits an indexterm.
  sub_path = File.join(dir, 'sub.xml')
  File.write(sub_path, '<?xml version="1.0"?><book><chapter><title>T</title><para role="not-display-none"><valsi>klama</valsi></para></chapter></book>')
  sub_out, sub_err, sub_st = Open3.capture3('ruby', File.join(__dir__, 'xml_preprocess.rb'), sub_path)
  check.(sub_st.success?, "xml_preprocess.rb failed on not-display-none: #{sub_err}")
  sub_doc = Nokogiri::XML(sub_out)
  sub_doc.remove_namespaces!
  check.(sub_doc.xpath('//indexterm[@type="lojban-word"]/primary').map(&:text) == ['klama'],
         'role="not-display-none" wrongly suppressed indexterm')

  # Check Typst and ConTeXt converters on the preprocessed book: neither emits
  # any index entry for the hidden-only words (ba, je, bo), while both emit klama.
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
