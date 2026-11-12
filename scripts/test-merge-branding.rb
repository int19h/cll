#!/usr/bin/env ruby
# Issue #172: .env punctuation must survive scripts/merge.sh as well-formed XML.
# Run from anywhere. Exits 1 on failure.

require 'cgi'
require 'fileutils'
require 'nokogiri'
require 'open3'
require 'tmpdir'

repo = File.expand_path('..', __dir__)
failures = []
check = lambda { |ok, msg| failures << msg unless ok }

def run_merge(root, title_line)
  env_path = File.join(root, '.env')
  File.write(env_path, title_line)
  build = File.join(root, 'build')
  FileUtils.rm_rf(build)
  FileUtils.mkdir_p(build)
  env = ENV.to_h.merge('CLL_BUILD_VERSION' => 'A & B')
  stdout, stderr, status = Open3.capture3(
    env, 'bash', 'scripts/merge.sh', '-t', '-b', build, 'chapter.xml', chdir: root
  )
  [status, stdout, stderr, File.join(build, 'cll.xml')]
end

def info_text(xml, xpath)
  info = xml[/<info>.*?<\/info>/m] or return nil
  doc = Nokogiri::XML("<wrapper>#{info}</wrapper>") { |config| config.strict.nonet }
  doc.at_xpath(xpath)&.text
end

Dir.mktmpdir do |root|
  File.symlink(File.join(repo, 'scripts'), File.join(root, 'scripts'))
  File.write(File.join(root, 'chapter.xml'), <<~XML)
    <chapter xml:id="chapter-test"><title>Test</title><para>Body.</para></chapter>
  XML

  {
    'Research & Teaching' => 'ampersand',
    "Lojban's Reference" => 'apostrophe',
    'Grammar = Reference' => 'equals',
    'Price is $5' => 'dollar'
  }.each do |title, label|
    status, _stdout, stderr, cll = run_merge(root, <<~ENV)
      TITLE=#{title}
      VERSION=audit
      REVISER=Auditor
      PUBLISHER=Example
    ENV
    check.(status.success?, "#{label}: merge exited #{status.exitstatus}\n#{stderr}")
    next unless status.success? && File.file?(cll)
    xml = File.read(cll)
    got = info_text(xml, '//title')
    check.(got == title, "#{label}: title text #{got.inspect}, expected #{title.inspect}")
    check.(info_text(xml, '//phrase[@role="release-version"]') == 'A & B',
           "#{label}: version was not escaped into the release phrase")
  end

  status, _stdout, stderr, cll = run_merge(root, <<~ENV)
    TITLE="Research & Teaching"
    SUBTITL='Grammar = Reference'
    REVISER=Lojban's community
    PUBLISHER='Press & Type'
    PUBLISHER_DISCLAIMER="Don't <tag> & friends"
  ENV
  check.(status.success?, "quoted fields: merge exited #{status.exitstatus}\n#{stderr}")
  if status.success? && File.file?(cll)
    xml = File.read(cll)
    check.(info_text(xml, '//title') == 'Research & Teaching', 'quoted title lost punctuation')
    check.(info_text(xml, '//subtitle') == 'Grammar = Reference', 'quoted subtitle lost the equals sign')
    check.(xml.include?("revised by Lojban&#39;s community"), 'reviser apostrophe was dropped or left raw')
    check.(info_text(xml, '//orgname[@role="publication-notice"]')&.include?('Press & Type'),
           'publisher lost the ampersand')
    check.(info_text(xml, '//phrase[@role="publication-disclaimer"]') == "Don't <tag> & friends",
           'disclaimer was not preserved as text')
  end

  status, _stdout, stderr, cll = run_merge(root, "TITLE=\"unterminated\nVERSION=audit\n")
  check.(!status.success?, 'unmatched quote was accepted')
  check.(!File.file?(cll), 'a failed parse still published cll.xml')
  check.(stderr.include?('unmatched quote'), "parse error did not name the quote problem:\n#{stderr}")

  status, = run_merge(root, "this is not an assignment\n")
  check.(!status.success?, 'a line without an equals sign was accepted')
end

{
  'TITLE' => 'The Contemporary Lojban Language',
  'PUBLISHER' => '(not a Logical Language Group publication)',
  'REVISER' => 'the Lojban community',
  'SUBTITL' => ''
}.each do |key, expected|
  got, status = Open3.capture2('ruby', File.join(repo, 'scripts/branding-value.rb'), key, File.join(repo, '.env'))
  check.(status.success?, "#{key}: branding-value failed on the repository .env")
  check.(got == expected, "#{key}: #{got.inspect}, expected #{expected.inspect}")
end

if failures.empty?
  puts 'test-merge-branding: punctuation in .env reaches the title page'
else
  puts 'test-merge-branding: FAIL'
  failures.each { |failure| puts "  #{failure}" }
  exit 1
end
