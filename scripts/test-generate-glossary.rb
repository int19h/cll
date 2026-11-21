#!/usr/bin/env ruby
# Issues #173 and #174: the glossary cache must change when the generator,
# util.rb, or the pronunciation files change, and spellings that share a slug
# must share one glossary ID. Run from anywhere. Exits 1 on failure.

require 'digest'
require 'fileutils'
require 'nokogiri'
require 'open3'
require 'tmpdir'

repo = File.expand_path('..', __dir__)
failures = []
check = lambda { |ok, msg| failures << msg unless ok }

def stage_generator(repo, dir)
  scripts = File.join(dir, 'scripts')
  FileUtils.mkdir_p(File.join(dir, 'assets/media/vreji'))
  FileUtils.mkdir_p(scripts)
  FileUtils.cp(File.join(repo, 'scripts/generate_glossary.rb'), scripts)
  FileUtils.cp(File.join(repo, 'scripts/util.rb'), scripts)
  File.write(File.join(scripts, 'update_jbovlaste_xml.sh'), <<~'SH')
    #!/bin/bash
    cat > "$1/jbovlaste.xml" <<'EOF'
    <dictionary>
      <valsi word=".y."><definition>hesitation noise</definition></valsi>
      <valsi word=".ia"><definition>belief</definition></valsi>
      <valsi word="klama"><definition>to come or go</definition></valsi>
      <valsi word="na'e"><definition>other than</definition></valsi>
      <valsi word=".i,ov"><definition>Job (a name)</definition></valsi>
      <valsi word="lojbangirz"><definition>Logical Language Group (LLG)</definition></valsi>
      <valsi word="y"><definition> </definition></valsi>
    </dictionary>
    EOF
  SH
  FileUtils.chmod(0o755, File.join(scripts, 'update_jbovlaste_xml.sh'))
  scripts
end

def run_generator(scripts, build, *args)
  Open3.capture3('ruby', File.join(scripts, 'generate_glossary.rb'), *args, '-b', build)
end

def entry_map(xml)
  doc = Nokogiri::XML("<wrapper>#{xml}</wrapper>") { |config| config.strict.nonet }
  doc.xpath('//glossentry').map { |entry| [entry['xml:id'], entry.at('glossterm').text, entry.at('para').text] }
end

words = <<~XML
  <?xml version="1.0"?>
  <book>
    <valsi>.y.</valsi>
    <valsi>y</valsi>
    <valsi valid="false">y</valsi>
    <valsi valid="maybe">ia</valsi>
    <valsi>.ia</valsi>
    <valsi>ia</valsi>
    <valsi>klama</valsi>
    <valsi>na'e</valsi>
    <valsi>nahe</valsi>
    <valsi>ke'e</valsi>
    <valsi>ui</valsi>
    <jbophrase>ke ... ke'e</jbophrase>
  </book>
XML

Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  File.write(File.join(build, 'cll_preglossary.xml'), words)

  stdout, stderr, status = run_generator(scripts, build, '-t')
  check.(status.success?, "testing glossary failed\n#{stderr}")
  if status.success?
    rows = entry_map(stdout)
    ids = rows.map(&:first)
    check.(ids == ids.uniq, "testing mode repeated an ID: #{ids.inspect}")
    check.(ids.count('valsi-y') == 1, 'testing mode did not collapse .y. and y')
    check.(ids.count('valsi-ia') == 1, 'testing mode did not collapse .ia and ia')
    check.(ids.count('valsi-nahe') == 1, 'testing mode did not collapse na\'e and nahe')
    check.(ids.include?('valsi-klama'), 'klama lost its existing ID')
    check.(ids.include?('valsi-kehe'), "ke'e lost its existing ID")
    check.(ids.include?('valsi-ke'), 'a frame word was dropped')
    check.(!ids.include?('valsi-ui') || ids.count('valsi-ui') == 1, 'ui was duplicated')
    terms = rows.map { |id, term, _defn| [id, term] }.to_h
    check.(terms['valsi-y'] == '.y.', "testing entry for y shows #{terms['valsi-y'].inspect}")
    check.(terms['valsi-nahe'] == "na'e", "testing entry for nahe shows #{terms['valsi-nahe'].inspect}")
  end

  stdout, stderr, status = run_generator(scripts, build)
  check.(status.success?, "regular glossary failed\n#{stderr}")
  if status.success?
    rows = entry_map(stdout)
    ids = rows.map(&:first)
    check.(ids == ids.uniq, "regular mode repeated an ID: #{ids.inspect}")
    by_id = rows.map { |id, term, defn| [id, [term, defn]] }.to_h
    check.(by_id['valsi-y'] == ['.y.', 'hesitation noise'], "y entry is #{by_id['valsi-y'].inspect}")
    check.(by_id['valsi-ia'] == ['.ia', 'belief'], "ia entry is #{by_id['valsi-ia'].inspect}")
    check.(by_id['valsi-klama'] == ['klama', 'to come or go'], "klama entry is #{by_id['valsi-klama'].inspect}")
    # The match is per spelling: "nahe" shares the ID valsi-nahe with
    # "na'e", but it differs from "na'e" inside the word, not only in
    # outer pause dots, so it has no match of its own. The group gets no
    # entry, "nahe" is reported missing, and the conflict is named, so
    # validation fails instead of linking "nahe" to "na'e". (Testing mode
    # above still collapses the spellings to the existing ID.)
    check.(!ids.include?('valsi-nahe'), "\"nahe\" still took the entry of \"na'e\": #{by_id['valsi-nahe'].inspect}")
    check.(stderr.include?('NO JBOVLASTE DEFINITION FOUND FOR WORD "nahe"'), '"nahe" was not reported missing')
    check.(stderr.include?('share the ID "valsi-nahe"'), 'the valsi-nahe group conflict is silent')
    check.(!ids.include?('valsi-ui'), 'an undefined word still produced an entry')
    check.(stderr.include?('NO JBOVLASTE DEFINITION FOUND FOR WORD "ui"'), 'missing definitions are silent')
  end
