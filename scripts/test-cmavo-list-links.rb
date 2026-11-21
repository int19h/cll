#!/usr/bin/env ruby
# The link rules for cmavo-list cells, shared with jbotci (int19h/jbotci#1108):
# only <cmavo> and <gismu> cells link; a cell links only when its whole
# trimmed text is one word ([.a-zA-Z']+) or exactly [word] (the inner word
# links, the brackets stay plain text); everything else stays plain
# (empty, "-----", "[cmavo: mi]", phrases with spaces); a compound links
# as a whole only when the dictionary has that exact word, never split;
# the target is the entry equal to the text or differing only in outer
# pause dots, else the cell stays plain and is reported; a <valsi>
# already inside a cell counts as the cell's text under the same rules
# and never makes a nested link, so `tense+ <valsi>ki</valsi>` stays
# plain; glossary="false" and valid="false"/"maybe" on a cell or on a
# <valsi> inside it stop the link, as for a <valsi>; a cell spelling
# without an entry of its own ("kiha") never takes over another word's
# entry ("ki'a"); two adjacent <valsi> parts link separately with no
# space between them (rule 12); and a cell's text excludes indexterm,
# anchor and display-none subtrees (rule 11).
# Run from the repository root; exits 1 on failure.
require 'nokogiri'
require 'open3'
require 'tmpdir'
require_relative 'util'

failures = []
check = lambda { |ok, msg| failures << msg unless ok }

source = <<~XML
  <?xml version="1.0"?>
  <book><chapter><title>Words</title>
  <para>The cmavo <valsi>mi</valsi> names the speaker; <valsi>ki'a</valsi> is an apology.</para>
  <cmavo-list>
    <cmavo-list-head><td>cmavo</td><td>gismu</td><td>selmaho</td></cmavo-list-head>
    <cmavo-entry>
      <cmavo>mi</cmavo>
      <gismu>[jundi]</gismu>
      <selmaho>MI</selmaho>
      <description>plain and bracketed words link; other elements never do</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>.ki</cmavo>
      <gismu />
      <description>outer pause dots link to the same entry</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>ki alone</cmavo>
      <gismu>-----</gismu>
      <description>phrases and placeholders stay plain</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>[cmavo: mi]</cmavo>
      <gismu>m,i</gismu>
      <description>bracketed phrases and inner commas stay plain</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>roinai</cmavo>
      <gismu>pino'o</gismu>
      <description>compounds link as a whole only with an entry; these have none</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><valsi>mi</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>a valsi in a single-word cell links once, never nested</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>tense+ <valsi>ki</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>a valsi in a phrase cell stays plain with the phrase</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo glossary="false">nahe</cmavo>
      <gismu valid="maybe">ke'e</gismu>
      <description>opted-out cells stay plain and silent</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><valsi valid="maybe">mi</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>an opted-out valsi in a cell stays plain and silent</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>kiha</cmavo>
      <gismu>fasnu</gismu>
      <description>a cell spelling takes no other word's entry</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><valsi>roi</valsi><valsi>nai</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>adjacent parts link separately with no space</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><valsi>roi</valsi> <valsi>nai</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>spaced parts stay plain as a phrase</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>mi<anchor xml:id="cell-anchor"/></cmavo>
      <gismu>[jundi<phrase role="display-none">hidden</phrase>]</gismu>
      <description>anchors and hidden text do not count as cell text</description>
    </cmavo-entry>
  </cmavo-list>
  <glossary><glossdiv><title>M</title>
  <glossentry xml:id="valsi-mi"><glossterm>mi<guibutton>mi</guibutton></glossterm><glossdef><para>I</para></glossdef></glossentry>
  <glossentry xml:id="valsi-ki"><glossterm>ki</glossterm><glossdef><para>sticky</para></glossdef></glossentry>
  <glossentry xml:id="valsi-jundi"><glossterm>jundi</glossterm><glossdef><para>attentive</para></glossdef></glossentry>
  <glossentry xml:id="valsi-fasnu"><glossterm>fasnu</glossterm><glossdef><para>event</para></glossdef></glossentry>
  <glossentry xml:id="valsi-kiha"><glossterm>ki'a</glossterm><glossdef><para>sorry</para></glossdef></glossentry>
  <glossentry xml:id="valsi-roi"><glossterm>roi</glossterm><glossdef><para>all</para></glossdef></glossentry>
  <glossentry xml:id="valsi-nai"><glossterm>nai</glossterm><glossdef><para>not</para></glossdef></glossentry>
  </glossdiv></glossary>
  </chapter></book>
XML

# The glossary side collects exactly the linkable words: bare words and
# the inner word of [word], nothing from other elements or plain cells.
# Opted-out valid="maybe" words stay out (ke'e); a glossary="false"
# word is still collected (nahe), as for a <valsi>. A compound cell
# contributes its whole text (roinai); anchors and hidden text do not
# count (the mi and jundi cells, not "hidden").
words = find_cmavo_list_words(Nokogiri::XML(source)).sort
check.(words == ['.ki', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'jundi', 'jundi', 'kiha', 'mi', 'mi', 'mi', 'nahe', "pino'o", 'roinai', 'roinai'],
      "find_cmavo_list_words gave #{words.inspect}")

