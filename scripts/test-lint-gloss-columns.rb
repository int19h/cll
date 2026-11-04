#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tempfile'
require_relative 'lint-gloss-columns'

class GlossColumnsTest < Minitest::Test
  def lint_failures(jbo, gloss)
    doc = Nokogiri::XML(<<~XML)
      <chapter><example id="first"><title/></example>
      <example id="target"><title/><interlinear-gloss>
      <jbo>#{jbo}</jbo><gloss>#{gloss}</gloss>
      </interlinear-gloss></example></chapter>
    XML
    GlossColumns.failures(doc, 'chapters/06.xml')
  end

  def test_short_gloss_and_location
    out = lint_failures('mi klama', 'I').join
    assert_includes out, 'example 6.2 (target)'
    assert_includes out, '1 gloss cells for 2 Lojban cells'
    assert_match(/klama\s+\| \(missing\)/, out)
  end

  def test_structural_words
    %w[cu ku ku'o kei vau be'o ke'e].each do |word|
      [word, "[#{word}]"].each do |spelling|
        refute_empty lint_failures("mi #{spelling} klama", 'I goes -')
        assert_empty lint_failures("mi #{spelling} klama", 'I - goes')
        assert_empty lint_failures("mi #{spelling} klama", 'I ) goes')
      end
    end
  end

  def test_sentence_link
    assert_empty lint_failures('.i mi klama', 'And I go')
    refute_empty lint_failures('.i mi klama', '[wrong:] I go')
  end

  def test_build_cells
    doc = Nokogiri::XML('<root><gloss>- -- two--words <quote>a b</quote> x<subscript>1</subscript>=2</gloss></root>')
    assert_equal ['', "\u00a0", "two\u00a0words", 'a b', 'x1=2'], GlossColumns.cells(doc.at('gloss'))
    assert_empty lint_failures('mi cu <quote>two words</quote>', 'I -- <quote>two words</quote>')
  end

  def test_extra_cells_and_comments
    assert_empty lint_failures('mi klama', 'I go (somewhere)')
    assert_empty lint_failures('mi <!-- cu --> klama', 'I go')
    assert_empty lint_failures('mi cu klama', 'I -- go')
  end

  def test_chapter_entities_and_errors
    Tempfile.create(['chapter', '.xml']) do |file|
      file.write('<chapter><interlinear-gloss><jbo>mi cu</jbo><gloss>I &ndash;</gloss></interlinear-gloss></chapter>')
      file.flush
      assert_empty GlossColumns.failures(ChapterLint.read(file.path), file.path)
      file.rewind
      file.truncate(0)
      file.write('<chapter><jbo>mi</chapter>')
      file.flush
      assert_raises(Nokogiri::XML::SyntaxError) { ChapterLint.read(file.path) }
    end
  end

  def test_multiline
    doc = Nokogiri::XML('<chapter><example id="two"><interlinear-gloss><jbo>mi cu</jbo><gloss>I -</gloss><jbo>klama [vau]</jbo><gloss>go</gloss></interlinear-gloss></example></chapter>')
    assert_equal 1, GlossColumns.failures(doc, '11.xml').size
  end
end