end

Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  pre = File.join(build, 'cll_preglossary.xml')
  File.write(pre, <<~XML)
    <?xml version="1.0"?>
    <book><para><valsi>klama</valsi><jbophrase>ke ... ke'e</jbophrase></para></book>
  XML
  md5 = Digest::MD5.file(pre).hexdigest
  File.write(File.join(build, "glossary.xml-#{md5}--testing"), 'STALE CACHE ' * 20)

  stdout, stderr, status = run_generator(scripts, build, '-t')
  check.(status.success?, "cache setup run failed\n#{stderr}")
  check.(stdout.include?('xml:id="valsi-ke"'), 'current generator did not emit the frame word')
  check.(!stdout.include?('STALE CACHE'), 'an older cache name was reused')
  check.(stderr.include?('Generating new glossary file.'), "first run did not generate:\n#{stderr}")

  stdout, stderr, status = run_generator(scripts, build, '-t')
  check.(status.success?, "cache hit failed\n#{stderr}")
  check.(stderr.include?('Glossary file already exists; using.'), "second run regenerated:\n#{stderr}")
  check.(stdout.include?('xml:id="valsi-ke"'), 'cache hit dropped the frame word')

  File.write(File.join(dir, 'assets/media/vreji/klama.mp3'), '')
  stdout, stderr, status = run_generator(scripts, build, '-t')
  check.(status.success?, "audio rerun failed\n#{stderr}")
  check.(stderr.include?('Generating new glossary file.'), "adding a pronunciation file reused the cache:\n#{stderr}")
  check.(stdout.include?('<guibutton>klama</guibutton>'), 'the new pronunciation file did not add a button')

  File.write(File.join(scripts, 'util.rb'), File.read(File.join(scripts, 'util.rb')) + "\n# cache bust\n")
  _stdout, stderr, status = run_generator(scripts, build, '-t')
  check.(status.success?, "util.rb rerun failed\n#{stderr}")
  check.(stderr.include?('Generating new glossary file.'), "editing util.rb reused the cache:\n#{stderr}")

  generator = File.join(scripts, 'generate_glossary.rb')
  File.write(generator, File.read(generator).sub('placeholder definition', 'edited definition'))
  stdout, stderr, status = run_generator(scripts, build, '-t')
  check.(status.success?, "generator rerun failed\n#{stderr}")
  check.(stderr.include?('Generating new glossary file.'), "editing the generator reused the cache:\n#{stderr}")
  check.(stdout.include?('edited definition'), 'the edited generator did not reach the output')
  check.(!stdout.include?('placeholder definition'), 'the edited generator kept the old definition')
end

