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
    check.(by_id['valsi-nahe'] == ["na'e", 'other than'], "na'e entry is #{by_id['valsi-nahe'].inspect}")
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

if failures.empty?
  puts 'test-generate-glossary: cache key and glossary IDs are stable'
else
  puts 'test-generate-glossary: FAIL'
  failures.each { |failure| puts "  #{failure}" }
  exit 1
end