# The preprocessing side, through the real script.
Dir.mktmpdir do |dir|
  path = File.join(dir, 'mini.xml')
  File.write(path, source)
  out, err, status = Open3.capture3('ruby', File.join(__dir__, 'xml_preprocess.rb'), path)
  check.(status.success?, "xml_preprocess.rb failed: #{err.lines.last(3).join}")
  doc = Nokogiri::XML(out)
  doc.remove_namespaces!

  links = doc.xpath("//informaltable//glossterm").map { |g| [g.text, g['linkend']] }.sort
  check.(links == [['.ki', 'valsi-ki'], ['fasnu', 'valsi-fasnu'], ['fasnu', 'valsi-fasnu'],
                   ['fasnu', 'valsi-fasnu'], ['fasnu', 'valsi-fasnu'], ['fasnu', 'valsi-fasnu'],
                   ['fasnu', 'valsi-fasnu'], ['jundi', 'valsi-jundi'],
                   ['jundi', 'valsi-jundi'], ['mi', 'valsi-mi'], ['mi', 'valsi-mi'],
                   ['mi', 'valsi-mi'], ['nai', 'valsi-nai'], ['roi', 'valsi-roi']],
        "table links: #{links.inspect}")

  # The brackets stay as plain text around the inner link.
  check.(doc.xpath("//informaltable//td[@class='gismu']")[0].text == '[jundi]',
        'bracketed cell text changed')
  # Plain cells keep their exact text and grow no link: phrases (with or
  # without an inner valsi), placeholders, opted-out cells, and the
  # word without an entry of its own.
  plain = doc.xpath("//informaltable//td[@class='cmavo']").map(&:text) +
          doc.xpath("//informaltable//td[@class='gismu']").map(&:text)
  ['ki alone', 'tense+ ki', 'roi nai', '-----', '[cmavo: mi]', 'm,i', 'roinai', "pino'o",
   'nahe', "ke'e", 'mi', 'kiha'].each do |text|
    check.(plain.include?(text), "plain cell #{text.inspect} changed or linked")
  end
  plain_roinai = doc.xpath("//informaltable//td[@class='cmavo']").select { |td| td.text == 'roinai' }
  check.(plain_roinai.length == 1, 'the plain roinai cell changed text or linked')
  check.(plain_roinai.all? { |td| td.xpath('.//glossterm').empty? }, 'the plain roinai cell linked')
  split = doc.xpath("//informaltable//td[@class='cmavo']").find do |td|
    td.xpath('.//glossterm').map(&:text) == %w[roi nai]
  end
  check.(split, 'the split parts did not link separately')
  check.(split && split.text.gsub(/\s+/, '') == 'roinai', 'a split cell changed text')
  check.(split && out.include?('roi</glossterm></foreignphrase><foreignphrase'),
        'the split parts are not adjacent')
  hidden = doc.xpath("//informaltable//td[@class='gismu']").find { |td| td.at('.//phrase[@role="display-none"]') }
  check.(hidden && hidden.xpath('.//glossterm').map(&:text) == ['jundi'] && hidden.text.include?('hidden'),
        'hidden text broke the bracketed link or was lost')
  check.(doc.xpath("//informaltable//td[@class='cmavo']").any? { |td| td.at('.//anchor') },
        'the anchor did not survive')
  # Other elements never link, and the head row is untouched.
  check.(doc.xpath("//informaltable//td[not(@class='cmavo' or @class='gismu')]//glossterm").empty?,
        'a non-cmavo/gismu cell linked')
  check.(doc.xpath('//informaltable//thead//glossterm').empty?, 'the head row linked')

  # The three words without entries of their own stay plain and are each
  # reported once. Opted-out cells and phrases stay silent.
  check.(err.scan('cmavo-list: no glossary entry').length == 3,
        "unlinked-word reports:\n#{err}")
  ['roinai', "pino'o", 'kiha'].each do |word|
    check.(err.include?("cmavo-list: no glossary entry for \"#{word}\""),
          "missing word #{word.inspect} not reported:\n#{err}")
  end

  # The same markup a <valsi> gets, minus the index entry: tables link
  # without growing the index, a valsi in a cell never nests, and the
  # body word keeps its own entry and link.
  valsi_link = doc.xpath('//chapter/para//glossterm').map(&:to_xml)
  table_link = doc.xpath("//informaltable//glossterm[.='mi']").map(&:to_xml).uniq
  check.(table_link == valsi_link.select { |x| x.include?('>mi<') },
        "table link markup differs from the valsi link: #{table_link.inspect} vs #{valsi_link.inspect}")
  check.(doc.xpath('//informaltable//indexterm').empty?, 'a table cell grew an index entry')
  check.(doc.xpath('//informaltable//glossterm//glossterm').empty?, 'a cell link nested')
  body_kia = doc.xpath("//chapter/para//glossterm[.=\"ki'a\"]")
  check.(body_kia.length == 1 && body_kia.first['linkend'] == 'valsi-kiha',
        "the body ki'a lost its link: #{body_kia.map(&:to_xml).inspect}")
end

if failures.empty?
  puts 'test-cmavo-list-links: all checks passed'
else
  puts 'test-cmavo-list-links: FAIL'
  failures.each { |f| puts "  #{f}" }
  exit 1
end