# Issue #292: a book spelling with no dictionary entry of its own still gets
# the entry of a dictionary spelling that differs only in outer pause
# dots, as bare "y" does with ".y.". A partial build whose chapters use
# only the bare spelling otherwise links to a glossary entry that nothing
# defines. The fallback goes no further: ".i.ov" shares the ID valsi-i_ov
# with the name ".i,ov", but an internal period and an internal comma are
# different words, so ".i.ov" must stay undefined and keep its warning.
# The staged dictionary defines ".y.", ".ia", ".i,ov", and "lojbangirz",
# and "y" with an empty definition.
Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  File.write(File.join(build, 'cll_preglossary.xml'), <<~XML)
    <?xml version="1.0"?>
    <book><para><valsi>y</valsi><valsi>ia</valsi><valsi>.lojbangirz.</valsi><valsi>.i.ov</valsi><valsi>na'e</valsi></para></book>
  XML

  stdout, stderr, status = run_generator(scripts, build)
  check.(status.success?, "alias-only glossary failed\n#{stderr}")
  if status.success?
    by_id = entry_map(stdout).map { |id, term, defn| [id, [term, defn]] }.to_h
    check.(by_id['valsi-y'] == ['.y.', 'hesitation noise'], "bare y entry is #{by_id['valsi-y'].inspect}")
    check.(by_id['valsi-ia'] == ['.ia', 'belief'], "bare ia entry is #{by_id['valsi-ia'].inspect}")
    check.(by_id['valsi-lojbangirz'] == ['lojbangirz', 'Logical Language Group (LLG)'], "dotted .lojbangirz. entry is #{by_id['valsi-lojbangirz'].inspect}")
    check.(by_id['valsi-nahe'] == ["na'e", 'other than'], "na'e alone lost its existing ID: #{by_id['valsi-nahe'].inspect}")
    check.(!by_id.key?('valsi-i_ov'), ".i.ov took the entry of the name .i,ov: #{by_id['valsi-i_ov'].inspect}")
    check.(stderr.include?('glossary: "y" uses the dictionary spelling ".y."'), 'the y fallback is silent')
    check.(stderr.include?('glossary: ".lojbangirz." uses the dictionary spelling "lojbangirz"'), 'the .lojbangirz. fallback is silent')
    check.(stderr.include?('NO JBOVLASTE DEFINITION FOUND FOR WORD ".i.ov"'), '.i.ov lost its missing-definition warning')
  end
end

# Issue #292, round 3: the match is decided per book spelling, not per
# ID group. "i,ov" matches the name ".i,ov" by its outer dot, and the
# book spelling ".i,ov" matches it exactly, but ".i.ov" in the same
# group matches nothing of its own. It must be reported missing and the
# group must get no entry, so validation fails instead of linking
# ".i.ov" to Job through its group mate. Bare "y" in the same input is
# the positive control.
Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  pre = File.join(build, 'cll_preglossary.xml')

  [%w[i,ov .i.ov], %w[.i,ov .i.ov]].each do |mate, stray|
    File.write(pre, <<~XML)
      <?xml version="1.0"?>
      <book><para><valsi>#{mate}</valsi><valsi>#{stray}</valsi><valsi>y</valsi></para></book>
    XML
    stdout, stderr, status = run_generator(scripts, build)
    check.(status.success?, "mixed-group glossary (#{mate}) failed\n#{stderr}")
    next unless status.success?
    by_id = entry_map(stdout).map { |id, term, defn| [id, [term, defn]] }.to_h
    check.(by_id['valsi-y'] == ['.y.', 'hesitation noise'], "control y entry is #{by_id['valsi-y'].inspect}")
    check.(!by_id.key?('valsi-i_ov'), "\"#{stray}\" took the entry of the name .i,ov through \"#{mate}\": #{by_id['valsi-i_ov'].inspect}")
    check.(stderr.include?('NO JBOVLASTE DEFINITION FOUND FOR WORD ".i.ov"'), "\"#{stray}\" was not reported missing beside \"#{mate}\"")
    check.(stderr.include?('share the ID "valsi-i_ov"'), 'the valsi-i_ov group conflict is silent')
    check.(!stderr.include?('glossary: ".i.ov" uses the dictionary spelling'), "\".i.ov\" still claims a dictionary spelling beside \"#{mate}\"")
  end
end

# Cmavo-list cells: a cell spelling without an entry of its own must not
# join a slug group and remove a body word's entry. Here the "nahe" cell
# shares the ID valsi-nahe with the body word "na'e", which the staged
# dictionary defines. The cell word is dropped before grouping, so the
# "na'e" entry survives; the preprocessed book leaves the cell plain and
# reports it instead. The "klama" gismu cells have an entry of their own
# and produce one with no body word, and the ".y." cell joins the body
# "y" as before.
Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  File.write(File.join(build, 'cll_preglossary.xml'), <<~XML)
    <?xml version="1.0"?>
    <book>
      <para><valsi>na'e</valsi><valsi>y</valsi></para>
      <cmavo-list>
        <cmavo-entry><cmavo>nahe</cmavo><gismu>klama</gismu></cmavo-entry>
        <cmavo-entry><cmavo>.y.</cmavo><gismu>klama</gismu></cmavo-entry>
      </cmavo-list>
    </book>
  XML

  stdout, stderr, status = run_generator(scripts, build)
  check.(status.success?, "cell-word glossary failed\n#{stderr}")
  if status.success?
    by_id = entry_map(stdout).map { |id, term, defn| [id, [term, defn]] }.to_h
    check.(by_id['valsi-nahe'] == ["na'e", 'other than'], "the nahe cell removed na'e's entry: #{by_id['valsi-nahe'].inspect}")
    check.(!stderr.include?('share the ID "valsi-nahe"'), 'the valsi-nahe group conflict is back')
    check.(by_id['valsi-klama'] == ['klama', 'to come or go'], "a cell word with an entry produced none: #{by_id['valsi-klama'].inspect}")
    check.(by_id['valsi-y'] == ['.y.', 'hesitation noise'], "the .y. cell stopped joining y: #{by_id['valsi-y'].inspect}")
  end
