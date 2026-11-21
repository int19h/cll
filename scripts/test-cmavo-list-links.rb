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
# space between them (rule 12), each part following the same rules on
# its own (opt-outs, hidden-text exclusions and dictionary gate apply
# per part; a part without an entry stays plain and is reported); and a
# cell's text excludes indexterm, anchor and display-none subtrees
# (rule 11), so an anchor between letters does not stop the link and a
# nested rafsi never links (rule 9). The whole run is repeated with a
# default DocBook namespace, which the merged book carries and under
# which unprefixed XPath element names never match.
# Run from the repository root; exits 1 on failure.
require 'nokogiri'
require 'open3'
require 'tmpdir'
require_relative 'util'

failures = []
check = lambda { |ok, msg| failures << msg unless ok }
links = []

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
    <cmavo-entry>
      <cmavo><valsi glossary="false">roi</valsi><valsi>nai</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>an opted-out part stays plain, the other still links</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><valsi>roi</valsi><valsi>nai<phrase glossary="false"/></valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>a marked element inside a part unwraps that part</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><valsi>roi</valsi><valsi>nai<phrase role="display-none">x</phrase></valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>hidden text inside a part does not change its target</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><valsi>pi</valsi><valsi>nosuchword</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>a part with no entry stays plain and is reported</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo valid="false"><valsi>roi</valsi><valsi>nai</valsi></cmavo>
      <gismu>fasnu</gismu>
      <description>an opted-out cell unwraps every part</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>m<anchor xml:id="mid2"/>i</cmavo>
      <gismu>fasnu</gismu>
      <description>an anchor between letters does not stop the link</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo><rafsi>mi</rafsi></cmavo>
      <gismu>fasnu</gismu>
      <description>a nested rafsi never gets a glossary link</description>
    </cmavo-entry>
    <cmavo-entry>
      <cmavo>mi</cmavo>
      <gismu>fasnu<indexterm><primary>w</primary></indexterm></gismu>
      <description>an explicit indexterm does not join the cell text</description>
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
  <glossentry xml:id="valsi-pi"><glossterm>pi</glossterm><glossdef><para>portion</para></glossdef></glossentry>
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
check.(words == ['.ki', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'fasnu', 'jundi', 'jundi', 'kiha', 'mi', 'mi', 'mi', 'mi', 'mi', 'nahe', "pino'o", 'pinosuchword', 'roinai', 'roinai', 'roinai', 'roinai', 'roinai'],
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
  check.(links == [['.ki', 'valsi-ki']] + [['fasnu', 'valsi-fasnu']] * 14 +
                   [['jundi', 'valsi-jundi'], ['jundi', 'valsi-jundi']] +
                   [['mi', 'valsi-mi']] * 5 +
                   [['nai', 'valsi-nai']] * 3 + [['pi', 'valsi-pi']] + [['roi', 'valsi-roi']] * 3,
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
  check.(plain_roinai.length == 2, 'a plain roinai cell changed text or linked')
  check.(plain_roinai.all? { |td| td.xpath('.//glossterm').empty? }, 'a plain roinai cell linked')
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
  # Each split part follows the cell rules on its own: an opted-out
  # part stays plain text while its neighbor still links, and no valsi
  # wrapper survives the change.
  optout = doc.xpath("//informaltable//td[@class='cmavo']").find do |td|
    td.xpath('.//glossterm').map(&:text) == ['nai'] && td.text.gsub(/\s+/, '') == 'roinai'
  end
  check.(optout, 'the opted-out part did not stay plain beside its link')
  check.(optout && optout.xpath('.//valsi').empty?, 'an unwrapped part kept a valsi wrapper')
  marked_inside = doc.xpath("//informaltable//td[@class='cmavo']").find do |td|
    td.xpath('.//glossterm').map(&:text) == ['roi'] && td.text.gsub(/\s+/, '') == 'roinai' && !td.xpath('.//phrase').empty?
  end
  check.(marked_inside, 'a marked element inside a part broke its neighbor')
  hidden_part = doc.xpath("//informaltable//td[@class='cmavo']").find do |td|
    td.xpath('.//glossterm').map(&:text) == %w[roi nai] && !td.xpath('.//phrase[@role="display-none"]').empty?
  end
  check.(hidden_part, 'a part with hidden text did not link both parts')
  check.(hidden_part && hidden_part.xpath('.//glossterm').none? { |g| g['linkend'] == 'valsi-naix' },
        'hidden text changed a part link target')
  check.(hidden_part && hidden_part.text.include?('x'), 'hidden text inside a part was lost')
  missing_part = doc.xpath("//informaltable//td[@class='cmavo']").find do |td|
    td.xpath('.//glossterm').map(&:text) == ['pi'] && td.text.gsub(/\s+/, '') == 'pinosuchword'
  end
  check.(missing_part, 'a part with an entry did not link beside a part without one')
  check.(doc.xpath('//informaltable//@linkend').none? { |id| id.value == 'valsi-nosuchword' },
        'a part without an entry got a link')
  # An anchor between a word's letters does not stop the link.
  anchored = doc.xpath("//informaltable//td[@class='cmavo']").find do |td|
    td.at('.//anchor') && td.xpath('.//glossterm').map(&:text) == ['mi']
  end
  check.(anchored, 'an anchor between letters broke the link')
  # A nested rafsi never gets a glossary link, and the cell stays plain.
  rafsi_cell = doc.xpath("//informaltable//td[@class='cmavo']").find do |td|
    td.text.gsub(/\s+/, '') == 'mi' && td.xpath('.//glossterm').empty? &&
      !td.xpath('.//rafsi | .//foreignphrase').empty?
  end
  check.(rafsi_cell, 'the rafsi cell lost its word or grew a link')
  check.(doc.xpath("//informaltable//td[@class='cmavo']//indexterm").empty? &&
         doc.xpath("//informaltable//td[@class='gismu']//indexterm").empty?,
        'an explicit indexterm leaked into a cell')
  # Other elements never link, and the head row is untouched.
  check.(doc.xpath("//informaltable//td[not(@class='cmavo' or @class='gismu')]//glossterm").empty?,
        'a non-cmavo/gismu cell linked')
  check.(doc.xpath('//informaltable//thead//glossterm').empty?, 'the head row linked')

  # The four words without entries of their own stay plain and are each
  # reported once. Opted-out cells and phrases stay silent.
  check.(err.scan('cmavo-list: no glossary entry').length == 4,
        "unlinked-word reports:\n#{err}")
  ['roinai', "pino'o", 'kiha', 'nosuchword'].each do |word|
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

# The merged book parses with the default DocBook namespace, under
# which unprefixed XPath element names never match. The implementation
# must not rely on them: the same input with a default namespace must
# link the same cells the same way, with no valsi remnants and no
# index terms in any table cell.
Dir.mktmpdir do |dir|
  path = File.join(dir, 'mini-ns.xml')
  File.write(path, source.sub('<book>', '<book xmlns="http://docbook.org/ns/docbook">'))
  out_ns, err_ns, status = Open3.capture3('ruby', File.join(__dir__, 'xml_preprocess.rb'), path)
  check.(status.success?, "xml_preprocess.rb failed on namespaced input: #{err_ns.lines.last(3).join}")
  doc_ns = Nokogiri::XML(out_ns)
  doc_ns.remove_namespaces!
  ns_links = doc_ns.xpath("//informaltable//glossterm").map { |g| [g.text, g['linkend']] }.sort
  check.(ns_links == links, "namespaced run linked differently: #{ns_links.inspect}")
  ns_plain = doc_ns.xpath("//informaltable//td[@class='cmavo']").map(&:text) +
             doc_ns.xpath("//informaltable//td[@class='gismu']").map(&:text)
  ['ki alone', 'tense+ ki', 'roi nai', '-----', '[cmavo: mi]', 'm,i', 'roinai', "pino'o",
   'nahe', "ke'e", 'mi', 'kiha'].each do |text|
    check.(ns_plain.include?(text), "namespaced plain cell #{text.inspect} changed")
  end
  check.(err_ns.scan('cmavo-list: no glossary entry').length == 4,
        "namespaced run reported differently:\n#{err_ns}")
  check.(doc_ns.xpath('//informaltable//valsi').empty?, 'a valsi wrapper survived under a namespace')
  check.(doc_ns.xpath('//informaltable//indexterm').empty?, 'an indexterm survived under a namespace')
end

if failures.empty?
  puts 'test-cmavo-list-links: all checks passed'
else
  puts 'test-cmavo-list-links: FAIL'
  failures.each { |f| puts "  #{f}" }
  exit 1
end
