#!/usr/bin/env ruby
# Full-width colspan replacement (issue #209).
# Run from anywhere: ruby scripts/test-html-table-spans.rb

require 'minitest/autorun'
require 'nokogiri'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
require File.join(ROOT, 'scripts/html_table_spans')

def parse(text)
  Nokogiri::XML(text) { |config| config.strict.nonet }
end

class HtmlTableSpansTest < Minitest::Test
  def test_sentinel_uses_the_column_count_including_row_spans
    document = parse(<<~XML)
      <table><tbody>
        <tr><td rowspan="2">A</td><td colspan="2">B</td></tr>
        <tr><td>C</td><td>D</td></tr>
        <tr><td colspan="12321">translation</td></tr>
      </tbody></table>
    XML
    assert_equal 1, HtmlTableSpans.normalize!(document)
    assert_equal '3', document.at_xpath('.//tr[last()]/td')['colspan']
    assert_equal '2', document.at_xpath('.//td[@rowspan]')['rowspan']
  end

  def test_a_row_span_keeps_its_column_for_the_following_row
    document = parse(<<~XML)
      <table>
        <tr><td rowspan="2">A</td><td>B</td></tr>
        <tr><td>C</td></tr>
        <tr><td colspan="12321">translation</td></tr>
      </table>
    XML
    assert_equal 1, HtmlTableSpans.normalize!(document)
    assert_equal '2', document.at_xpath('.//tr[last()]/td')['colspan']
  end

  def test_a_sentinel_that_shares_its_row_fails
    document = parse('<table><tr><td colspan="12321">A</td><td>B</td></tr></table>')
    error = assert_raises(HtmlTableSpans::Error) { HtmlTableSpans.normalize!(document) }
    assert_equal 'A full-width sentinel must occupy its own row', error.message
  end

  def test_a_sentinel_with_a_row_span_fails
    document = parse('<table><tr><td colspan="12321" rowspan="2">A</td></tr></table>')
    assert_raises(HtmlTableSpans::Error) { HtmlTableSpans.normalize!(document) }
  end

  def test_a_non_numeric_span_fails
    document = parse(<<~XML)
      <table>
        <tr><td colspan="wide">A</td></tr>
        <tr><td colspan="12321">translation</td></tr>
      </table>
    XML
    error = assert_raises(HtmlTableSpans::Error) { HtmlTableSpans.normalize!(document) }
    assert_equal 'Invalid table span', error.message
  end

  def test_a_table_without_a_sentinel_is_unchanged
    document = parse('<table><tr><td colspan="2">A</td></tr></table>')
    assert_equal 0, HtmlTableSpans.normalize!(document)
    assert_equal '2', document.at_xpath('.//td')['colspan']
  end

  def test_a_table_of_only_sentinels_is_one_column
    document = parse('<table><tr><td colspan="12321">A</td></tr></table>')
    assert_equal 1, HtmlTableSpans.normalize!(document)
    assert_equal '1', document.at_xpath('.//td')['colspan']
  end

  def test_a_nested_table_uses_its_own_width
    document = parse(<<~XML)
      <table>
        <tr><td>outer</td><td>
          <table><tr><td>a</td><td>b</td><td>c</td></tr><tr><td colspan="12321">inner</td></tr></table>
        </td></tr>
        <tr><td colspan="12321">outer translation</td></tr>
      </table>
    XML
    assert_equal 2, HtmlTableSpans.normalize!(document)
    assert_equal '2', document.at_xpath('/table/tr[last()]/td')['colspan']
    assert_equal '3', document.at_xpath('/table/tr/td/table/tr[last()]/td')['colspan']
  end

  def test_namespaced_xhtml_rows_in_a_head_and_body
    document = parse(<<~XML)
      <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <table>
          <thead><tr><th>one</th><th>two</th></tr></thead>
          <tbody><tr><td colspan="12321">both</td></tr></tbody>
        </table>
      </body></html>
    XML
    assert_equal 1, HtmlTableSpans.normalize!(document)
    cell = document.at_xpath('//*[local-name()="td"]')
    assert_equal '2', cell['colspan']
    assert_equal 'http://www.w3.org/1999/xhtml', cell.namespace.href
  end

  def test_rowspan_zero_covers_the_remaining_rows
    document = parse(<<~XML)
      <table>
        <tr><td rowspan="0">A</td><td>B</td><td>C</td></tr>
        <tr><td>D</td><td>E</td></tr>
        <tr><td colspan="12321">translation</td></tr>
      </table>
    XML
    assert_equal 1, HtmlTableSpans.normalize!(document)
    assert_equal '3', document.at_xpath('.//tr[last()]/td')['colspan']
  end

  def test_cleanup_writes_the_real_colspan
    source = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "dtd/xhtml1-transitional.dtd">
      <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
        <title>T</title>
      </head><body>
        <table><tr><td>A</td><td>B</td><td>C</td></tr>
        <tr><td colspan="12321">translation</td></tr></table>
      </body></html>
    XML
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'sample.html')
      File.write(file, source)
      env = ENV.to_h.merge('CLL_HTML_FORMAT' => 'none')
      stdout, stderr, status = Open3.capture3(
        env, 'ruby', File.join(ROOT, 'scripts/xhtml_postprocess_cleanup_file.rb'), file, chdir: ROOT
      )
      assert status.success?, stderr
      refute_includes stdout, '12321'
      assert_includes stdout, 'colspan="3"'
    end
  end

  def test_cleanup_reports_a_bad_sentinel_and_names_the_page
    source = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
        <table><tr><td colspan="12321">A</td><td>B</td></tr></table>
      </body></html>
    XML
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'chapter-tour.html')
      File.write(file, source)
      _stdout, stderr, status = Open3.capture3(
        ENV.to_h, 'ruby', File.join(ROOT, 'scripts/xhtml_postprocess_cleanup_file.rb'), file, 'chapter-tour.html',
        chdir: ROOT
      )
      refute status.success?
      assert_includes stderr, 'chapter-tour.html'
      assert_includes stderr, 'A full-width sentinel must occupy its own row'
    end
  end
end
