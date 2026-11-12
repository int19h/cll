#!/usr/bin/env ruby
# Issue #171: a partial build must retarget every linkend whose target is
# absent, whatever its prefix, and leave local targets alone.
# Run from anywhere. Exits 1 on failure.

require 'fileutils'
require 'open3'
require 'tmpdir'

repo = File.expand_path('..', __dir__)
failures = []
check = lambda { |ok, msg| failures << msg unless ok }

def rewrite(repo, xml)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'book.xml')
    File.write(path, xml)
    _out, err, status = Open3.capture3('ruby', File.join(repo, 'scripts/partial-references.rb'), path)
    check_status = status.success? ? File.read(path) : nil
    [check_status, err, status]
  end
end

source = <<~XML
  <book>
  <chapter xml:id="chapter-a">
  <title>A &ndash; chapter</title>
  <section xml:id="section-local">
  <title>Local</title>
  <para><xref linkend="section-local"/></para>
  <para><xref linkend="chapter-b"/></para>
  <para><xref linkend="appendix-changes"/></para>
  <para><xref linkend="example-outside"/></para>
  <para><xref linkend="ebnf-parses"/></para>
  <para><xref linkend="volume-chrestomathy"/></para>
  <para><link linkend="section-local">this section</link></para>
  <para><link linkend="appendix-changes">the changes</link></para>
  <para><indexterm zone="section-local missing-zone"/></para>
  </section>
  </chapter>
  <chapter xml:id="chapter-b"><title>B</title></chapter>
  </book>
XML

rewritten, err, status = rewrite(repo, source)
check.(status.success?, "rewriter failed: #{err}")
if rewritten
  check.(rewritten.include?('&ndash;'), 'rewriter expanded or dropped a character entity')
  check.(!rewritten.include?('<!ENTITY emsp'), 'rewriter inlined the DocBook entity set')
  check.(!rewritten.include?('xmlns="http://docbook.org/ns/docbook"'), 'rewriter re-serialized the document')
  check.(rewritten.include?('linkend="section-local"'), 'a local section reference was retargeted')
  check.(rewritten.include?('linkend="chapter-b"'), 'a reference to an included chapter was retargeted')
  %w[appendix-changes example-outside ebnf-parses volume-chrestomathy].each do |missing|
    check.(!rewritten.include?(%(linkend="#{missing}")), "#{missing} was left unresolved")
  end
  check.(rewritten.scan('linkend="chapter-a"').size == 5, 'omitted targets were not all pointed at chapter-a')
  check.(rewritten.include?('zone="section-local chapter-a"'), "zone tokens were not rewritten:\n#{rewritten[/zone="[^"]*"/]}")
  check.(rewritten.include?('>this section</link>'), 'link text was rewritten')
  check.(rewritten.include?('>the changes</link>'), 'the text of an omitted link was dropped')
end

def validate_partial(repo, mode, chapters)
  Dir.mktmpdir do |root|
    File.symlink(File.join(repo, 'scripts'), File.join(root, 'scripts'))
    build = File.join(root, 'build')
    FileUtils.mkdir_p(build)
    File.symlink(File.join(repo, 'dtd'), File.join(build, 'dtd'))
    File.symlink(File.join(repo, 'xml'), File.join(build, 'xml'))
    paths = chapters.each_with_index.map do |body, index|
      path = File.join(root, "chapter-#{index}.xml")
      File.write(path, body)
      path
    end
    File.write(File.join(root, '.env'), "TITLE=Partial Test\nREVISER=Auditor\nPUBLISHER=Example\n")
    env = ENV.to_h.merge('CLL_BUILD_VERSION' => 'audit')
    _out, err, status = Open3.capture3(
      env, 'bash', 'scripts/merge.sh', mode, '-b', build, *paths, chdir: root
    )
    return ["#{mode}: merge exited #{status.exitstatus}\n#{err}", nil] unless status.success?
    cll = File.read(File.join(build, 'cll.xml'))
    processed = File.join(build, 'processed.xml')
    stdout, err, status = Open3.capture3('ruby', File.join(repo, 'scripts/xml_preprocess.rb'), File.join(build, 'cll.xml'))
    return ["#{mode}: preprocess failed\n#{err}", cll] unless status.success?
    File.write(processed, stdout)
    _out, err, status = Open3.capture3(
      'xmllint', '--noout', '--nonet', '--xinclude', '--postvalid', '--noent', processed
    )
    return ["#{mode}: validation failed\n#{err}", cll] unless status.success?
    [nil, cll, stdout]
  end
end

fixture = <<~XML
  <chapter xml:id="chapter-fixture">
  <title>Fixture &ndash; test</title>
  <section xml:id="section-local">
  <title>Local</title>
  <para>Local <xref linkend="section-local"/>.</para>
  <para>Appendix <xref linkend="appendix-changes"/>.</para>
  <para>Example <xref linkend="example-outside"/>.</para>
  <para>Grammar <xref linkend="ebnf-parses"/>.</para>
  <para>Texts <xref linkend="volume-chrestomathy"/>.</para>
  <para><link linkend="section-local">this section</link> and <link linkend="appendix-changes">the changes</link>.</para>
  <para><valsi>.y.</valsi> and <valsi>y</valsi> and <valsi>klama</valsi>.</para>
  </section>
  </chapter>
XML

%w[-t -s].each do |mode|
  message, merged, processed = validate_partial(repo, mode, [fixture])
  check.(message.nil?, message || "#{mode}: validation failed")
  next unless merged
  check.(merged.include?('&ndash;'), "#{mode}: character entity was lost")
  check.(!merged.include?('linkend="appendix-changes"'), "#{mode}: appendix reference was left unresolved")
  check.(!merged.include?('linkend="volume-chrestomathy"'), "#{mode}: chrestomathy reference was left unresolved")
  check.(!merged.include?('linkend="ebnf-parses"'), "#{mode}: grammar reference was left unresolved")
  check.(merged.include?('linkend="section-local"'), "#{mode}: local reference was retargeted")
  check.(merged.include?('linkend="chapter-fixture"'), "#{mode}: omitted references have no fallback")
  if processed
    ids = processed.scan(/xml:id="(valsi-[^"]+)"/).flatten
    check.(ids.count('valsi-y') == 1, "#{mode}: valsi-y count is #{ids.count('valsi-y')}")
  end
end

other = <<~XML
  <chapter xml:id="chapter-b"><title>Other</title><para><xref linkend="section-local"/></para></chapter>
XML
message, merged, = validate_partial(repo, '-t', [fixture, other])
check.(message.nil?, message || 'two-chapter validation failed')
if merged
  check.(merged.include?('linkend="section-local"'), 'a reference to an included chapter was retargeted')
  check.(!merged.include?('linkend="appendix-changes"'), 'an omitted reference survived a two-chapter build')
end

if failures.empty?
  puts 'test-partial-references: omitted targets are retargeted and partial books validate'
else
  puts 'test-partial-references: FAIL'
  failures.each { |failure| puts "  #{failure}" }
  exit 1
end