end

# A <valsi> wrapped in a table cell is a cell spelling, not body prose:
# a wrapped spelling without an entry of its own must not join a slug
# group and remove a body word's entry either. Here the wrapped "nahe"
# shares the ID valsi-nahe with the body word "na'e", which the staged
# dictionary defines. The entry survives with the "na'e" term and no
# group conflict; a wrapped "klama", which has an entry of its own,
# still produces one.
Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  File.write(File.join(build, 'cll_preglossary.xml'), <<~XML)
    <?xml version="1.0"?>
    <book>
      <para><valsi>na'e</valsi></para>
      <cmavo-list>
        <cmavo-entry><cmavo><valsi>nahe</valsi></cmavo><gismu>ui</gismu></cmavo-entry>
        <cmavo-entry><cmavo><valsi>klama</valsi></cmavo><gismu>y</gismu></cmavo-entry>
      </cmavo-list>
    </book>
  XML

  stdout, stderr, status = run_generator(scripts, build)
  check.(status.success?, "wrapped-word glossary failed\n#{stderr}")
  if status.success?
    by_id = entry_map(stdout).map { |id, term, defn| [id, [term, defn]] }.to_h
    check.(by_id['valsi-nahe'] == ["na'e", 'other than'], "the wrapped nahe removed na'e's entry: #{by_id['valsi-nahe'].inspect}")
    check.(!stderr.include?('share the ID "valsi-nahe"'), 'the valsi-nahe group conflict is back')
    check.(by_id['valsi-klama'] == ['klama', 'to come or go'], "a wrapped cell word with an entry produced none: #{by_id['valsi-klama'].inspect}")
  end
end

# A wrapped cell spelling counts its visible text only, as the
# preprocessor does: hidden text inside the <valsi> must not join the
# slug. Here "klama" appears only inside a wrapped phrase cell with a
# display-none letter (the cell as a whole names no word), so without
# the visible-text rule its entry would vanish under "klamax".
Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  File.write(File.join(build, 'cll_preglossary.xml'), <<~XML)
    <?xml version="1.0"?>
    <book>
      <cmavo-list>
        <cmavo-entry><cmavo>tense+ <valsi>klama<phrase role="display-none">x</phrase></valsi></cmavo><gismu>y</gismu></cmavo-entry>
      </cmavo-list>
    </book>
  XML

  stdout, stderr, status = run_generator(scripts, build)
  check.(status.success?, "hidden-text cell-word glossary failed\n#{stderr}")
  if status.success?
    by_id = entry_map(stdout).map { |id, term, defn| [id, [term, defn]] }.to_h
    check.(by_id['valsi-klama'] == ['klama', 'to come or go'], "hidden text removed klama's entry: #{by_id['valsi-klama'].inspect}")
    check.(!stderr.include?('klamax'), 'hidden text leaked into the glossary')
  end
end

# Only a <cmavo> or <gismu> whose parent is a <cmavo-entry> counts as a
# table cell. A wrapped spelling elsewhere, such as in an example, is
# body prose: without an entry of its own it sinks the shared group
# loudly instead of silently taking over another word's entry.
Dir.mktmpdir do |dir|
  scripts = stage_generator(repo, dir)
  build = File.join(dir, 'build')
  FileUtils.mkdir_p(build)
  File.write(File.join(build, 'cll_preglossary.xml'), <<~XML)
    <?xml version="1.0"?>
    <book>
      <para><valsi>na'e</valsi></para>
      <example><para>see <cmavo><valsi>nahe</valsi></cmavo> here</para></example>
    </book>
  XML

  stdout, stderr, status = run_generator(scripts, build)
  check.(status.success?, "example-wrapped glossary failed\n#{stderr}")
  if status.success?
    by_id = entry_map(stdout).map { |id, term, defn| [id, [term, defn]] }.to_h
    check.(by_id['valsi-nahe'].nil?, "an example-wrapped spelling kept na'e's entry quiet: #{by_id['valsi-nahe'].inspect}")
    check.(stderr.include?('share the ID "valsi-nahe"'), 'the example-wrapped conflict is silent')
  end
end

if failures.empty?
  puts 'test-generate-glossary: cache key and glossary IDs are stable'
else
  puts 'test-generate-glossary: FAIL'
  failures.each { |failure| puts "  #{failure}" }
  exit 1
end
