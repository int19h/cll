#!/usr/bin/env ruby
# Test that a jbophrase naming a frame, such as "lu ... li'u", links each of
# its words to the glossary, and that the glossary collects those words.
# Run from the repository root; exits 1 on any failure.
require 'nokogiri'
require 'open3'
require 'tmpdir'
require_relative 'util'

failures = []
check = lambda { |ok, msg| failures << msg unless ok }

# The detector.
{
  "ke ... ke'e" => %w[ke ke'e],
  "lo'u…le'u" => %w[lo'u le'u],
  "be ... bei ... be'o" => %w[be bei be'o],
  "zoi ..." => nil,
  "pu gi ... gi" => nil,
  "le ni ... kei be" => nil,
  "… .i la .djan." => nil,
  "la .djan." => nil,
}.each do |text, words|
  parts = jbophrase_frame(text)
  got = parts && parts.each_slice(2).map(&:first)
  check.(got == words, "jbophrase_frame(#{text.inspect}) gave #{got.inspect}, expected #{words.inspect}")
end

source = <<~XML
  <?xml version="1.0"?>
  <book xmlns:xlink="http://www.w3.org/1999/xlink"><chapter><title>On <jbophrase>ke ... ke'e</jbophrase></title>
  <para><jbophrase>lu ... li'u</jbophrase>, <jbophrase>lo'u…le'u</jbophrase>, <jbophrase valid="false">to ... toi</jbophrase>, <jbophrase>pu gi ... gi</jbophrase>.</para>
  </chapter></book>
XML

# The glossary side.
words = find_frame_words(Nokogiri::XML(source)).sort
check.(words == %w[ke ke'e le'u li'u lo'u lu].sort, "find_frame_words gave #{words.inspect}")

# The preprocessing side, through the real script.
Dir.mktmpdir do |dir|
  path = File.join(dir, 'mini.xml')
  File.write(path, source)
  out, err, status = Open3.capture3('ruby', File.join(__dir__, 'xml_preprocess.rb'), path)
  check.(status.success?, "xml_preprocess.rb failed: #{err.lines.last(3).join}")
  doc = Nokogiri::XML(out)
  doc.remove_namespaces!
  links = doc.xpath('//para//glossterm').map { |g| [g.text, g['linkend']] }
  check.(links == [%w[lu valsi-lu], %w[li'u valsi-lihu], %w[lo'u valsi-lohu], %w[le'u valsi-lehu]],
         "glossary links in the paragraph: #{links.inspect}")
  phrases = doc.xpath("//indexterm[@type='lojban-phrase']/primary").map(&:text)
  check.(phrases.include?("lu ... li'u") && phrases.include?("lo'u…le'u"),
         "phrase index entries lost their text: #{phrases.inspect}")
  check.(doc.xpath('//title//glossterm').empty?, 'a title got a glossary link')
  check.(doc.xpath('//para').first.text.include?("pu gi ... gi"), 'a non-frame phrase lost its text')
end

if failures.empty?
  puts 'test-jbophrase-frames: all checks passed'
else
  puts 'test-jbophrase-frames: FAIL'
  failures.each { |f| puts "  #{f}" }
  exit 1
end
