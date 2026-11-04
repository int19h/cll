#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'lint-word-spellings'

class WordSpellingsTest < Minitest::Test
  def lint(xml)
    WordSpellings.failures(Nokogiri::XML("<chapter>#{xml}</chapter>"), '17.xml')
  end

  def test_cgv_and_case
    %w[.liudis. .kuot. .melxi,or. .CIAs. .naciys.].each do |word|
      assert_equal 1, WordSpellings.sequences(word).size, word
      assert_equal 'CGV', WordSpellings.sequences(word).first.first
    end
    assert_equal 2, WordSpellings.sequences('.tcriyviys.').size
    assert_equal 2, WordSpellings.sequences('.liudies.').size
  end

  def test_full_vowel_before_glide
    %w[slinkuui .liiudiies. .nuiork. .xaliuyd. .kiiys. .kuuot.].each do |word|
      assert_empty WordSpellings.sequences(word), word
    end
  end

  def test_repeated_vowel_without_following_nucleus
    assert_equal [['CGV', 'kii']], WordSpellings.sequences('.ckiipyris.')
    assert_equal [['CGV', 'nii']], WordSpellings.sequences('.an,iis.')
  end

  def test_invalid_examples
    assert_empty lint('<example valid="false"><jbo>.kuot.</jbo></example>')
    assert_empty lint('<jbo valid="maybe">.kuot.</jbo>')
    assert_empty lint('<jbo>mi <cmevla valid="false">.kuot.</cmevla> klama</jbo>')
    refute_empty lint('<jbo valid="iffy">.kuot.</jbo>')
  end

  def test_foreign_quotes_and_delimiters
    assert_empty lint('<jbo>zoi gy. liudies .gy. cu glico</jbo>')
    assert_empty lint('<jbo>zoi gy. .ai,in. .g,y. cu glico</jbo>')
    assert_empty lint('<jbo>la\'o gy. liudies .gy.</jbo>')
    assert_equal 2, lint('<jbo>zoi .kuot. liudies .kuot.</jbo>').size
    assert_equal 3, lint('<jbo>zo zoi .kuot. .liudies.</jbo>').size
    assert_equal 2, lint('<jbo>lo\'u zoi liudies le\'u</jbo>').size
  end

  def test_foreign_quote_across_rows
    assert_empty lint('<example><interlinear-gloss><jbo>zoi gy. English</jbo><gloss>text</gloss><jbo>liudies .gy.</jbo></interlinear-gloss></example>')
    assert_equal 1, lint('<example><jbo>zoi gy. text</jbo></example><example><jbo>.kuot.</jbo></example>').size
  end

  def test_only_live_lojban_text_once
    assert_empty lint('<para>.liudies.</para><!-- <jbo>.liudies.</jbo> -->')
    assert_empty lint('<gloss><cmavo>obligation</cmavo><valsi>.kuot.</valsi></gloss>')
    assert_empty lint('<jbo>mi <comment>initial</comment> klama</jbo>')
    assert_equal 1, lint('<jbo><cmevla>.kuot.</cmevla></jbo>').size
    assert_equal 2, lint('<valsi>.li<emphasis>u</emphasis>dies.</valsi>').size
    assert_equal 1, lint('<jbo><cmavo>mi</cmavo><sumti>.kuot.</sumti></jbo>').size
  end

  def test_comma_review
    assert_empty lint('<jbo>la .nu,iork. .xali,uyd. .me,iin. .va,uensas.</jbo>')
    out = lint('<jbophrase>.ai,in.</jbophrase>').join
    assert_includes out, '<jbophrase> ".ai,in."'
    assert_includes out, 'unreviewed comma between vowels'
    refute_empty lint('<valsi>.nu,io,rk.</valsi>')
  end
end
